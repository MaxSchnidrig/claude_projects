--!strict
-- Save data layout (pure: no DataStore calls; tested headless).
--
-- One DataStore per environment (live / Studio). Keys:
--   w:<ownerId>:meta            world: seed, reserved-server code, friends setting, time, region index
--   w:<ownerId>:r:<rx>:<rz>     region of 4 x 4 chunks: changed blocks (packed diffs, Base64) and
--                               the chests/furnaces in it
--   w:<ownerId>:p:<userId>      a player's state in this world: inventory, health, hunger, air,
--                               position (inventories are per world, like separate save files)
--   srv:<privateServerId>       which world a reserved server runs: { owner, world } (older saves:
--                               just the owner's id, meaning their first world)
--   u:<ownerId>:worlds          the owner's world list (Phase 8d): { next, worlds = { worldKey } }
--   u:<userId>:settings         a player's own options (render distance, FOV, volumes, ...)
--
-- A world is named by its world key: the owner's first world is just "<ownerId>" (so worlds
-- saved before the world list keep their keys), later ones "<ownerId>_<n>". The w:<...> keys
-- above take that world key.
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

-- `world`: a world key (see the header); a plain owner id means that owner's first world.
function SaveFormat.metaKey(world: string | number): string
	return `w:{world}:meta`
end

function SaveFormat.regionKey(world: string | number, rx: number, rz: number): string
	return `w:{world}:r:{rx}:{rz}`
end

function SaveFormat.playerKey(world: string | number, userId: number): string
	return `w:{world}:p:{userId}`
end

-- World list -----------------------------------------------------------------------------------

SaveFormat.MAX_WORLDS = 10
SaveFormat.MAX_NAME = 32

function SaveFormat.worldsKey(ownerId: number): string
	return `u:{ownerId}:worlds`
end

function SaveFormat.settingsKey(userId: number): string
	return `u:{userId}:settings`
end

function SaveFormat.mainWorld(ownerId: number): string
	return tostring(ownerId)
end

-- Is `key` one of this owner's world keys? (Never trust a key a client sends.)
function SaveFormat.isOwnWorld(ownerId: number, key: any): boolean
	if typeof(key) ~= "string" then
		return false
	end
	local main = tostring(ownerId)
	if key == main then
		return true
	end
	local n = string.match(key, "^" .. main .. "_(%d+)$")
	return n ~= nil and #n <= 6
end

-- The owner of a world key.
function SaveFormat.ownerOf(key: string): number?
	return tonumber(string.match(key, "^(%d+)"))
end

export type WorldList = { next: number, worlds: { string } }

-- A stored list (or nothing). `hasMain`: the owner's first world exists (a world saved before
-- world lists): it becomes the list's first entry.
function SaveFormat.decodeWorldList(v: any, ownerId: number, hasMain: boolean): WorldList
	local out: WorldList = { next = 2, worlds = {} }
	if typeof(v) == "table" and typeof(v.worlds) == "table" then
		local seen = {}
		for _, key in v.worlds do
			if SaveFormat.isOwnWorld(ownerId, key) and not seen[key] and #out.worlds < SaveFormat.MAX_WORLDS then
				seen[key] = true
				table.insert(out.worlds, key)
			end
		end
		if typeof(v.next) == "number" and v.next % 1 == 0 and v.next >= 2 then
			out.next = v.next
		end
		return out
	end
	if hasMain then
		out.worlds = { SaveFormat.mainWorld(ownerId) }
	end
	return out
end

function SaveFormat.encodeWorldList(l: WorldList): any
	return { v = SaveFormat.VERSION, next = l.next, worlds = table.clone(l.worlds) }
end

-- A new world's key; advances l.next.
function SaveFormat.newWorldKey(l: WorldList, ownerId: number): string
	local key = `{ownerId}_{l.next}`
	l.next += 1
	return key
end

-- srv:<psid> record -> owner and world key.
function SaveFormat.decodeServer(v: any): (number?, string?)
	if typeof(v) == "number" then
		return v, SaveFormat.mainWorld(v)
	elseif typeof(v) == "table" and typeof(v.owner) == "number" and SaveFormat.isOwnWorld(v.owner, v.world) then
		return v.owner, v.world
	end
	return nil, nil
end

-- A world name as typed: trimmed, one line, at most MAX_NAME characters; nil if empty.
function SaveFormat.cleanName(text: any): string?
	if typeof(text) ~= "string" then
		return nil
	end
	local t = string.gsub(text, "[%c]", " ")
	t = string.match(t, "^%s*(.-)%s*$") or ""
	if utf8.len(t) == nil then
		return nil
	end
	if (utf8.len(t) :: number) > SaveFormat.MAX_NAME then
		t = string.sub(t, 1, utf8.offset(t, SaveFormat.MAX_NAME + 1) - 1)
	end
	return if t == "" then nil else t
end

-- Java's world seed from the "Seed" box: a whole number is used as is, any other text becomes
-- its String.hashCode(); stored as 0 .. 2^32 - 1. nil for an empty box (a random seed).
function SaveFormat.seedFromText(text: any): number?
	if typeof(text) ~= "string" then
		return nil
	end
	local t = string.match(text, "^%s*(.-)%s*$") or ""
	if t == "" then
		return nil
	end
	local n = tonumber(t)
	if n and n % 1 == 0 and string.match(t, "^%-?%d+$") then
		return n % 4294967296
	end
	local h = 0
	for _, c in utf8.codes(t) do
		if c > 0xFFFF then -- Java hashes UTF-16 code units: a surrogate pair
			local v = c - 0x10000
			h = (h * 31 + 0xD800 + v // 0x400) % 4294967296
			h = (h * 31 + 0xDC00 + v % 0x400) % 4294967296
		else
			h = (h * 31 + c) % 4294967296
		end
	end
	return h
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
	bed: Vector3?, -- respawn point: the bed's head block (Phase 8c)
	sinceRest: number?, -- ticks since the player last slept (the insomnia counter)
	spectator: boolean?, -- died in a Hardcore world: only watches from now on (Phase 8d)
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
		bed = if p.bed then { p.bed.X, p.bed.Y, p.bed.Z } else nil,
		rest = p.sinceRest,
		spec = if p.spectator then true else nil,
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
		bed = if typeof(record.bed) == "table" and typeof(record.bed[1]) == "number" and typeof(record.bed[2]) == "number"
				and typeof(record.bed[3]) == "number"
			then Vector3.new(math.floor(record.bed[1]), math.floor(record.bed[2]), math.floor(record.bed[3]))
			else nil,
		sinceRest = num(record.rest, 0, 0, 1e9),
		spectator = record.spec == true,
	}
end

return SaveFormat
