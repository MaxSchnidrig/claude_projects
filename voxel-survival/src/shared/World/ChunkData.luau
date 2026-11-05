--!strict
--!native
-- Chunk storage: 16 x 128 x 16 block IDs in one 32 KB buffer (1 byte per block).
--
-- Layout: index = x + z * 16 + y * 256   (x, z in 0..15, y in 0..127)
-- A horizontal 16x16 layer is contiguous, and a 16-high render section is a contiguous 4 KB slice.

local Config = require(script.Parent.Parent.Config)

local CS = Config.CHUNK_SIZE
local H = Config.WORLD_HEIGHT
local LAYER = CS * CS
local VOLUME = LAYER * H

export type Chunk = {
	cx: number,
	cz: number,
	blocks: buffer,
	biomes: buffer, -- 16x16 biome ids (u8), index x + z * 16
	heights: buffer, -- 16x16 generated surface height (u8), index x + z * 16
	-- Server: block edits relative to the seed, idx -> id. Client: diffs received from server.
	diffs: { [number]: number },
	generated: boolean,
}

local ChunkData = {}
ChunkData.VOLUME = VOLUME
ChunkData.LAYER = LAYER

function ChunkData.new(cx: number, cz: number): Chunk
	return {
		cx = cx,
		cz = cz,
		blocks = buffer.create(VOLUME),
		biomes = buffer.create(LAYER),
		heights = buffer.create(LAYER),
		diffs = {},
		generated = false,
	}
end

-- Numeric key for a chunk coordinate (faster than string keys in hash tables).
-- Valid for |cx|, |cz| < 2^20 (≈ 50 million blocks), far beyond anything we stream.
function ChunkData.key(cx: number, cz: number): number
	return (cx + 1048576) * 2097152 + (cz + 1048576)
end

function ChunkData.unkey(key: number): (number, number)
	local cz = key % 2097152
	local cx = (key - cz) / 2097152
	return cx - 1048576, cz - 1048576
end

function ChunkData.index(x: number, y: number, z: number): number
	return x + z * CS + y * LAYER
end

function ChunkData.unindex(idx: number): (number, number, number)
	local x = idx % CS
	local z = (idx // CS) % CS
	local y = idx // LAYER
	return x, y, z
end

-- Local coordinates; returns 0 (air) outside the vertical range.
function ChunkData.get(chunk: Chunk, x: number, y: number, z: number): number
	if y < 0 or y >= H then
		return 0
	end
	return buffer.readu8(chunk.blocks, x + z * CS + y * LAYER)
end

function ChunkData.set(chunk: Chunk, x: number, y: number, z: number, id: number)
	buffer.writeu8(chunk.blocks, x + z * CS + y * LAYER, id)
end

-- World block coordinate -> chunk coordinate + local coordinate.
function ChunkData.worldToChunk(wx: number, wz: number): (number, number, number, number)
	local cx = wx // CS
	local cz = wz // CS
	return cx, cz, wx - cx * CS, wz - cz * CS
end

-- Diff packing for the network / DataStore: sequence of (u16 index, u8 id) records.
function ChunkData.packDiffs(diffs: { [number]: number }): string
	local parts = {}
	for idx, id in diffs do
		table.insert(parts, string.pack("<I2B", idx, id))
	end
	return table.concat(parts)
end

function ChunkData.unpackDiffs(data: string): { [number]: number }
	local out = {}
	local pos = 1
	local n = #data
	while pos + 2 <= n do
		local idx, id, nextPos = string.unpack("<I2B", data, pos)
		out[idx] = id
		pos = nextPos
	end
	return out
end

-- Apply a diff table onto the generated blocks.
function ChunkData.applyDiffs(chunk: Chunk, diffs: { [number]: number })
	for idx, id in diffs do
		buffer.writeu8(chunk.blocks, idx, id)
		chunk.diffs[idx] = id
	end
end

return ChunkData
