--!strict
-- Fire, Java Edition rules (FireBlock):
--   * it survives on a sturdy block or next to something flammable; otherwise it goes out
--   * every 30-39 ticks it ages (+0..1) and may burn out; at age 15 over a non-flammable block it
--     has a 1-in-4 chance to go out
--   * neighbours burn by their flammability (chance 1-in-300 sideways, 1-in-250 up/down): they
--     turn into fire or vanish; TNT lights instead
--   * it spreads to air blocks up to 1 sideways, 1 below and 4 above that touch flammable blocks,
--     with Java's odds ((encouragement + 40 + difficulty x 7) / (age + 30))
-- Fire ages live in a table (they don't need saving: a reload just restarts fires at age 0).

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared.Config)
local BlockRegistry = require(Shared.Blocks.BlockRegistry)
local WorldService = require(script.Parent.Parent.World.WorldService)
local BlockUpdates = require(script.Parent.Parent.World.BlockUpdates)
local EntityService = require(script.Parent.EntityService)

local FIRE = BlockRegistry.id("fire")
local TNT = BlockRegistry.id("tnt")
local isSolid = BlockRegistry.isSolid
local isCube = BlockRegistry.isCube

local FireService = {}
local ages: { [string]: number } = {}

local function key(x: number, y: number, z: number): string
	return `{x},{y},{z}`
end

local function get(x: number, y: number, z: number): number?
	return WorldService.getBlockIfLoaded(x, y, z)
end

local function flammability(id: number?): number
	local def = id and BlockRegistry.byId[id]
	return if def and def.flammable then def.flammable[2] else 0
end

local function encouragement(id: number?): number
	local def = id and BlockRegistry.byId[id]
	return if def and def.flammable then def.flammable[1] else 0
end

local SIX = { { 1, 0, 0 }, { -1, 0, 0 }, { 0, 1, 0 }, { 0, -1, 0 }, { 0, 0, 1 }, { 0, 0, -1 } }

local function hasFlammableNeighbour(x: number, y: number, z: number): boolean
	for _, d in SIX do
		if flammability(get(x + d[1], y + d[2], z + d[3])) > 0 then
			return true
		end
	end
	return false
end

local function sturdyBelow(x: number, y: number, z: number): boolean
	local b = get(x, y - 1, z)
	return b ~= nil and isSolid[b + 1] and isCube[b + 1]
end

-- Can fire exist here (Java FireBlock.canSurvive)?
function FireService.canSurvive(x: number, y: number, z: number): boolean
	return sturdyBelow(x, y, z) or hasFlammableNeighbour(x, y, z)
end

local function schedule(x: number, y: number, z: number)
	BlockUpdates.schedule(x, y, z, 30 + math.random(0, 9), "fire")
end

-- Place fire (flint and steel, spreading).
function FireService.ignite(x: number, y: number, z: number, age: number?): boolean
	if get(x, y, z) ~= 0 or not FireService.canSurvive(x, y, z) then
		return false
	end
	ages[key(x, y, z)] = age or 0
	BlockUpdates.set(x, y, z, FIRE)
	schedule(x, y, z)
	return true
end

local function removeFire(x: number, y: number, z: number)
	ages[key(x, y, z)] = nil
	if get(x, y, z) == FIRE then
		BlockUpdates.set(x, y, z, 0)
	end
end

local function burnNeighbour(x: number, y: number, z: number, chance: number, age: number)
	local id = get(x, y, z)
	local flam = flammability(id)
	if flam > 0 and math.random(0, chance - 1) < flam then
		if id == TNT then
			EntityService.igniteBlock(x, y, z)
		elseif math.random(0, age + 9) < 5 then
			ages[key(x, y, z)] = math.min(15, age + math.random(0, 4) // 4)
			BlockUpdates.set(x, y, z, FIRE)
			schedule(x, y, z)
		else
			BlockUpdates.set(x, y, z, 0)
		end
	end
end

local function tick(x: number, y: number, z: number)
	if get(x, y, z) ~= FIRE then
		ages[key(x, y, z)] = nil
		return
	end
	if not FireService.canSurvive(x, y, z) then
		removeFire(x, y, z)
		return
	end
	local k = key(x, y, z)
	local age = ages[k] or 0
	age = math.min(15, age + math.random(0, 2) // 2)
	ages[k] = age
	if not hasFlammableNeighbour(x, y, z) then
		if not sturdyBelow(x, y, z) or age > 3 then
			removeFire(x, y, z)
		else
			schedule(x, y, z)
		end
		return
	end
	if age == 15 and math.random(0, 3) == 0 and flammability(get(x, y - 1, z)) == 0 then
		removeFire(x, y, z)
		return
	end
	burnNeighbour(x + 1, y, z, 300, age)
	burnNeighbour(x - 1, y, z, 300, age)
	burnNeighbour(x, y - 1, z, 250, age)
	burnNeighbour(x, y + 1, z, 250, age)
	burnNeighbour(x, y, z - 1, 300, age)
	burnNeighbour(x, y, z + 1, 300, age)
	-- spread into nearby air next to flammable blocks
	for dx = -1, 1 do
		for dz = -1, 1 do
			for dy = -1, 4 do
				if not (dx == 0 and dy == 0 and dz == 0) then
					local tx, ty, tz = x + dx, y + dy, z + dz
					local chanceBase = 100
					if dy > 1 then
						chanceBase += (dy - 1) * 100
					end
					if get(tx, ty, tz) == 0 then
						local enc = 0
						for _, d in SIX do
							enc = math.max(enc, encouragement(get(tx + d[1], ty + d[2], tz + d[3])))
						end
						if enc > 0 then
							local odds = (enc + 40 + Config.DIFFICULTY_FIRE * 7) // (age + 30)
							if odds > 0 and math.random(0, chanceBase - 1) <= odds then
								FireService.ignite(tx, ty, tz, math.min(15, age + math.random(0, 4) // 4))
							end
						end
					end
				end
			end
		end
	end
	if get(x, y, z) == FIRE then
		schedule(x, y, z)
	end
end

function FireService.init()
	BlockUpdates.register("fire", tick)
	BlockUpdates.onNeighbourChanged(function(x, y, z)
		if get(x, y, z) == FIRE and not FireService.canSurvive(x, y, z) then
			BlockUpdates.schedule(x, y, z, 1, "fire")
		end
	end)
	-- fires that exist in the world (e.g. after a reload) get ticked when touched; new ones
	-- from flint and steel / spreading are scheduled by ignite
	WorldService.onBlockChanged(function(x, y, z, _old, new)
		if new == FIRE and ages[key(x, y, z)] == nil then
			ages[key(x, y, z)] = 0
			BlockUpdates.schedule(x, y, z, 30 + math.random(0, 9), "fire")
		end
	end)
end

return FireService
