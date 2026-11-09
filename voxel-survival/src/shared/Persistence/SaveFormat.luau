--!strict
-- Save data layout (pure: no DataStore calls; tested headless).
--
-- One DataStore per environment (live / Studio). Keys:
--   w:<ownerId>:meta            world: seed, reserved-server code, friends setting, time, region index
--   w:<ownerId>:r:<rx>:<rz>     region of 4 x 4 chunks: changed blocks (packed diffs, Base64) and
--                               the chests/furnaces in it
--   w:<ownerId>:p:<userId>      a player's state in this world: inventory, health, hunger, air,
--                               position (inventories are per world, like separate save files)
--   srv:<privateServerId>       which owner a reserved server belongs to
--
-- Every record carries `v` (format version) so later phases can migrate old saves.

local ChunkData = require(script.Parent.Parent.World.ChunkData)
local ItemRegistry = require(script.Parent.Parent.Items.ItemRegistry)
local Base64 = require(script.Parent.Parent.Util.Base64)
local Config = require(script.Parent.Parent.Config)

local SaveFormat = {}

-- 1: world height 0..127 (2-byte diff indices); 2: Java height, internal y 0..383 (3-byte
-- indices); 3: block ids are u16 (Phase 8b, more than 255 block states). Older saves are converted
-- on load: version 1 moves everything up by Config.Y_OFFSET, versions 1-2 read 1-byte ids.
SaveFormat.VERSION = 3
local LAYER = Config.CHUNK_SIZE * Config.CHUNK_SIZE
local SHIFT = Config.Y_OFFSET

-- Version-1 diffs: 2-byte index + id, y in 0..127.
local function unpackV1(data: string): { [number]: number }
	local out = {}
	local pos = 1
	while pos + 2 <= #data do
		local idx, id, nextPos = string.unpack("<I2B", data, pos)
		out[idx + SHIFT * LAYER] = id
		pos = nextPos
	end
	return out
end
-- Version-2 diffs: 3-byte index + 1-byte id.
local function unpackV2(data: string): { [number]: number }
	local out = {}
	local pos = 1
	while pos + 3 <= #data do
		local idx, id, nextPos = string.unpack("<I3B", data, pos)
		out[idx] = id
		pos = nextPos
	end
	return out
end
SaveFormat.REGION_CHUNKS = 4 -- region = 4 x 4 chunks (64 x 64 blocks)

export type Stack = { item: string, count: number, durability: number? }

function SaveFormat.metaKey(ownerId: number): string
	return `w:{ownerId}:meta`
end

function SaveFormat.regionKey(ownerId: number, rx: number, rz: number): string
	return `w:{ownerId}:r:{rx}:{rz}`
end

function SaveFormat.playerKey(ownerId: number, userId: number): string
	return `w:{ownerId}:p:{userId}`
end

function SaveFormat.serverKey(privateServerId: string): string
	return `srv:{privateServerId}`
end

function SaveFormat.regionOf(cx: number, cz: number): (number, number)
	return cx // SaveFormat.REGION_CHUNKS, cz // SaveFormat.REGION_CHUNKS
end

function SaveFormat.regionId(rx: number, rz: number): string
	return `{rx},{rz}`
end

-- Stacks ------------------------------------------------------------------------------------

-- Sparse slot table -> list of { index, item, count, durability? }.
function SaveFormat.encodeStacks(slots: { [number]: Stack? }): { { any } }
	local out = {}
	for i, s in slots do
		if s and s.count > 0 then
			table.insert(out, { i, s.item, s.count, s.durability })
		end
	end
	table.sort(out, function(a, b)
		return a[1] < b[1]
	end)
	return out
end

-- Back to a slot table. Unknown items, bad counts and out-of-range slots are dropped.
function SaveFormat.decodeStacks(list: any, maxSlot: number): { [number]: Stack }
	local out: { [number]: Stack } = {}
	if typeof(list) ~= "table" then
		return out
	end
	for _, e in list do
		if typeof(e) == "table" then
			local i, item, count, durability = e[1], e[2], e[3], e[4]
			if typeof(i) == "number" and i % 1 == 0 and i >= 1 and i <= maxSlot
				and typeof(item) == "string" and ItemRegistry.get(item)
				and typeof(count) == "number" and count % 1 == 0 and count >= 1 and count <= 64
			then
				out[i] = {
					item = item,
					count = count,
					durability = if typeof(durability) == "number" then durability else nil,
				}
			end
		end
	end
	return out
end

-- Regions -----------------------------------------------------------------------------------

export type EntityRecord = {
	kind: string,
	x: number,
	y: number,
	z: number,
	slots: { [number]: Stack },
	burn: number,
	burnMax: number,
	progress: number,
	data: { [string]: any }?, -- signs: { front = {4 lines}, back = {4 lines} }; item frames: { facing, rot }
}

export type Region = {
	chunks: { [number]: { [number]: number } }, -- chunk key -> diffs (block index -> id)
	entities: { EntityRecord },
}

function SaveFormat.encodeRegion(region: Region): { [string]: any }
	local chunks = {}
	for key, diffs in region.chunks do
		if next(diffs) ~= nil then
			local cx, cz = ChunkData.unkey(key)
			chunks[`{cx},{cz}`] = Base64.encode(ChunkData.packDiffs(diffs))
		end
	end
	local entities = {}
	for _, e in region.entities do
		table.insert(entities, {
			k = e.kind,
			x = e.x,
			y = e.y,
			z = e.z,
			s = SaveFormat.encodeStacks(e.slots),
			b = if e.burn > 0 then e.burn else nil,
			bm = if e.burnMax > 0 then e.burnMax else nil,
			p = if e.progress > 0 then e.progress else nil,
			d = e.data,
		})
	end
	return { v = SaveFormat.VERSION, chunks = chunks, entities = entities }
end

-- Sign lines / item frame placement, checked (saves are data, not trusted structure).
local FACES = { up = true, down = true, north = true, south = true, east = true, west = true }
function SaveFormat.decodeData(kind: string, d: any): { [string]: any }?
	if typeof(d) ~= "table" then
		return nil
	end
	if kind == "sign" then
		local function lines(t: any): { string }
			local out = { "", "", "", "" }
			if typeof(t) == "table" then
				for i = 1, 4 do
					if typeof(t[i]) == "string" then
						out[i] = string.sub(t[i], 1, 200)
					end
				end
			end
			return out
		end
		return { front = lines(d.front), back = lines(d.back) }
	elseif kind == "item_frame" then
		return {
			facing = if typeof(d.facing) == "string" and FACES[d.facing] then d.facing else "up",
			rot = if typeof(d.rot) == "number" then math.clamp(math.floor(d.rot), 0, 7) else 0,
			glow = d.glow == true,
		}
	end
	return nil
end

function SaveFormat.decodeRegion(record: any): Region
	local out: Region = { chunks = {}, entities = {} }
	if typeof(record) ~= "table" then
		return out
	end
	local legacy = record.v == nil or record.v < 2
	local dy = if legacy then SHIFT else 0
	if typeof(record.chunks) == "table" then
		for name, text in record.chunks do
			local cx, cz = string.match(tostring(name), "^(%-?%d+),(%-?%d+)$")
			local raw = if typeof(text) == "string" then Base64.decode(text) else nil
			if cx and cz and raw then
				out.chunks[ChunkData.key(tonumber(cx) :: number, tonumber(cz) :: number)] =
					if legacy then unpackV1(raw) elseif record.v == 2 then unpackV2(raw) else ChunkData.unpackDiffs(raw)
			end
		end
	end
	if typeof(record.entities) == "table" then
		for _, e in record.entities do
			if typeof(e) == "table" and (e.k == "chest" or e.k == "furnace" or e.k == "campfire" or e.k == "sign" or e.k == "item_frame")
				and typeof(e.x) == "number" and typeof(e.y) == "number" and typeof(e.z) == "number"
			then
				table.insert(out.entities, {
					kind = e.k,
					x = e.x,
					y = e.y + dy,
					z = e.z,
					slots = SaveFormat.decodeStacks(e.s, if e.k == "chest" then 27 elseif e.k == "campfire" then 4
						elseif e.k == "item_frame" then 1 elseif e.k == "sign" then 0 else 3),
					data = SaveFormat.decodeData(e.k, e.d),
					burn = if typeof(e.b) == "number" then e.b else 0,
					burnMax = if typeof(e.bm) == "number" then e.bm else 0,
					progress = if typeof(e.p) == "number" then e.p else 0,
				})
			end
		end
	end
	return out
end

-- Players -----------------------------------------------------------------------------------

export type PlayerState = {
	slots: { [number]: Stack },
	selected: number,
	health: number,
	food: number,
	saturation: number,
	exhaustion: number,
	air: number,
	pos: Vector3?, -- feet, block units
	yaw: number,
}

function SaveFormat.encodePlayer(p: PlayerState): { [string]: any }
	return {
		v = SaveFormat.VERSION,
		slots = SaveFormat.encodeStacks(p.slots),
		sel = p.selected,
		hp = p.health,
		food = p.food,
		sat = p.saturation,
		exh = p.exhaustion,
		air = p.air,
		pos = if p.pos then { p.pos.X, p.pos.Y, p.pos.Z } else nil,
		yaw = p.yaw,
	}
end

local function num(v: any, default: number, lo: number, hi: number): number
	if typeof(v) ~= "number" or v ~= v then
		return default
	end
	return math.clamp(v, lo, hi)
end

function SaveFormat.decodePlayer(record: any, inventorySlots: number): PlayerState?
	if typeof(record) ~= "table" then
		return nil
	end
	local pos: Vector3? = nil
	local p = record.pos
	if typeof(p) == "table" and typeof(p[1]) == "number" and typeof(p[2]) == "number" and typeof(p[3]) == "number" then
		local legacy = record.v == nil or record.v < 2
		pos = Vector3.new(p[1], p[2] + (if legacy then SHIFT else 0), p[3])
	end
	return {
		slots = SaveFormat.decodeStacks(record.slots, inventorySlots),
		selected = math.floor(num(record.sel, 1, 1, 9)),
		health = num(record.hp, 20, 0, 20),
		food = math.floor(num(record.food, 20, 0, 20)),
		saturation = num(record.sat, 5, 0, 20),
		exhaustion = num(record.exh, 0, 0, 4),
		air = num(record.air, 15, 0, 15),
		pos = pos,
		yaw = num(record.yaw, 0, -1000, 1000),
	}
end

return SaveFormat
