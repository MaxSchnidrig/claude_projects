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

local BS = Config.BLOCK_SIZE
local H = Config.WORLD_HEIGHT
local AIR = 0
local isLiquid = BlockRegistry.isLiquid

local BlockActionService = {}
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
	return (root.Position + Vector3.new(0, Config.EYE_HEIGHT, 0)) / BS
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
local function canReach(eye: Vector3, x: number, y: number, z: number, forPlace: boolean): (boolean, string)
	local center = Vector3.new(x + 0.5, y + 0.5, z + 0.5)
	local maxDist = Config.REACH + Config.REACH_TOLERANCE
	if (center - eye).Magnitude > maxDist + 0.87 then -- 0.87 = half the cube diagonal
		return false, "out of reach"
	end
	for _, o in SAMPLES do
		local target = Vector3.new(x, y, z) + o
		local dir = target - eye
		local dist = dir.Magnitude
		if dist <= maxDist then
			local hit = VoxelRaycast.cast(getBlock, eye.X, eye.Y, eye.Z, dir.X, dir.Y, dir.Z, dist + 0.01, stopsRay)
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

-- Would a block at this cell overlap any character? (Characters are ~2 studs wide, 5 tall.)
local function overlapsCharacter(x: number, y: number, z: number): boolean
	local minP = Vector3.new(x, y, z) * BS
	local maxP = minP + Vector3.one * BS
	for _, player in Players:GetPlayers() do
		local character = player.Character
		local root = character and character:FindFirstChild("HumanoidRootPart") :: BasePart?
		if root then
			local p = root.Position
			local cMin = Vector3.new(p.X - 0.9, p.Y - 2.95, p.Z - 0.9)
			local cMax = Vector3.new(p.X + 0.9, p.Y + 2.0, p.Z + 0.9)
			if cMin.X < maxP.X and cMax.X > minP.X and cMin.Y < maxP.Y and cMax.Y > minP.Y and cMin.Z < maxP.Z and cMax.Z > minP.Z then
				return true
			end
		end
	end
	return false
end

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

	-- Apply: block -> air, drops into the inventory, tool wear.
	local key = WorldService.setBlock(x, y, z, AIR)
	local def = BlockRegistry.get(id)
	if def and def.drop and Mining.canHarvest(id, item) then
		local count = if def.dropMax > def.dropMin then math.random(def.dropMin, def.dropMax) else def.dropMin
		InventoryService.add(player, def.drop, count)
	end
	if Mining.usesDurability(id, item) then
		InventoryService.damageSelectedTool(player, 1)
	end
	BlockActionService.stats.accepted += 1
	broadcast(key, x, y, z, AIR, player)
end

local function place(player: Player, x: number, y: number, z: number)
	local eye = eyeOf(player)
	if not eye then
		return correct(player, x, y, z, "no character")
	end
	local stack = InventoryService.selectedStack(player)
	local item = stack and ItemRegistry.get(stack.item)
	if not item or not item.block then
		return correct(player, x, y, z, "not holding a block")
	end
	local current = WorldService.getBlock(x, y, z)
	if current ~= AIR and not isLiquid[current + 1] then
		return correct(player, x, y, z, "cell occupied")
	end
	-- must be placed against an existing block
	local supported = false
	for _, d in BlockRegistry.DIR_VECTORS do
		local n = WorldService.getBlock(x + d[1], y + d[2], z + d[3])
		if n ~= AIR and not isLiquid[n + 1] then
			supported = true
			break
		end
	end
	if not supported then
		return correct(player, x, y, z, "nothing to place against")
	end
	local ok, why = canReach(eye, x, y, z, true)
	if not ok then
		return correct(player, x, y, z, why)
	end
	if BlockRegistry.isSolid[item.block + 1] and overlapsCharacter(x, y, z) then
		return correct(player, x, y, z, "would overlap a player")
	end
	if not InventoryService.consumeSelected(player, 1) then
		return correct(player, x, y, z, "no item")
	end
	local key = WorldService.setBlock(x, y, z, item.block)
	BlockActionService.stats.accepted += 1
	broadcast(key, x, y, z, item.block, player)
end

function BlockActionService.init()
	Remotes.get("BlockAction").OnServerEvent:Connect(function(player: Player, action: any, x: any, y: any, z: any)
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
			place(player, x, y, z)
		end
	end)
	Players.PlayerRemoving:Connect(function(p)
		states[p] = nil
	end)
end

-- (exposed for the debug overlay / future tests)
BlockActionService.chunkKeyOf = function(x: number, z: number): number
	local cx, cz = ChunkData.worldToChunk(x, z)
	return ChunkData.key(cx, cz)
end

return BlockActionService
