--!strict
-- Flowing water and lava, Java Edition rules (pure; tested headless; run by the server).
--
-- Levels (one block id each): 0 = source, 1..7 = flowing (higher = farther from the source),
-- 8 = falling. "Amount" = 8 for sources and falling, 8 - level for flowing.
--
--   tick (scheduled: water every 5 game ticks, lava every 30 in the overworld)
--     lava touching water (not below it): source -> obsidian, flowing -> cobblestone
--     a non-source recomputes its level from its neighbours:
--       water with 2+ horizontal source neighbours over a solid block or a water source -> source
--       same fluid above -> falling
--       else max(neighbour amounts) - drop (water 1, lava 2); nothing left -> it disappears
--     then it spreads:
--       down first if it can (lava falling onto water makes stone); a falling or flowing column
--       doesn't spread sideways while it can fall, a source spreads sideways anyway
--       sideways: amount - drop, only towards the nearest way down within 4 (water) or 2 (lava)
--       blocks, or in every open direction if there is none
--   fluids wash away torches (they drop) and put out fire; water douses campfires
--
-- `world` gives access to blocks: get(x, y, z) -> id? (nil = unloaded: treated as a wall),
-- set(x, y, z, id), drop(x, y, z, itemKey) for washed-away items, fizz(x, y, z) for effects.

local BlockRegistry = require(script.Parent.Parent.Blocks.BlockRegistry)

local Fluids = {}

export type World = {
	get: (x: number, y: number, z: number) -> number?,
	set: (x: number, y: number, z: number, id: number) -> (),
	drop: (x: number, y: number, z: number, item: string) -> (),
	fizz: (x: number, y: number, z: number) -> (),
}

local AIR = 0
local STONE = BlockRegistry.id("stone")
local COBBLE = BlockRegistry.id("cobblestone")
local OBSIDIAN = BlockRegistry.id("obsidian")
local FIRE = BlockRegistry.id("fire")
local CAMPFIRE = BlockRegistry.id("campfire")
local CAMPFIRE_UNLIT = BlockRegistry.id("campfire_unlit")
local isSolid = BlockRegistry.isSolid

-- id -> fluid name / level, and (fluid, level) -> id
local fluidOf: { [number]: string } = {}
local levelOf: { [number]: number } = {}
local idFor: { [string]: { [number]: number } } = { water = {}, lava = {} }
for id, def in BlockRegistry.byId do
	if def.fluid then
		fluidOf[id] = def.fluid
		levelOf[id] = def.fluidLevel or 0
		idFor[def.fluid][def.fluidLevel or 0] = id
	end
end

Fluids.DROP = { water = 1, lava = 2 }
Fluids.SLOPE = { water = 4, lava = 2 }
Fluids.DELAY = { water = 5, lava = 30 }

function Fluids.info(id: number?): (string?, number)
	if id == nil then
		return nil, 0
	end
	return fluidOf[id], levelOf[id] or 0
end

function Fluids.id(fluid: string, level: number): number
	return idFor[fluid][level]
end

function Fluids.isSource(id: number?): boolean
	return id ~= nil and fluidOf[id] ~= nil and levelOf[id] == 0
end

function Fluids.amount(level: number): number
	if level == 0 or level == 8 then
		return 8
	end
	return 8 - level
end

-- Surface height (0..1 of a block) for rendering: sources 8/9, flowing (8 - level) / 9.
function Fluids.height(level: number): number
	if level == 8 then
		return 1
	end
	return Fluids.amount(level) / 9
end

-- Blocks a fluid flows into, replacing them (torches drop, fire goes out).
local function washable(id: number): boolean
	if id == AIR or id == FIRE then
		return true
	end
	local def = BlockRegistry.byId[id]
	return def ~= nil and not isSolid[id + 1] and not def.fluid and (def.shape == "torch" or def.shape == "wall_torch")
end

-- Can `fluid` flow into (x, y, z)? Same fluid: only into lower amounts (never sources).
local function canFlowInto(world: World, x: number, y: number, z: number, fluid: string): boolean
	local id = world.get(x, y, z)
	if id == nil then
		return false
	end
	local f, level = Fluids.info(id)
	if f == fluid then
		return level ~= 0
	elseif f ~= nil then
		return false
	end
	return washable(id)
end

local function place(world: World, x: number, y: number, z: number, fluid: string, level: number)
	local id = world.get(x, y, z)
	if id == nil then
		return
	end
	if id ~= AIR and id ~= FIRE and not fluidOf[id] then
		local def = BlockRegistry.byId[id]
		if def and def.drop then
			world.drop(x, y, z, def.drop) -- washed away
		end
	end
	world.set(x, y, z, idFor[fluid][level])
end

local H4 = { { 1, 0 }, { -1, 0 }, { 0, 1 }, { 0, -1 } }

-- Java getNewLiquid: the level this non-source block should have, or nil (empty).
local function newLevel(world: World, x: number, y: number, z: number, fluid: string): number?
	local maxAmount, sources = 0, 0
	for _, d in H4 do
		local f, level = Fluids.info(world.get(x + d[1], y, z + d[2]))
		if f == fluid then
			if level == 0 then
				sources += 1
			end
			maxAmount = math.max(maxAmount, Fluids.amount(level))
		end
	end
	if fluid == "water" and sources >= 2 then
		local below = world.get(x, y - 1, z)
		if below ~= nil and (isSolid[below + 1] or (fluidOf[below] == "water" and levelOf[below] == 0)) then
			return 0 -- infinite water source
		end
	end
	local above = world.get(x, y + 1, z)
	if above ~= nil and fluidOf[above] == fluid then
		return 8
	end
	local amount = maxAmount - Fluids.DROP[fluid]
	if amount <= 0 then
		return nil
	end
	return 8 - amount
end

-- Can the fluid fall at (x, y, z) (an open or same-fluid cell below)?
local function hole(world: World, x: number, y: number, z: number, fluid: string): boolean
	if canFlowInto(world, x, y - 1, z, fluid) then
		return true
	end
	local f = Fluids.info(world.get(x, y - 1, z))
	return f == fluid
end

-- Java getSlopeDistance: steps to the nearest hole, searching up to SLOPE[fluid] blocks.
local function slope(world: World, x: number, y: number, z: number, fluid: string, depth: number, fromDx: number, fromDz: number): number
	local best = 1000
	for _, d in H4 do
		if not (d[1] == fromDx and d[2] == fromDz) then
			local nx, nz = x + d[1], z + d[2]
			if canFlowInto(world, nx, y, nz, fluid) and not Fluids.isSource(world.get(nx, y, nz)) then
				if hole(world, nx, y, nz, fluid) then
					return depth
				end
				if depth < Fluids.SLOPE[fluid] then
					best = math.min(best, slope(world, nx, y, nz, fluid, depth + 1, -d[1], -d[2]))
				end
			end
		end
	end
	return best
end

local function spreadSides(world: World, x: number, y: number, z: number, fluid: string, level: number)
	local amount = Fluids.amount(level) - Fluids.DROP[fluid]
	if level == 8 then
		amount = 8 - Fluids.DROP[fluid]
	end
	if amount <= 0 then
		return
	end
	-- Java getSpread: prefer the direction(s) with the shortest way down
	local best = 1000
	local dist: { [number]: number } = {}
	for i, d in H4 do
		local nx, nz = x + d[1], z + d[2]
		if canFlowInto(world, nx, y, nz, fluid) and not Fluids.isSource(world.get(nx, y, nz)) then
			local s = if hole(world, nx, y, nz, fluid) then 0 else slope(world, nx, y, nz, fluid, 1, -d[1], -d[2])
			dist[i] = s
			best = math.min(best, s)
		end
	end
	for i, d in H4 do
		local s = dist[i]
		if s ~= nil and s <= best then
			local nx, nz = x + d[1], z + d[2]
			local f, l = Fluids.info(world.get(nx, y, nz))
			if f ~= fluid or Fluids.amount(l) < amount then
				place(world, nx, y, nz, fluid, 8 - amount)
			end
		end
	end
end

-- Lava touching water (above or beside): Java LiquidBlock.shouldSpreadLiquid. Returns true if
-- the lava block turned solid.
function Fluids.reactLava(world: World, x: number, y: number, z: number): boolean
	local id = world.get(x, y, z)
	if id == nil or fluidOf[id] ~= "lava" then
		return false
	end
	for _, d in { { 1, 0, 0 }, { -1, 0, 0 }, { 0, 1, 0 }, { 0, 0, 1 }, { 0, 0, -1 } } do
		local n = world.get(x + d[1], y + d[2], z + d[3])
		if n ~= nil and fluidOf[n] == "water" then
			world.set(x, y, z, if levelOf[id] == 0 then OBSIDIAN else COBBLE)
			world.fizz(x, y, z)
			return true
		end
	end
	return false
end

-- One scheduled fluid tick at (x, y, z).
function Fluids.tick(world: World, x: number, y: number, z: number)
	local id = world.get(x, y, z)
	if id == nil then
		return
	end
	local fluid, level = Fluids.info(id)
	if not fluid then
		return
	end
	if fluid == "lava" and Fluids.reactLava(world, x, y, z) then
		return
	end
	if level ~= 0 then
		local nl = newLevel(world, x, y, z, fluid)
		if nl == nil then
			world.set(x, y, z, AIR)
			return
		end
		if nl ~= level then
			world.set(x, y, z, idFor[fluid][nl])
			level = nl
		end
	end
	-- spread
	local below = world.get(x, y - 1, z)
	if below ~= nil and fluid == "lava" and fluidOf[below] == "water" then
		world.set(x, y - 1, z, STONE) -- lava falling onto water
		world.fizz(x, y - 1, z)
		return
	end
	if below ~= nil and (below == CAMPFIRE) and fluid == "water" then
		world.set(x, y - 1, z, CAMPFIRE_UNLIT)
	end
	if canFlowInto(world, x, y - 1, z, fluid) then
		local bf, bl = Fluids.info(below)
		if bf ~= fluid or bl ~= 8 then
			place(world, x, y - 1, z, fluid, 8)
		end
		-- Java: a source with 3+ source neighbours also spreads sideways while falling
		if level == 0 then
			local n = 0
			for _, d in H4 do
				if Fluids.isSource(world.get(x + d[1], y, z + d[2])) then
					n += 1
				end
			end
			if n >= 3 then
				spreadSides(world, x, y, z, fluid, level)
			end
		end
	elseif level == 0 or Fluids.info(below) ~= fluid then
		spreadSides(world, x, y, z, fluid, level)
	end
	-- water next to a lit campfire puts it out
	if fluid == "water" then
		for _, d in H4 do
			if world.get(x + d[1], y, z + d[2]) == CAMPFIRE then
				world.set(x + d[1], y, z + d[2], CAMPFIRE_UNLIT)
			end
		end
	end
end

-- Horizontal flow direction at a fluid block (for pushing entities), unit vector or zero.
function Fluids.flow(get: (number, number, number) -> number?, x: number, y: number, z: number): (number, number)
	local id = get(x, y, z)
	local fluid, level = Fluids.info(id)
	if not fluid then
		return 0, 0
	end
	local mine = Fluids.amount(level)
	local fx, fz = 0, 0
	for _, d in H4 do
		local n = get(x + d[1], y, z + d[2])
		local f, l = Fluids.info(n)
		local other: number? = nil
		if f == fluid then
			other = Fluids.amount(l)
		elseif n == AIR then
			local bf, bl = Fluids.info(get(x + d[1], y - 1, z + d[2]))
			if bf == fluid then
				other = Fluids.amount(bl) - 8
			end
		end
		if other ~= nil then
			local diff = mine - other
			fx += d[1] * diff
			fz += d[2] * diff
		end
	end
	local len = math.sqrt(fx * fx + fz * fz)
	if len < 1e-6 then
		return 0, 0
	end
	return fx / len, fz / len
end

return Fluids
