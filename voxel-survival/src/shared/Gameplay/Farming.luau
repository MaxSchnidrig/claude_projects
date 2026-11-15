--!strict
-- Farming rules (Java Edition; pure, tested headless). The server's Simulation/FarmingService
-- applies them; clients use them to predict planting.
--
--   soil        short grass and flowers grow on grass blocks, dirt and farmland; crops only on
--               farmland
--   tilling     a hoe turns grass blocks and dirt into farmland when the block above is air
--   farmland    random tick: water within 4 blocks across (same level or one up) -> moisture 7;
--               else it dries by 1; dry farmland without a crop turns back into dirt. A
--               solid block on top, or something landing on it (chance fall distance - 0.5),
--               turns it into dirt
--   crops       random tick with light >= 9: grow one age with chance 1 / (floor(25 / speed)
--               + 1); speed from the farmland under and around (CropBlock.getGrowthSpeed).
--               Beetroots skip 2 of 3 ticks. Bone meal: +2..5 ages (beetroots +1)
--   drops       ripe wheat: 1 wheat + 1..4 seeds; ripe carrots / potatoes: 1..4 (potatoes +2 %
--               poisonous potato); ripe beetroots: 1 beetroot + 1..4 seeds; unripe: 1 seed /
--               carrot / potato. Short grass: 1 in 8 wheat seeds (shears: the grass itself)
--               ("1..4" = 1 + three tries at 4 / 7, Java's binomial bonus)

local BlockRegistry = require(script.Parent.Parent.Blocks.BlockRegistry)

local byId, byKey = BlockRegistry.byId, BlockRegistry.byKey

local Farming = {}

local GRASS = byKey.grass_block.id
local SNOWY_GRASS = byKey.snowy_grass_block.id
local DIRT = byKey.dirt.id
Farming.DIRT = DIRT
Farming.SHORT_GRASS = byKey.short_grass.id

local FARMLAND: { [number]: number } = {} -- moisture -> id
local MOISTURE: { [number]: number } = {} -- id -> moisture
for id, d in byId do
	if d.shape == "farmland" then
		FARMLAND[d.state.moisture] = id
		MOISTURE[id] = d.state.moisture
	end
end
Farming.FARMLAND = FARMLAND[0]

export type CropInfo = { crop: string, age: number, maxAge: number }
local CROP: { [number]: CropInfo } = {}
local CROP_ID: { [string]: { [number]: number } } = {}
for id, d in byId do
	if d.shape == "crop" then
		local st = d.state
		CROP[id] = { crop = st.crop, age = st.age, maxAge = st.maxAge }
		CROP_ID[st.crop] = CROP_ID[st.crop] or {}
		CROP_ID[st.crop][st.age] = id
	end
end

function Farming.isFarmland(id: number?): boolean
	return id ~= nil and MOISTURE[id] ~= nil
end

function Farming.moisture(id: number?): number
	return if id then MOISTURE[id] or 0 else 0
end

function Farming.farmland(moisture: number): number
	return FARMLAND[math.clamp(moisture, 0, 7)]
end

function Farming.crop(id: number?): CropInfo?
	return if id then CROP[id] else nil
end

function Farming.cropId(crop: string, age: number): number?
	local list = CROP_ID[crop]
	return list and list[age]
end

-- Can a short grass / flower stand on this block?
function Farming.plantSoil(below: number?): boolean
	return below ~= nil and (below == GRASS or below == SNOWY_GRASS or below == DIRT or MOISTURE[below] ~= nil)
end

-- Does the block with this id survive on the block below it? (Plants and crops only; others: true.)
function Farming.survives(id: number, below: number?): boolean
	local d = byId[id]
	if not d then
		return true
	end
	if d.shape == "crop" then
		return Farming.isFarmland(below)
	elseif d.shape == "plant" then
		return Farming.plantSoil(below)
	end
	return true
end

-- A hoe turns this block into farmland (when the block above is air).
function Farming.tillable(id: number?): boolean
	return id == GRASS or id == SNOWY_GRASS or id == DIRT
end

-- Water within 4 blocks across, at the farmland's level or one above (Java FarmBlock.isNearWater).
function Farming.waterNear(x: number, y: number, z: number, get: (number, number, number) -> number?): boolean
	for dy = 0, 1 do
		for dz = -4, 4 do
			for dx = -4, 4 do
				local id = get(x + dx, y + dy, z + dz)
				local d = id and byId[id]
				if d and d.fluid == "water" then
					return true
				end
			end
		end
	end
	return false
end

-- Java CropBlock.getGrowthSpeed for the crop at (x, y, z).
function Farming.growthSpeed(crop: string, x: number, y: number, z: number, get: (number, number, number) -> number?): number
	local f = 1.0
	for dx = -1, 1 do
		for dz = -1, 1 do
			local g = 0.0
			local below = get(x + dx, y - 1, z + dz)
			if Farming.isFarmland(below) then
				g = 1.0
				if Farming.moisture(below) > 0 then
					g = 3.0
				end
			end
			if dx ~= 0 or dz ~= 0 then
				g /= 4.0
			end
			f += g
		end
	end
	local function same(dx: number, dz: number): boolean
		local c = Farming.crop(get(x + dx, y, z + dz))
		return c ~= nil and c.crop == crop
	end
	local westEast = same(-1, 0) or same(1, 0)
	local northSouth = same(0, -1) or same(0, 1)
	if westEast and northSouth then
		f /= 2.0
	elseif same(-1, -1) or same(1, -1) or same(1, 1) or same(-1, 1) then
		f /= 2.0
	end
	return f
end

-- Chance per random tick that a crop with this growth speed grows one age.
function Farming.growChance(speed: number): number
	return 1 / (math.floor(25.0 / speed) + 1)
end

-- Bone meal on a crop: its new age. `rng(a, b)` returns an integer in [a, b].
function Farming.bonemealAge(info: CropInfo, rng: (number, number) -> number): number
	local add = if info.crop == "beetroots" then 1 else rng(2, 5)
	return math.min(info.maxAge, info.age + add)
end

export type Stack = { item: string, count: number }

-- Items a farming block drops when broken (or washed away), or nil if it isn't one (use its
-- normal drop). `toolKind`: the tool's kind ("shears" ...) or nil. `rand()` returns [0, 1).
function Farming.drops(id: number, toolKind: string?, rand: () -> number): { Stack }?
	local d = byId[id]
	if not d then
		return nil
	end
	local function bonus(): number
		local n = 1
		for _ = 1, 3 do
			if rand() < 0.5714286 then
				n += 1
			end
		end
		return n
	end
	if d.key == "short_grass" then
		if toolKind == "shears" then
			return { { item = "short_grass", count = 1 } }
		end
		return if rand() < 0.125 then { { item = "wheat_seeds", count = 1 } } else {}
	end
	local c = CROP[id]
	if not c then
		return nil
	end
	local ripe = c.age >= c.maxAge
	if c.crop == "wheat" then
		return if ripe then { { item = "wheat", count = 1 }, { item = "wheat_seeds", count = bonus() } }
			else { { item = "wheat_seeds", count = 1 } }
	elseif c.crop == "beetroots" then
		return if ripe then { { item = "beetroot", count = 1 }, { item = "beetroot_seeds", count = bonus() } }
			else { { item = "beetroot_seeds", count = 1 } }
	elseif c.crop == "carrots" then
		return { { item = "carrot", count = if ripe then bonus() else 1 } }
	elseif c.crop == "potatoes" then
		local out = { { item = "potato", count = if ripe then bonus() else 1 } }
		if ripe and rand() < 0.02 then
			table.insert(out, { item = "poisonous_potato", count = 1 })
		end
		return out
	end
	return nil
end

-- Farmland trampling: chance that landing after falling `fall` blocks turns it into dirt.
function Farming.trampleChance(fall: number): number
	return math.clamp(fall - 0.5, 0, 1)
end

return Farming
