--!strict
-- Validates and applies block breaking/placing requests. The client predicts locally; the
-- server re-checks everything and always answers the requester with the true block state, so
-- a rejected prediction is corrected immediately.
--
-- Checks: payload types, rate limit, world bounds, reach from the eye, line of sight (voxel
-- raycast on server data), held item from the server inventory, break duration (classic formula),
-- and that placed blocks don't overlap any character.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local SneakPose = require(Shared.Gameplay.SneakPose)
local TorchRules = require(Shared.Blocks.TorchRules)
local Placement = require(Shared.Blocks.Placement)
local Shapes = require(Shared.Blocks.Shapes)
local Config = require(Shared.Config)
local Remotes = require(Shared.Net.Remotes)
local BlockRegistry = require(Shared.Blocks.BlockRegistry)
local ItemRegistry = require(Shared.Items.ItemRegistry)
local Mining = require(Shared.Gameplay.Mining)
local VoxelRaycast = require(Shared.World.VoxelRaycast)
local ChunkData = require(Shared.World.ChunkData)
local WorldService = require(script.Parent.Parent.World.WorldService)
local ChunkStreamer = require(script.Parent.Parent.World.ChunkStreamer)
local InventoryService = require(script.Parent.Parent.Player.InventoryService)
local ItemEntityService = require(script.Parent.Parent.World.ItemEntityService)
local BlockEntityService = require(script.Parent.Parent.World.BlockEntityService)

local BS = Config.BLOCK_SIZE
local H = Config.WORLD_HEIGHT
local AIR = 0
local isLiquid = BlockRegistry.isLiquid

local BlockActionService = {}
-- Listeners called after a player breaks a block (survival exhaustion, voidling anger, ...).
-- Registered by those services to avoid require cycles.
local blockBrokenListeners: { (Player, number, number, number) -> () } = {}
local placedListeners: { (Player, number, number, number, number) -> () } = {}
-- Called after a player places a block (signs open their editor).
function BlockActionService.onPlaced(fn: (Player, number, number, number, number) -> ())
	table.insert(placedListeners, fn)
end
function BlockActionService.onBlockBroken(fn: (Player, number, number, number) -> ())
	table.insert(blockBrokenListeners, fn)
end
BlockActionService.stats = { accepted = 0, rejected = 0, lastReject = "" }

type Pending = { x: number, y: number, z: number, t: number, item: string? }
type PState = { pending: Pending?, tokens: number, last: number }
local states: { [Player]: PState } = {}

local function state(p: Player): PState
	local s = states[p]
	if not s then
		s = { pending = nil, tokens = Config.ACTIONS_PER_SECOND, last = os.clock() }
		states[p] = s
	end
	return s
end

local function allow(s: PState): boolean
	local now = os.clock()
	s.tokens = math.min(Config.ACTIONS_PER_SECOND, s.tokens + (now - s.last) * Config.ACTIONS_PER_SECOND)
	s.last = now
	if s.tokens < 1 then
		return false
	end
	s.tokens -= 1
	return true
end

local function isInt(v: any): boolean
	return typeof(v) == "number" and v == v and v % 1 == 0 and math.abs(v) < 2 ^ 24
end

-- Eye position in BLOCK units, or nil if the player has no live character.
local function eyeOf(player: Player): Vector3?
	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart") :: BasePart?
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	if not root or not humanoid or humanoid.Health <= 0 then
		return nil
	end
	return (root.Position + Vector3.new(0, SneakPose.eyeHeight(root.Parent), 0)) / BS
end

local function stopsRay(id: number): boolean
	return id ~= AIR and not isLiquid[id + 1]
end

local function getBlock(x: number, y: number, z: number): number?
	return WorldService.getBlock(x, y, z)
end

-- Reach + line of sight to block cell (x,y,z). For breaking, the first block the ray hits must be
-- the target; for placing, nothing may block the way to the empty target cell. A few sample points
-- on the cell are tried so aiming at an edge isn't rejected.
local SAMPLES = {
	Vector3.new(0.5, 0.5, 0.5),
	Vector3.new(0.02, 0.5, 0.5), Vector3.new(0.98, 0.5, 0.5),
	Vector3.new(0.5, 0.02, 0.5), Vector3.new(0.5, 0.98, 0.5),
	Vector3.new(0.5, 0.5, 0.02), Vector3.new(0.5, 0.5, 0.98),
}
local rayShape = Shapes.rayShapeFn(function(x: number, y: number, z: number): number?
	return WorldService.getBlock(x, y, z)
end)
local function canReach(eye: Vector3, x: number, y: number, z: number, forPlace: boolean): (boolean, string)
	local center = Vector3.new(x + 0.5, y + 0.5, z + 0.5)
	local maxDist = Config.REACH + Config.REACH_TOLERANCE
	if (center - eye).Magnitude > maxDist + 0.87 then -- 0.87 = half the cube diagonal
		return false, "out of reach"
	end
	-- sample points: the cell's centre and face centres, plus the centre of every box of a
	-- shaped block (a thin door panel or a fence post may miss them all otherwise)
	local samples = table.clone(SAMPLES)
	local id = WorldService.getBlock(x, y, z)
	if id ~= AIR and BlockRegistry.isBoxShape[id + 1] then
		for _, b in Shapes.at(getBlock, x, y, z, false) do
			table.insert(samples, Vector3.new((b[1] + b[4]) / 2, (b[2] + b[5]) / 2, (b[3] + b[6]) / 2))
		end
	end
	for _, o in samples do
		local target = Vector3.new(x, y, z) + o
		local dir = target - eye
		local dist = dir.Magnitude
		if dist <= maxDist then
			-- real block shapes: an open door, a fence or a slab's empty half don't block the view
			local hit = VoxelRaycast.cast(getBlock, eye.X, eye.Y, eye.Z, dir.X, dir.Y, dir.Z, dist + 0.01, stopsRay, rayShape)
			if forPlace then
				if not hit or (hit.x == x and hit.y == y and hit.z == z) or hit.distance >= dist - 0.05 then
					return true, ""
				end
			elseif hit and hit.x == x and hit.y == y and hit.z == z then
				return true, ""
			end
		end
	end
	return false, "no line of sight"
end

-- Recent root positions per player (last ~0.5 s), for latency-tolerant overlap checks.
local history: { [Player]: { { t: number, p: Vector3 } } } = {}
local HISTORY_SECONDS = 0.5

local function boxOverlaps(p: Vector3, minP: Vector3, maxP: Vector3): boolean
	-- character box: ~1.8 studs wide, feet 2.95 below the root, top 2 above
	local cMin = Vector3.new(p.X - 0.9, p.Y - 2.95, p.Z - 0.9)
	local cMax = Vector3.new(p.X + 0.9, p.Y + 2.0, p.Z + 0.9)
	return cMin.X < maxP.X and cMax.X > minP.X and cMin.Y < maxP.Y and cMax.Y > minP.Y and cMin.Z < maxP.Z and cMax.Z > minP.Z
end

-- Would a block at this cell overlap a character?
-- The requester's own body is judged with latency tolerance (towering up: you jump and place a
-- block under yourself; the server sees you a few frames late, still lower). It's allowed when
-- the client's own check passed and, on the server, either:
--   * any position in the last 0.5 s is clear of the block (you've been above it), or
--   * you're moving upward and your feet are above the block's lower half.
-- Other players are checked at their current position with no tolerance.
local function overlapsCharacter(x: number, y: number, z: number, requester: Player): (boolean, boolean)
	local minP = Vector3.new(x, y, z) * BS
	local maxP = minP + Vector3.one * BS
	for _, player in Players:GetPlayers() do
		local character = player.Character
		local root = character and character:FindFirstChild("HumanoidRootPart") :: BasePart?
		if root and boxOverlaps(root.Position, minP, maxP) then
			if player ~= requester then
				return true, true
			end
			local clear = false
			for _, h in history[player] or {} do
				if not boxOverlaps(h.p, minP, maxP) then
					clear = true
					break
				end
			end
			local feetY = root.Position.Y - 2.95
			if not clear and root.AssemblyLinearVelocity.Y > 2 and feetY >= minP.Y + BS * 0.5 then
				clear = true
			end
			if not clear then
				return true, false
			end
		end
	end
	return false, false
end

-- Placements that overlapped only the requester's (server-side, lagging) body: towering up.
-- They are re-checked every frame for a short while, so the server's view of the jump can
-- catch up with the client's, instead of rejecting the block at once.
local DEFER_SECONDS = 0.6
type Deferred = { player: Player, x: number, y: number, z: number, untilT: number, face: { number }, extra: { number }? }
local deferred: { Deferred } = {}

local function broadcast(key: number, x: number, y: number, z: number, id: number, requester: Player)
	local remote = Remotes.get("BlockChanged")
	local sentToRequester = false
	for _, p in ChunkStreamer.playersWithChunk(key) do
		remote:FireClient(p, x, y, z, id)
		if p == requester then
			sentToRequester = true
		end
	end
	if not sentToRequester then
		remote:FireClient(requester, x, y, z, id)
	end
end

-- Tell the requester the true state of a cell (undoes a wrong prediction).
local function correct(player: Player, x: number, y: number, z: number, why: string)
	BlockActionService.stats.rejected += 1
	BlockActionService.stats.lastReject = why
	if y >= 0 and y < H then
		Remotes.get("BlockChanged"):FireClient(player, x, y, z, WorldService.getBlock(x, y, z))
	end
end

local function heldItem(player: Player): string?
	local s = InventoryService.selectedStack(player)
	return s and s.item
end

local function finishBreak(player: Player, st: PState, x: number, y: number, z: number)
	local eye = eyeOf(player)
	if not eye then
		return correct(player, x, y, z, "no character")
	end
	local id = WorldService.getBlock(x, y, z)
	local item = heldItem(player)
	local expected = Mining.breakSeconds(id, item)
	if expected == math.huge then
		return correct(player, x, y, z, "unbreakable")
	end
	local ok, why = canReach(eye, x, y, z, false)
	if not ok then
		return correct(player, x, y, z, why)
	end
	if expected > 0 then
		local p = st.pending
		if not p or p.x ~= x or p.y ~= y or p.z ~= z then
			return correct(player, x, y, z, "finish without start")
		end
		if p.item ~= item then
			st.pending = nil
			return correct(player, x, y, z, "tool changed while mining")
		end
		local elapsed = os.clock() - p.t
		if elapsed < expected * Config.BREAK_TIME_TOLERANCE - Config.BREAK_LATENCY_SLACK then
			return correct(player, x, y, z, string.format("too fast (%.2fs < %.2fs)", elapsed, expected))
		end
	end
	st.pending = nil

	-- Apply: block -> air, the drop pops out as an item entity, tool wear.
	local key = WorldService.setBlock(x, y, z, AIR)
	local center = Vector3.new(x + 0.5, y + 0.5, z + 0.5) * BS
	local def = BlockRegistry.get(id)
	if def and def.drop and Mining.canHarvest(id, item) then
		local count = if def.dropMax > def.dropMin then math.random(def.dropMin, def.dropMax) else def.dropMin
		local dropItem = def.drop
		local alt = def.altDrop
		if alt and math.random() < alt.chance then
			dropItem = alt.item -- Java: gravel drops flint 10 % of the time
		end
		ItemEntityService.spawn({ item = dropItem, count = count }, center)
	end
	if def then
		-- chance drops (apples / sticks from leaves), any tool or bare hands
		for _, bonus in def.bonusDrops do
			if math.random() < bonus.chance then
				ItemEntityService.spawn({ item = bonus.item, count = 1 }, center)
			end
		end
	end
	for _, fn in blockBrokenListeners do
		fn(player, x, y, z)
	end
	if BlockEntityService.kindOf(id) then
		-- chest / furnace contents spill out
		ItemEntityService.spawnAround(BlockEntityService.remove(x, y, z), center)
	end
	local wear = Mining.durabilityCost(id, item)
	if wear > 0 then
		InventoryService.damageSelectedTool(player, wear)
	end
	BlockActionService.stats.accepted += 1
	broadcast(key, x, y, z, AIR, player)
	-- torches that hung on this block fall off and drop
	for _, t in TorchRules.dependents(x, y, z, WorldService.getBlock) do
		local tkey = WorldService.setBlock(t[1], t[2], t[3], AIR)
		ItemEntityService.spawn({ item = "torch", count = 1 }, Vector3.new(t[1] + 0.5, t[2] + 0.5, t[3] + 0.5) * BS)
		broadcast(tkey, t[1], t[2], t[3], AIR, player)
	end
end

local function place(player: Player, x: number, y: number, z: number, retry: boolean?, face: { number }?, extra: { number }?): boolean
	local f = face or { 0, 1, 0 }
	-- a refused placement: undo every cell the client may have predicted (the target, a door's
	-- top half above it, a slab merged into the clicked block)
	local function reject(why: string)
		correct(player, x, y, z, why)
		local remote = Remotes.get("BlockChanged")
		for _, c in { { x, y + 1, z }, { x - f[1], y - f[2], z - f[3] } } do
			if c[2] >= 0 and c[2] < H then
				remote:FireClient(player, c[1], c[2], c[3], WorldService.getBlock(c[1], c[2], c[3]))
			end
		end
	end
	local eye = eyeOf(player)
	if not eye then
		reject("no character")
		return true
	end
	-- the off hand places when the client says so (its main hand can't place)
	local useOff = extra ~= nil and extra[6] == 1
	local slot = if useOff then Config.OFFHAND_SLOT else InventoryService.selectedSlot(player)
	local stack = InventoryService.getSlot(player, slot)
	local item = stack and ItemRegistry.get(stack.item)
	if not item or not item.block then
		reject("not holding a block")
		return true
	end
	-- must be placed against an existing block (the clicked one)
	local hx, hy, hz = x - f[1], y - f[2], z - f[3]
	local clicked = WorldService.getBlock(hx, hy, hz)
	if clicked == AIR or isLiquid[clicked + 1] then
		reject("nothing to place against")
		return true
	end
	local ok, why = canReach(eye, x, y, z, true)
	if not ok then
		reject(why)
		return true
	end
	-- the exact click point and look direction (slab halves, stair / door facing, door hinge)
	local e = extra or {}
	local px = math.clamp(e[1] or (hx + 0.5), hx - 0.01, hx + 1.01)
	local py = math.clamp(e[2] or (hy + 0.5), hy - 0.01, hy + 1.01)
	local pz = math.clamp(e[3] or (hz + 0.5), hz - 0.01, hz + 1.01)
	local root = player.Character and player.Character:FindFirstChild("HumanoidRootPart") :: BasePart?
	local look = if root then root.CFrame.LookVector else Vector3.new(0, 0, -1)
	local lx, lz = e[4] or look.X, e[5] or look.Z
	local changes, reason = Placement.resolve(item.block, {
		hx = hx, hy = hy, hz = hz, nx = f[1], ny = f[2], nz = f[3], px = px, py = py, pz = pz, lx = lx, lz = lz,
	}, WorldService.getBlock)
	if not changes then
		reject(reason or "can't place here")
		return true
	end
	for _, c in changes do
		if c.y < 0 or c.y >= H then
			reject("out of the world")
			return true
		end
		if BlockRegistry.isSolid[c.id + 1] then
			local overlap, byOther = overlapsCharacter(c.x, c.y, c.z, player)
			if overlap then
				if not byOther and not retry then
					if #deferred < 64 then
						table.insert(deferred, { player = player, x = x, y = y, z = z, untilT = os.clock() + DEFER_SECONDS, face = f, extra = extra })
					else
						reject("too many pending placements")
					end
					return true
				elseif not byOther and retry then
					return false -- still waiting (the caller times out)
				end
				reject("would overlap a player")
				return true
			end
		end
	end
	local st = stack :: InventoryService.Stack
	if st.count < 1 then
		reject("no item")
		return true
	end
	st.count -= 1
	InventoryService.setSlot(player, slot, if st.count > 0 then st else nil)
	for _, c in changes do
		local key = WorldService.setBlock(c.x, c.y, c.z, c.id)
		local kind = BlockEntityService.kindOf(c.id)
		if kind then
			BlockEntityService.ensure(c.x, c.y, c.z, kind)
		end
		broadcast(key, c.x, c.y, c.z, c.id, player)
	end
	if changes[1].x ~= x or changes[1].y ~= y or changes[1].z ~= z then
		-- the client predicted another cell (a slab merged into the clicked one): send the truth
		Remotes.get("BlockChanged"):FireClient(player, x, y, z, WorldService.getBlock(x, y, z))
	end
	BlockActionService.stats.accepted += 1
	for _, fn in placedListeners do
		fn(player, changes[1].x, changes[1].y, changes[1].z, changes[1].id)
	end
	return true
end

-- Right-click on a block that reacts (wooden doors).
local function interact(player: Player, x: number, y: number, z: number)
	local eye = eyeOf(player)
	if not eye then
		return
	end
	local id = WorldService.getBlock(x, y, z)
	local def = BlockRegistry.byId[id]
	local ok, why = canReach(eye, x, y, z, false)
	if not ok then
		return correct(player, x, y, z, why)
	end
	-- trapdoors and fence gates
	if def and (def.shape == "trapdoor" or def.shape == "fence_gate") then
		local root = player.Character and player.Character:FindFirstChild("HumanoidRootPart") :: BasePart?
		local look = if root then root.CFrame.LookVector else Vector3.new(0, 0, -1)
		local nextId = Placement.toggle(id, look.X, look.Z)
		if not nextId then
			return correct(player, x, y, z, "doesn't open by hand")
		end
		local key = WorldService.setBlock(x, y, z, nextId)
		broadcast(key, x, y, z, nextId, player)
		BlockActionService.stats.accepted += 1
		return
	end
	if not def or def.shape ~= "door" or def.family == "iron_door" then
		return correct(player, x, y, z, "nothing to use")
	end
	-- the state lives in the lower half
	local ly = if def.state.upper then y - 1 else y
	local lower = WorldService.getBlock(x, ly, z)
	local toggled = Placement.toggledDoor(lower)
	if not toggled then
		return correct(player, x, y, z, "broken door")
	end
	local key = WorldService.setBlock(x, ly, z, toggled)
	broadcast(key, x, ly, z, toggled, player)
	BlockActionService.stats.accepted += 1
end

function BlockActionService.init()
	Remotes.get("BlockAction").OnServerEvent:Connect(function(player: Player, action: any, x: any, y: any, z: any, nx: any, ny: any, nz: any, extra: any)
		if typeof(action) ~= "string" or not isInt(x) or not isInt(y) or not isInt(z) then
			return
		end
		local st = state(player)
		if not allow(st) then
			return correct(player, x, y, z, "rate limited")
		end
		if y < 0 or y >= H then
			return
		end
		if action == "start" then
			st.pending = { x = x, y = y, z = z, t = os.clock(), item = heldItem(player) }
		elseif action == "cancel" then
			st.pending = nil
		elseif action == "finish" then
			finishBreak(player, st, x, y, z)
		elseif action == "place" then
			local face = if isInt(nx) and isInt(ny) and isInt(nz) and math.abs(nx) + math.abs(ny) + math.abs(nz) == 1
				then { nx, ny, nz }
				else nil
			local ex: { number }? = nil
			if typeof(extra) == "table" then
				local list = {}
				for i = 1, 6 do
					local v = extra[i]
					list[i] = if typeof(v) == "number" and v == v and math.abs(v) < 2 ^ 24 then v else nil
				end
				ex = list
			end
			place(player, x, y, z, nil, face, ex)
		elseif action == "interact" then
			interact(player, x, y, z)
		end
	end)
	Players.PlayerRemoving:Connect(function(p)
		states[p] = nil
		history[p] = nil
	end)
	game:GetService("RunService").Heartbeat:Connect(function()
		local now = os.clock()
		for _, p in Players:GetPlayers() do
			local character = p.Character
			local root = character and character:FindFirstChild("HumanoidRootPart") :: BasePart?
			if root then
				local h = history[p] or {}
				history[p] = h
				table.insert(h, { t = now, p = root.Position })
				while #h > 0 and now - h[1].t > HISTORY_SECONDS do
					table.remove(h, 1)
				end
			end
		end
		for i = #deferred, 1, -1 do
			local d = deferred[i]
			if not d.player.Parent then
				table.remove(deferred, i)
			elseif place(d.player, d.x, d.y, d.z, true, d.face, d.extra) then
				table.remove(deferred, i)
			elseif now > d.untilT then
				table.remove(deferred, i)
				correct(d.player, d.x, d.y, d.z, "would overlap a player")
				if d.y + 1 < H then -- a predicted door top half
					Remotes.get("BlockChanged"):FireClient(d.player, d.x, d.y + 1, d.z, WorldService.getBlock(d.x, d.y + 1, d.z))
				end
			end
		end
	end)
end

-- (exposed for the debug overlay / future tests)
BlockActionService.chunkKeyOf = function(x: number, z: number): number
	local cx, cz = ChunkData.worldToChunk(x, z)
	return ChunkData.key(cx, cz)
end

return BlockActionService
