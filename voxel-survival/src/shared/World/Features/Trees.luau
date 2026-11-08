--!strict
--!native
-- Tree placement. Trees whose canopy crosses a chunk border must look identical from both sides,
-- so each chunk's tree list is a pure function of (seed, chunk coords). When generating a chunk we
-- collect the trees of the 3x3 neighbourhood and write only the blocks that fall inside it.

local Shared = script.Parent.Parent.Parent
local Config = require(Shared.Config)
local Hash = require(Shared.Util.Hash)
local BlockRegistry = require(Shared.Blocks.BlockRegistry)
local Biomes = require(script.Parent.Parent.Biomes)

local CS = Config.CHUNK_SIZE
local H = Config.WORLD_HEIGHT
local SEA = Config.SEA_LEVEL
local LAYER = CS * CS

local TREE_ATTEMPTS = 12 -- per chunk; biome.treeChance decides how many succeed
local CACHE_LIMIT = 1024

local AIR = 0
local DIRT = BlockRegistry.id("dirt")
local GRASS = BlockRegistry.id("grass_block")
local SNOWY_GRASS = BlockRegistry.id("snowy_grass_block")

type Kind = { log: number, leaves: number, minHeight: number, heightRange: number, shape: string }
local KINDS: { [string]: Kind } = {
	oak = { log = BlockRegistry.id("oak_log"), leaves = BlockRegistry.id("oak_leaves"), minHeight = 4, heightRange = 3, shape = "round" },
	birch = { log = BlockRegistry.id("birch_log"), leaves = BlockRegistry.id("birch_leaves"), minHeight = 5, heightRange = 3, shape = "round" },
	spruce = { log = BlockRegistry.id("spruce_log"), leaves = BlockRegistry.id("spruce_leaves"), minHeight = 6, heightRange = 4, shape = "cone" },
}

local LEAVES = {} :: { [number]: boolean }
for _, k in KINDS do
	LEAVES[k.leaves] = true
end

export type Tree = { x: number, y: number, z: number, kind: Kind, height: number }

local Trees = {}

-- Pure: list of trees rooted in chunk (cx, cz). y is the surface block under the trunk.
function Trees.candidates(gen: any, cx: number, cz: number): { Tree }
	local key = (cx + 1048576) * 2097152 + (cz + 1048576)
	local cached = gen.treeCache[key]
	if cached then
		return cached
	end

	local list: { Tree } = {}
	local rng = Hash.newRng(Hash.hash3(gen.seed, cx, 0x7EE5, cz))
	for _ = 1, TREE_ATTEMPTS do
		-- Always draw the same number of values per attempt so results stay stable if rules change.
		local lx = rng:nextInt(0, CS - 1)
		local lz = rng:nextInt(0, CS - 1)
		local roll = rng:nextFloat()
		local kindRoll = rng:nextFloat()
		local heightRoll = rng:nextU32()

		local wx, wz = cx * CS + lx, cz * CS + lz
		local h, biomeId = gen.column(gen, wx, wz)
		local biome = Biomes.byId[biomeId]
		if roll < biome.treeChance and #biome.trees > 0 and h > SEA and h < SEA + 34 then
			-- pick kind by weight
			local total = 0
			for _, t in biome.trees do
				total += t.weight
			end
			local pick = kindRoll * total
			local kindName = biome.trees[#biome.trees].kind
			for _, t in biome.trees do
				pick -= t.weight
				if pick < 0 then
					kindName = t.kind
					break
				end
			end
			local kind = KINDS[kindName]
			local height = kind.minHeight + heightRoll % kind.heightRange
			if h + height + 3 < H and not gen.caveCarved(gen, wx, h, wz) and not gen.caveCarved(gen, wx, h - 1, wz) then
				table.insert(list, { x = wx, y = h, z = wz, kind = kind, height = height })
			end
		end
	end

	if gen.treeCacheSize >= CACHE_LIMIT then
		table.clear(gen.treeCache)
		gen.treeCacheSize = 0
	end
	gen.treeCache[key] = list
	gen.treeCacheSize += 1
	return list
end

-- Write one tree's blocks that fall inside `chunk`.
local function place(gen: any, chunk: any, tree: Tree)
	local blocks: buffer = chunk.blocks
	local ox, oz = chunk.cx * CS, chunk.cz * CS
	local seed = gen.seed
	local kind = tree.kind

	local function inChunk(wx: number, y: number, wz: number): number?
		local lx, lz = wx - ox, wz - oz
		if lx < 0 or lx >= CS or lz < 0 or lz >= CS or y < 0 or y >= H then
			return nil
		end
		return lx + lz * CS + y * LAYER
	end

	local function leaf(wx: number, y: number, wz: number)
		local idx = inChunk(wx, y, wz)
		if idx and buffer.readu16(blocks, idx * 2) == AIR then
			buffer.writeu16(blocks, idx * 2, kind.leaves)
		end
	end

	-- A ring of leaves. corners: "keep" | "drop" | "random"
	local function ring(y: number, r: number, corners: string)
		for dz = -r, r do
			for dx = -r, r do
				local corner = r > 0 and math.abs(dx) == r and math.abs(dz) == r
				local keep = true
				if corner then
					if corners == "drop" then
						keep = false
					elseif corners == "random" then
						keep = Hash.hash3(seed, tree.x + dx, y, tree.z + dz) % 2 == 0
					end
				end
				if keep then
					leaf(tree.x + dx, y, tree.z + dz)
				end
			end
		end
	end

	local top = tree.y + tree.height -- highest log block
	if kind.shape == "round" then
		ring(top - 2, 2, "random")
		ring(top - 1, 2, "random")
		ring(top, 1, "random")
		ring(top + 1, 1, "drop")
	else -- cone (spruce)
		leaf(tree.x, top + 1, tree.z)
		local r = 1
		for y = top, tree.y + 3, -1 do
			ring(y, r, "drop")
			r = if r == 1 then 2 else 1
		end
	end

	-- Trunk (after leaves so logs win), and turn the grass under it into dirt.
	for y = tree.y + 1, top do
		local idx = inChunk(tree.x, y, tree.z)
		if idx then
			local cur = buffer.readu16(blocks, idx * 2)
			if cur == AIR or LEAVES[cur] then
				buffer.writeu16(blocks, idx * 2, kind.log)
			end
		end
	end
	local base = inChunk(tree.x, tree.y, tree.z)
	if base then
		local cur = buffer.readu16(blocks, base * 2)
		if cur == GRASS or cur == SNOWY_GRASS then
			buffer.writeu16(blocks, base * 2, DIRT)
		end
	end
end

function Trees.generate(gen: any, chunk: any)
	for dz = -1, 1 do
		for dx = -1, 1 do
			for _, tree in Trees.candidates(gen, chunk.cx + dx, chunk.cz + dz) do
				place(gen, chunk, tree)
			end
		end
	end
end

return Trees
