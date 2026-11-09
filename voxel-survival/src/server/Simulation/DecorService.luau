--!strict
-- Signs, item frames, and blocks that need something to hang on (Phase 8b).
--
-- Signs: text lives in the sign's block entity ({ front = 4 lines, back = 4 lines }). Placing a
-- sign opens the editor for its front; right-clicking one edits the side you look at. Every text
-- goes through Roblox's TextService filter before it is stored or shown to anyone; if filtering
-- fails, the edit is dropped.
--
-- Item frames (and glow item frames, whose item is shown at full brightness): entities hanging on a block face (not blocks, like Java). Right-click: put the
-- held item in (one), or turn the item 45 degrees. Left-click: knock the item out, or break the
-- empty frame. A frame drops when its block goes away or a block fills its cell.
--
-- Support: ladders, signs and doors break when what holds them is removed (Placement.supported).

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TextService = game:GetService("TextService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared.Config)
local Remotes = require(Shared.Net.Remotes)
local BlockRegistry = require(Shared.Blocks.BlockRegistry)
local Placement = require(Shared.Blocks.Placement)
local ItemRegistry = require(Shared.Items.ItemRegistry)
local WorldService = require(script.Parent.Parent.World.WorldService)
local BlockUpdates = require(script.Parent.Parent.World.BlockUpdates)
local BlockEntityService = require(script.Parent.Parent.World.BlockEntityService)
local ItemEntityService = require(script.Parent.Parent.World.ItemEntityService)
local InventoryService = require(script.Parent.Parent.Player.InventoryService)
local BlockActionService = require(script.Parent.Parent.Interaction.BlockActionService)

local BS = Config.BLOCK_SIZE
local DecorService = {}

local MAX_LINE = 18 -- characters per sign line (Java limits by width, about this many)
local FACE_DIR: { [string]: { number } } = {
	up = { 0, 1, 0 }, down = { 0, -1, 0 }, north = { 0, 0, -1 }, south = { 0, 0, 1 }, east = { 1, 0, 0 }, west = { -1, 0, 0 },
}

local function remote(): RemoteEvent
	return Remotes.get("Decor")
end

local function getBlock(x: number, y: number, z: number): number?
	return WorldService.getBlockIfLoaded(x, y, z)
end

local SIGN_SHAPES = { sign = true, wall_sign = true, hanging_sign = true, wall_hanging_sign = true }
local function isSign(id: number?): boolean
	local d = id and BlockRegistry.byId[id]
	return d ~= nil and SIGN_SHAPES[d.shape] == true
end
-- Java fits less text on hanging signs.
local function maxLineOf(id: number?): number
	local d = id and BlockRegistry.byId[id]
	return if d and (d.shape == "hanging_sign" or d.shape == "wall_hanging_sign") then 12 else MAX_LINE
end

local function near(player: Player, pos: Vector3, blocks: number): boolean
	local c = player.Character
	local root = c and c:FindFirstChild("HumanoidRootPart") :: BasePart?
	return root ~= nil and (root.Position / BS - pos).Magnitude <= blocks
end

-- Signs ----------------------------------------------------------------------------------------

local function signMessage(e: BlockEntityService.Entity): { [string]: any }
	local d = e.data or {}
	return { type = "sign", x = e.x, y = e.y, z = e.z, front = d.front or { "", "", "", "" }, back = d.back or { "", "", "", "" } }
end

local function cleanLine(v: any, maxLen: number): string
	if typeof(v) ~= "string" then
		return ""
	end
	local s = string.gsub(v, "[%c]", "") -- no control characters / newlines
	if utf8.len(s) == nil then
		return ""
	end
	if (utf8.len(s) :: number) > maxLen then
		s = string.sub(s, 1, (utf8.offset(s, maxLen + 1) :: number) - 1)
	end
	return s
end

-- Roblox text filter for text other players will see. nil when filtering failed.
local function filter(player: Player, lines: { string }): { string }?
	local joined = table.concat(lines, "\n")
	if string.match(joined, "^%s*$") then
		return { "", "", "", "" }
	end
	local ok, result = pcall(function()
		return TextService:FilterStringAsync(joined, player.UserId, Enum.TextFilterContext.PublicChat)
	end)
	if not ok or not result then
		return nil
	end
	local ok2, text = pcall(function()
		return (result :: TextFilterResult):GetNonChatStringForBroadcastAsync()
	end)
	if not ok2 or typeof(text) ~= "string" then
		return nil
	end
	local out = { "", "", "", "" }
	local i = 1
	for line in string.gmatch(text .. "\n", "(.-)\n") do
		if i > 4 then
			break
		end
		out[i] = line
		i += 1
	end
	return out
end

local function onSignEdit(player: Player, m: any)
	local x, y, z = m.x, m.y, m.z
	if typeof(x) ~= "number" or typeof(y) ~= "number" or typeof(z) ~= "number" or typeof(m.lines) ~= "table" then
		return
	end
	if not isSign(getBlock(x, y, z)) or not near(player, Vector3.new(x + 0.5, y + 0.5, z + 0.5), 8) then
		return
	end
	local side = if m.side == "back" then "back" else "front"
	local lines = {}
	for i = 1, 4 do
		lines[i] = cleanLine(m.lines[i], maxLineOf(getBlock(x, y, z)))
	end
	local filtered = filter(player, lines)
	if not filtered then
		warn("[DecorService] sign text could not be filtered; edit dropped")
		return
	end
	local e = BlockEntityService.ensure(x, y, z, "sign")
	local d = e.data or { front = { "", "", "", "" }, back = { "", "", "", "" } }
	d[side] = filtered
	e.data = d
	BlockEntityService.markDirty(x, z)
	remote():FireAllClients(signMessage(e))
end

-- Item frames ----------------------------------------------------------------------------------

local function frameMessage(e: BlockEntityService.Entity): { [string]: any }
	local d = e.data or {}
	local s = e.slots[1]
	return { type = "frame", key = e.key, x = e.x, y = e.y, z = e.z, facing = d.facing, rot = d.rot or 0, item = if s then s.item else nil, glow = d.glow == true }
end

local function frameCentre(e: BlockEntityService.Entity): Vector3
	local d = FACE_DIR[(e.data or {}).facing or "up"]
	return (Vector3.new(e.x + 0.5, e.y + 0.5, e.z + 0.5) - Vector3.new(d[1], d[2], d[3]) * 0.45) * BS
end

local function dropFrame(e: BlockEntityService.Entity)
	local k = e.key :: string
	BlockEntityService.removeKeyed(k)
	local pos = frameCentre(e)
	local s = e.slots[1]
	if s then
		ItemEntityService.spawn({ item = s.item, count = 1, durability = s.durability }, pos)
	end
	ItemEntityService.spawn({ item = if (e.data or {}).glow then "glow_item_frame" else "item_frame", count = 1 }, pos)
	remote():FireAllClients({ type = "frameRemove", key = k })
end

local function framesAt(x: number, y: number, z: number): { BlockEntityService.Entity }
	local out = {}
	for face in FACE_DIR do
		local e = BlockEntityService.getKeyed(BlockEntityService.frameKey(x, y, z, face))
		if e then
			table.insert(out, e)
		end
	end
	return out
end

local function onFramePlace(player: Player, m: any)
	local x, y, z, nx, ny, nz = m.x, m.y, m.z, m.nx, m.ny, m.nz
	for _, v in { x, y, z, nx, ny, nz } do
		if typeof(v) ~= "number" or v % 1 ~= 0 then
			return
		end
	end
	if math.abs(nx) + math.abs(ny) + math.abs(nz) ~= 1 then
		return
	end
	local stack = InventoryService.selectedStack(player)
	if not stack or (stack.item ~= "item_frame" and stack.item ~= "glow_item_frame") then
		return
	end
	local glow = stack.item == "glow_item_frame"
	if not Placement.frameSupported(getBlock(x, y, z)) then
		return
	end
	local cx, cy, cz = x + nx, y + ny, z + nz
	local here = getBlock(cx, cy, cz)
	if here == nil or BlockRegistry.isSolid[here + 1] then
		return
	end
	if not near(player, Vector3.new(cx + 0.5, cy + 0.5, cz + 0.5), 7) then
		return
	end
	local facing = if ny == 1 then "up" elseif ny == -1 then "down" elseif nx == 1 then "east" elseif nx == -1 then "west"
		elseif nz == 1 then "south" else "north"
	local k = BlockEntityService.frameKey(cx, cy, cz, facing)
	if BlockEntityService.getKeyed(k) then
		return
	end
	if not InventoryService.consumeSelected(player, 1) then
		return
	end
	local e: BlockEntityService.Entity = { kind = "item_frame", x = cx, y = cy, z = cz, slots = {}, data = { facing = facing, rot = 0, glow = glow } }
	BlockEntityService.putKeyed(k, e)
	remote():FireAllClients(frameMessage(e))
end

local function onFrameUse(player: Player, m: any)
	if typeof(m.key) ~= "string" then
		return
	end
	local e = BlockEntityService.getKeyed(m.key)
	if not e or e.kind ~= "item_frame" or not near(player, frameCentre(e) / BS, 7) then
		return
	end
	local d = e.data or {}
	if e.slots[1] then
		d.rot = ((d.rot or 0) + 1) % 8
	else
		local stack = InventoryService.selectedStack(player)
		if not stack or not ItemRegistry.get(stack.item) then
			return
		end
		local item, durability = stack.item, stack.durability
		if not InventoryService.consumeSelected(player, 1) then
			return
		end
		e.slots[1] = { item = item, count = 1, durability = durability }
		d.rot = 0
	end
	e.data = d
	BlockEntityService.markDirty(e.x, e.z)
	remote():FireAllClients(frameMessage(e))
end

local function onFrameHit(player: Player, m: any)
	if typeof(m.key) ~= "string" then
		return
	end
	local e = BlockEntityService.getKeyed(m.key)
	if not e or e.kind ~= "item_frame" or not near(player, frameCentre(e) / BS, 7) then
		return
	end
	local s = e.slots[1]
	if s then
		e.slots[1] = nil
		ItemEntityService.spawn({ item = s.item, count = 1, durability = s.durability }, frameCentre(e))
		BlockEntityService.markDirty(e.x, e.z)
		remote():FireAllClients(frameMessage(e))
	else
		dropFrame(e)
	end
end

-- Support ----------------------------------------------------------------------------------------

local NEEDS_SUPPORT: { [number]: boolean } = {}
for id, d in BlockRegistry.byId do
	if d.shape == "ladder" or d.shape == "door" or d.shape == "vine" or SIGN_SHAPES[d.shape] then
		NEEDS_SUPPORT[id] = true
	end
end

function DecorService.init()
	BlockUpdates.onNeighbourChanged(function(x, y, z)
		local id = getBlock(x, y, z)
		if id and NEEDS_SUPPORT[id] then
			BlockUpdates.schedule(x, y, z, 1, "support")
		end
	end)
	BlockUpdates.register("support", function(x, y, z)
		local id = getBlock(x, y, z)
		if not id or not NEEDS_SUPPORT[id] then
			return
		end
		if BlockRegistry.byId[id].shape == "vine" then
			-- vines lose only the faces that lost their wall (no drop without shears)
			local keep = Placement.vineSupported(id, x, y, z, getBlock)
			if keep ~= id then
				BlockUpdates.set(x, y, z, keep)
			end
			return
		end
		local ok, drops = Placement.supported(id, x, y, z, getBlock)
		if ok then
			return
		end
		BlockUpdates.set(x, y, z, 0)
		local def = BlockRegistry.byId[id]
		if drops and def and def.drop then
			ItemEntityService.spawn({ item = def.drop, count = 1 }, Vector3.new(x + 0.5, y + 0.5, z + 0.5) * BS)
		end
	end)

	WorldService.onBlockChanged(function(x, y, z, old, new)
		-- a sign went away (broken, burnt, blown up, washed off): forget its text
		if isSign(old) and not isSign(new) then
			BlockEntityService.remove(x, y, z)
			remote():FireAllClients({ type = "signRemove", x = x, y = y, z = z })
		end
		-- frames hanging on this block lose their wall; frames in this cell get pushed out
		local solid = new ~= nil and BlockRegistry.isSolid[new + 1]
		if not solid then
			for face, d in FACE_DIR do
				local e = BlockEntityService.getKeyed(BlockEntityService.frameKey(x + d[1], y + d[2], z + d[3], face))
				if e then
					task.defer(dropFrame, e)
				end
			end
		else
			for _, e in framesAt(x, y, z) do
				task.defer(dropFrame, e)
			end
		end
	end)

	-- a placed sign starts blank and opens its editor for the placer
	BlockActionService.onPlaced(function(player, x, y, z, id)
		if isSign(id) then
			local e = BlockEntityService.ensure(x, y, z, "sign")
			e.data = { front = { "", "", "", "" }, back = { "", "", "", "" } }
			remote():FireAllClients(signMessage(e))
			remote():FireClient(player, { type = "signEditor", x = x, y = y, z = z, side = "front" })
		end
	end)

	-- restored from a save: tell everyone
	BlockEntityService.onRestore(function(e)
		if e.kind == "sign" then
			remote():FireAllClients(signMessage(e))
		elseif e.kind == "item_frame" then
			remote():FireAllClients(frameMessage(e))
		end
	end)
	-- joining players get every sign and frame the server knows
	Players.PlayerAdded:Connect(function(p)
		task.wait(2)
		for _, e in BlockEntityService.ofKind("sign") do
			remote():FireClient(p, signMessage(e))
		end
		for _, e in BlockEntityService.ofKind("item_frame") do
			remote():FireClient(p, frameMessage(e))
		end
	end)

	local last: { [Player]: number } = {}
	Players.PlayerRemoving:Connect(function(p)
		last[p] = nil
	end)
	remote().OnServerEvent:Connect(function(player: Player, m: any)
		if typeof(m) ~= "table" then
			return
		end
		local now = os.clock()
		if now - (last[player] or 0) < 0.12 then
			return -- rate limit (sign edits also cost a filter call)
		end
		last[player] = now
		if m.type == "signEdit" then
			onSignEdit(player, m)
		elseif m.type == "framePlace" then
			onFramePlace(player, m)
		elseif m.type == "frameUse" then
			onFrameUse(player, m)
		elseif m.type == "frameHit" then
			onFrameHit(player, m)
		end
	end)
end

return DecorService
