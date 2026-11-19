--!strict
-- Farming on the server (Java rules: Shared/Gameplay/Farming):
--   random ticks   crops grow, farmland gets wet near water or dries and turns back into dirt,
--                  grass blocks spread onto dirt next to them and die under solid blocks
--   neighbours     plants and crops without their soil pop off (with their drops); farmland
--                  under a solid block becomes dirt
--   using items    a hoe tills grass / dirt into farmland; bone meal grows a crop or sprouts
--                  grass and flowers around a grass block
--   trampling      landing on farmland (the client reports the fall) may turn it into dirt
--
-- Light: the server has no light engine, so "light" is estimated: open sky (nothing solid in the
-- 24 blocks above; leaves dim it by 1 each) or a torch nearby (WorldService.blockLightAt).

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared.Config)
local Remotes = require(Shared.Net.Remotes)
local BlockRegistry = require(Shared.Blocks.BlockRegistry)
local ItemRegistry = require(Shared.Items.ItemRegistry)
local Farming = require(Shared.Gameplay.Farming)
local WorldService = require(script.Parent.Parent.World.WorldService)
local BlockUpdates = require(script.Parent.Parent.World.BlockUpdates)
local RandomTicks = require(script.Parent.Parent.World.RandomTicks)
local WeatherService = require(script.Parent.Parent.World.WeatherService)
local ItemEntityService = require(script.Parent.Parent.World.ItemEntityService)
local InventoryService = require(script.Parent.Parent.Player.InventoryService)
local Trees = require(Shared.World.Features.Trees)

local BS = Config.BLOCK_SIZE
local H = Config.WORLD_HEIGHT
local AIR = 0
local DIRT = Farming.DIRT
local GRASS = BlockRegistry.id("grass_block")
local SHORT_GRASS = Farming.SHORT_GRASS
local FLOWERS = { BlockRegistry.id("dandelion"), BlockRegistry.id("poppy") }
local isOpaque = BlockRegistry.isOpaque
local isSolid = BlockRegistry.isSolid
local isLiquid = BlockRegistry.isLiquid
local byId = BlockRegistry.byId

local FarmingService = {}
FarmingService.stats = { grown = 0, tilled = 0, trampled = 0, bonemeal = 0 }

local rng = Random.new()
local function rand(): number
	return rng:NextNumber()
end

local function get(x: number, y: number, z: number): number?
	return WorldService.getBlockIfLoaded(x, y, z)
end

local LEAVES: { [number]: boolean } = {}
for id, d in byId do
	if string.find(d.key, "leaves", 1, true) then
		LEAVES[id] = true
	end
end

-- Does this block shut out the light completely (grass dies under it)? Leaves don't.
local function blocksLight(id: number?): boolean
	return id ~= nil and isOpaque[id + 1] and not LEAVES[id]
end

-- Estimated light level at a cell (see the header).
function FarmingService.lightAt(x: number, y: number, z: number): number
	local sky = 15
	for yy = y, math.min(H - 1, y + 24) do
		local id = get(x, yy, z)
		if id == nil then
			break
		end
		if isOpaque[id + 1] then
			if LEAVES[id] then
				sky -= 1
			else
				sky = 0
				break
			end
		end
	end
	return math.max(sky, WorldService.blockLightAt(x, y, z))
end
local lightAt = FarmingService.lightAt

local function centre(x: number, y: number, z: number): Vector3
	return Vector3.new(x + 0.5, y + 0.5, z + 0.5) * BS
end

local function spawnDrops(stacks: { Farming.Stack }, x: number, y: number, z: number)
	for _, s in stacks do
		if s.count > 0 then
			ItemEntityService.spawn({ item = s.item, count = s.count }, centre(x, y, z))
		end
	end
end

-- Break a farming block (or any block) with its drops.
local function breakWithDrops(x: number, y: number, z: number, id: number)
	BlockUpdates.set(x, y, z, AIR)
	local stacks = Farming.drops(id, nil, rand)
	if stacks then
		spawnDrops(stacks, x, y, z)
	else
		local def = byId[id]
		if def and def.drop then
			spawnDrops({ { item = def.drop, count = 1 } }, x, y, z)
		end
	end
end

-- Random ticks ---------------------------------------------------------------------------------

local function farmlandTick(x: number, y: number, z: number, id: number)
	local m = Farming.moisture(id)
	-- Java FarmBlock.randomTick: water within 4 blocks, or rain falling on the block above
	if Farming.waterNear(x, y, z, get) or WeatherService.rainingAt(x, y + 1, z) then
		if m < 7 then
			BlockUpdates.set(x, y, z, Farming.farmland(7))
		end
	elseif m > 0 then
		BlockUpdates.set(x, y, z, Farming.farmland(m - 1))
	elseif not Farming.crop(get(x, y + 1, z)) then
		BlockUpdates.set(x, y, z, DIRT) -- dry and nothing planted: back to dirt
	end
end

local FACINGS = { north = { 0, -1 }, east = { 1, 0 }, south = { 0, 1 }, west = { -1, 0 } }
local FACING_ORDER = { "north", "east", "south", "west" }

-- A ripe stem grows its fruit on a free cell beside it (Java StemBlock), and bends toward it.
local function growFruit(x: number, y: number, z: number, fruitName: string)
	local facing = FACING_ORDER[rng:NextInteger(1, 4)]
	local d = FACINGS[facing]
	local fx, fz = x + d[1], z + d[2]
	if get(fx, y, fz) == AIR and Farming.fruitSoil(get(fx, y - 1, fz)) then
		BlockUpdates.set(fx, y, fz, BlockRegistry.id(fruitName))
		BlockUpdates.set(x, y, z, BlockRegistry.id(`attached_{fruitName}_stem_{facing}`))
		FarmingService.stats.grown += 1
	end
end

local function cropTick(x: number, y: number, z: number, id: number)
	local info = Farming.crop(id)
	if not info then
		return
	end
	local def = byId[id]
	local stem = def.state.stem == true
	if info.age >= info.maxAge and not stem then
		return
	end
	if lightAt(x, y, z) < 9 then
		return
	end
	if info.crop == "beetroots" and rng:NextInteger(0, 2) ~= 0 then
		return -- Java: beetroots skip 2 of 3 random ticks
	end
	local speed = Farming.growthSpeed(info.crop, x, y, z, get)
	if rng:NextInteger(0, math.floor(25.0 / speed)) == 0 then
		if info.age >= info.maxAge then
			growFruit(x, y, z, def.state.fruit)
			return
		end
		local nextId = Farming.cropId(info.crop, info.age + 1)
		if nextId then
			BlockUpdates.set(x, y, z, nextId)
			FarmingService.stats.grown += 1
		end
	end
end

-- Sugar cane and cactus (Java): with air above and fewer than 3 in the column, age +1 each
-- random tick; at 15 a new block grows on top and the age starts over.
local function columnTick(x: number, y: number, z: number, id: number)
	if get(x, y + 1, z) ~= AIR then
		return
	end
	local d = byId[id]
	local same = if d.shape == "cactus" then Farming.isCactus else Farming.isCane
	local height = 1
	while same(get(x, y - height, z)) do
		height += 1
	end
	if height >= 3 then
		return
	end
	local family = d.family
	local age = d.state.age
	if age >= 15 then
		BlockUpdates.set(x, y + 1, z, BlockRegistry.id(family))
		BlockUpdates.set(x, y, z, BlockRegistry.id(family))
		FarmingService.stats.grown += 1
	else
		BlockUpdates.set(x, y, z, BlockRegistry.id(`{family}_age_{age + 1}`))
	end
end

-- A sapling grows into its tree if there is room (Java: the tree feature fails when blocked).
function FarmingService.growTree(x: number, y: number, z: number, wood: string): boolean
	local tree = Trees.make(wood, x, y - 1, z, rng:NextInteger(0, 1000))
	if not tree then
		return false
	end
	local pieces = Trees.shape(rng:NextInteger(0, 2 ^ 30), tree)
	for _, p in pieces do
		if p.kind == "log" then
			local here = get(p.x, p.y, p.z)
			local hd = here and byId[here]
			if here == nil or not (here == AIR or Trees.LEAVES[here] or (p.y == y and p.x == x and p.z == z)
				or (hd and hd.replaceable)) then
				return false -- no room
			end
		end
	end
	for _, p in pieces do
		local here = get(p.x, p.y, p.z)
		local hd = here and byId[here]
		if p.kind == "leaf" then
			if here == AIR or (hd and hd.replaceable) then
				BlockUpdates.set(p.x, p.y, p.z, p.id)
			end
		elseif p.kind == "log" then
			BlockUpdates.set(p.x, p.y, p.z, p.id)
		elseif here == GRASS or here == BlockRegistry.id("snowy_grass_block") or Farming.isFarmland(here) then
			BlockUpdates.set(p.x, p.y, p.z, DIRT)
		end
	end
	FarmingService.stats.grown += 1
	return true
end

-- Java SaplingBlock.advanceTree: stage 0 -> 1, stage 1 -> a tree.
local function advanceSapling(x: number, y: number, z: number, id: number)
	local wood, stage = Farming.sapling(id)
	if not wood then
		return
	end
	if stage == 0 then
		BlockUpdates.set(x, y, z, Farming.saplingId(wood, 1) :: number)
	else
		FarmingService.growTree(x, y, z, wood)
	end
end

local function saplingTick(x: number, y: number, z: number, id: number)
	if lightAt(x, y + 1, z) >= 9 and rng:NextInteger(0, 6) == 0 then
		advanceSapling(x, y, z, id)
	end
end

local function grassTick(x: number, y: number, z: number, _id: number)
	local above = get(x, y + 1, z)
	if above == nil then
		return
	end
	if blocksLight(above) or isLiquid[above + 1] then
		BlockUpdates.set(x, y, z, DIRT) -- Java: grass dies under a block that shuts out the light
		return
	end
	if lightAt(x, y + 1, z) < 9 then
		return
	end
	for _ = 1, 4 do
		local tx, ty, tz = x + rng:NextInteger(-1, 1), y + rng:NextInteger(-3, 1), z + rng:NextInteger(-1, 1)
		if get(tx, ty, tz) == DIRT then
			local ta = get(tx, ty + 1, tz)
			if ta ~= nil and not blocksLight(ta) and not isLiquid[ta + 1] and lightAt(tx, ty + 1, tz) >= 4 then
				BlockUpdates.set(tx, ty, tz, GRASS)
			end
		end
	end
end

-- Neighbours ---------------------------------------------------------------------------------

local function supportCheck(x: number, y: number, z: number)
	local id = get(x, y, z)
	if not id then
		return
	end
	local d = byId[id]
	if not d then
		return
	end
	if d.shape == "plant" or d.shape == "crop" or d.shape == "cactus" then
		if not Farming.survivesAt(id, x, y, z, get) then
			breakWithDrops(x, y, z, id)
			return
		end
		-- an attached stem whose fruit was taken goes back to a ripe stem
		local fruit = d.state.attachedStem
		if fruit then
			local f = FACINGS[d.state.facing]
			local there = get(x + f[1], y, z + f[2])
			if there ~= nil and there ~= BlockRegistry.id(fruit) then
				BlockUpdates.set(x, y, z, Farming.cropId(`{fruit}_stem`, 7) :: number)
			end
		end
	elseif d.shape == "farmland" then
		local above = get(x, y + 1, z)
		if above ~= nil and isSolid[above + 1] then
			BlockUpdates.set(x, y, z, DIRT) -- Java: a solid block on farmland squashes it
		end
	end
end

-- Using items ----------------------------------------------------------------------------------

-- Bone meal on a grass block (Java GrassBlock.performBonemeal): 128 tries along short random
-- walks from the block above; each lands short grass (or 1 in 8 a flower) on bare grass.
local function bonemealGrass(x: number, y: number, z: number)
	for i = 0, 127 do
		local px, py, pz = x, y + 1, z
		local ok = true
		for _ = 1, i // 16 do
			px += rng:NextInteger(-1, 1)
			py += (rng:NextInteger(-1, 1) * rng:NextInteger(0, 2)) // 2
			pz += rng:NextInteger(-1, 1)
			local below = get(px, py - 1, pz)
			local here = get(px, py, pz)
			if below ~= GRASS or here == nil or isSolid[here + 1] then
				ok = false
				break
			end
		end
		if ok and get(px, py, pz) == AIR and get(px, py - 1, pz) == GRASS then
			local plant = if rng:NextInteger(0, 7) == 0 then FLOWERS[rng:NextInteger(1, #FLOWERS)] else SHORT_GRASS
			BlockUpdates.set(px, py, pz, plant)
		end
	end
end

-- A right-click use of the held item on block (x, y, z) (ItemUseService). Returns true if it
-- was a farming use (handled here).
function FarmingService.use(p: Player, item: string?, x: number, y: number, z: number, ny: number): boolean
	local def = ItemRegistry.get(item)
	local clicked = get(x, y, z)
	if not def or clicked == nil then
		return false
	end
	local tool = def.tool
	if tool and tool.kind == "hoe" then
		if ny ~= -1 and Farming.tillable(clicked) and get(x, y + 1, z) == AIR then
			BlockUpdates.set(x, y, z, Farming.FARMLAND)
			InventoryService.damageSelectedTool(p, 1)
			FarmingService.stats.tilled += 1
		end
		return true
	end
	if item == "bone_meal" then
		local info = Farming.crop(clicked)
		local used = false
		if info and info.age < info.maxAge then
			local age = Farming.bonemealAge(info, function(a, b)
				return rng:NextInteger(a, b)
			end)
			BlockUpdates.set(x, y, z, Farming.cropId(info.crop, age) :: number)
			used = true
		elseif clicked == GRASS and get(x, y + 1, z) == AIR then
			bonemealGrass(x, y, z)
			used = true
		elseif (Farming.sapling(clicked)) then
			-- Java: 45 % chance to advance the sapling (the bone meal is used either way)
			if rng:NextNumber() < 0.45 then
				advanceSapling(x, y, z, clicked)
			end
			used = true
		end
		if used then
			InventoryService.consumeSelected(p, 1)
			FarmingService.stats.bonemeal += 1
		end
		return true
	end
	return false
end

-- Trampling: the client says it landed on farmland at (x, y, z) after falling `fall` blocks.
local function onTrample(p: Player, x: number, y: number, z: number, fall: number)
	if p:GetAttribute("Spectator") == true then
		return
	end
	local id = get(x, y, z)
	if not Farming.isFarmland(id) then
		return
	end
	local c = p.Character
	local root = c and c:FindFirstChild("HumanoidRootPart") :: BasePart?
	if not root then
		return
	end
	local feet = (root.Position - Vector3.new(0, 3, 0)) / BS
	if math.abs(feet.X - (x + 0.5)) > 1.5 or math.abs(feet.Z - (z + 0.5)) > 1.5 or math.abs(feet.Y - (y + 1)) > 1.5 then
		return -- not standing there
	end
	if rand() < Farming.trampleChance(math.min(fall, 64)) then
		BlockUpdates.set(x, y, z, DIRT)
		FarmingService.stats.trampled += 1
	end
end

-- For tests: run one random tick / support check on a block.
function FarmingService.randomTick(x: number, y: number, z: number)
	local id = get(x, y, z)
	if not id then
		return
	end
	if Farming.isFarmland(id) then
		farmlandTick(x, y, z, id)
	elseif Farming.crop(id) then
		cropTick(x, y, z, id)
	elseif id == GRASS then
		grassTick(x, y, z, id)
	elseif Farming.isCane(id) or Farming.isCactus(id) then
		columnTick(x, y, z, id)
	elseif (Farming.sapling(id)) then
		saplingTick(x, y, z, id)
	end
end
FarmingService.supportCheck = supportCheck
FarmingService.trample = onTrample

function FarmingService.init()
	local farmland, crops = {}, {}
	for id, d in byId do
		if d.shape == "farmland" then
			table.insert(farmland, id)
		elseif d.shape == "crop" then
			table.insert(crops, id)
		end
	end
	RandomTicks.register(farmland, farmlandTick)
	RandomTicks.register(crops, cropTick)
	RandomTicks.register({ GRASS }, grassTick)
	local columns, saplings, attached = {}, {}, {}
	for id, d in byId do
		if d.shape == "cactus" or (d.shape == "plant" and d.state.cane) then
			table.insert(columns, id)
		elseif d.shape == "plant" and d.state.sapling then
			table.insert(saplings, id)
		elseif d.shape == "plant" and d.state.attachedStem then
			table.insert(attached, id)
		end
	end
	RandomTicks.register(columns, columnTick)
	RandomTicks.register(saplings, saplingTick)
	-- safety net: a bent stem whose fruit is gone also straightens on a random tick
	RandomTicks.register(attached, function(x: number, y: number, z: number, _id: number)
		supportCheck(x, y, z)
	end)

	local NEEDS_CHECK: { [number]: boolean } = {}
	for id, d in byId do
		if d.shape == "plant" or d.shape == "crop" or d.shape == "farmland" or d.shape == "cactus" then
			NEEDS_CHECK[id] = true
		end
	end
	BlockUpdates.onNeighbourChanged(function(x, y, z)
		local id = get(x, y, z)
		if id and NEEDS_CHECK[id] then
			BlockUpdates.schedule(x, y, z, 1, "farming_support")
		end
	end)
	BlockUpdates.register("farming_support", supportCheck)

	Remotes.get("SurvivalAction").OnServerEvent:Connect(function(p: Player, a: any)
		if typeof(a) == "table" and a.type == "trample" and typeof(a.x) == "number" and typeof(a.y) == "number"
			and typeof(a.z) == "number" and typeof(a.fall) == "number" and a.fall == a.fall
		then
			onTrample(p, math.floor(a.x), math.floor(a.y), math.floor(a.z), a.fall)
		end
	end)
end

return FarmingService
