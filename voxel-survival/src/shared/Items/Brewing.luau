--!strict
-- Slots 1..3 hold bottles, 4 holds the ingredient, 5 holds fuel.
-- TEMPORARY STAND-INS (no Nether yet), to be replaced by Java's items once it exists:
--   fuel charcoal = blaze powder; wheat -> potion base = nether wart -> awkward potion;
--   iron ingot -> strength = blaze powder; poppy -> regeneration = ghast tear.
--   (sugar -> speed is Java's own recipe.) See ROADMAP.md.
local Brewing = {}
Brewing.SECONDS = 20
Brewing.FUEL = "charcoal" -- TEMPORARY stand-in for blaze powder
Brewing.CHARGES = 20
local recipes: { [string]: { [string]: string } } = {
	water_bottle = { wheat = "potion_base" },
	potion_base = { sugar = "potion_speed", iron_ingot = "potion_strength", poppy = "potion_regeneration" },
}

type Stack = { item: string, count: number }
type Slots = { [number]: Stack? }
type State = { [string]: any }
function Brewing.range(item: string): (number?, number?)
	if recipes[item] or item == "potion_speed" or item == "potion_strength" or item == "potion_regeneration" then
		return 1, 3
	elseif item == Brewing.FUEL then
		return 5, 5
	end
	for _, options in recipes do
		if options[item] then
			return 4, 4
		end
	end
	return nil, nil
end

function Brewing.accepts(index: number, item: string): boolean
	local lo, hi = Brewing.range(item)
	return lo ~= nil and hi ~= nil and index >= lo and index <= hi
end

local function consume(slots: Slots, index: number)
	local stack = slots[index] :: Stack
	stack.count -= 1
	if stack.count == 0 then
		slots[index] = nil
	end
end

function Brewing.step(slots: Slots, state: State, dt: number): boolean
	local ingredient = slots[4]
	local key = ingredient and ingredient.item
	local outputs: { [number]: string } = {}
	if key then
		for i = 1, 3 do
			local bottle = slots[i]
			local options = bottle and recipes[bottle.item]
			if options and options[key] then
				outputs[i] = options[key]
			end
		end
	end
	local changed = false
	if state.ingredient and (state.ingredient ~= key or next(outputs) == nil) then
		state.progress, state.ingredient = 0, nil
		changed = true
	end
	if next(outputs) == nil then
		return changed
	end
	if not state.ingredient then
		if (state.charges or 0) == 0 then
			local fuel = slots[5]
			if not fuel or fuel.item ~= Brewing.FUEL then
				return changed
			end
			consume(slots, 5)
			state.charges = Brewing.CHARGES
		end
		state.charges -= 1
		state.ingredient, state.progress = key, 0
	end
	state.progress += dt
	if state.progress >= Brewing.SECONDS then
		for index, output in outputs do
			slots[index] = { item = output, count = 1 }
		end
		consume(slots, 4)
		state.progress, state.ingredient = 0, nil
	end
	return true
end
return Brewing
