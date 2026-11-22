local Loader = require("./Loader")
return function(test, eq)
	local Brewing = Loader.require("src/shared/Items/Brewing")
	local Save = Loader.require("src/shared/Persistence/SaveFormat")
	local function stack(item, count)
		return { item = item, count = count or 1 }
	end
	test("brewing: three bottles, fuel accounting, save round trip and all recipes", function()
		local slots = {stack("water_bottle"), stack("water_bottle"), stack("water_bottle"), stack("wheat"), stack("charcoal", 2)}
		local state = {}
		Brewing.step(slots, state, 8)
		local record = Save.encodeRegion({ chunks = {}, entities = { {
			kind = "brewing_stand", x = 1, y = 100, z = 2, slots = slots, data = state,
			burn = 0, burnMax = 0, progress = 0,
		} } })
		local restored = Save.decodeRegion(record).entities[1]
		state, slots = restored.data, restored.slots
		eq(state.progress, 8)
		eq(state.ingredient, "wheat")
		eq(slots[5].count, 1)
		Brewing.step(slots, state, 12)
		eq(slots[4], nil)
		eq(state.charges, 19)
		for i = 1, 3 do eq(slots[i].item, "potion_base") end
		for ingredient, result in { sugar = "speed", iron_ingot = "strength", poppy = "regeneration" } do
			slots[4] = stack(ingredient)
			Brewing.step(slots, state, 20)
			for i = 1, 3 do
				eq(slots[i].item, "potion_" .. result)
				slots[i] = stack("potion_base")
			end
		end
		eq(state.charges, 16)
	end)
	test("brewing: invalid combinations idle and changing ingredient restarts the timer", function()
		local state = {}
		local slots = { stack("water_bottle"), [4] = stack("sugar"), [5] = stack("charcoal") }
		eq(Brewing.step(slots, state, 20), false)
		eq(slots[5].count, 1)
		slots[1] = stack("potion_base")
		Brewing.step(slots, state, 19)
		slots[4] = stack("poppy")
		Brewing.step(slots, state, 1)
		eq(slots[1].item, "potion_base")
		eq(state.progress, 1)
		slots[1] = nil
		Brewing.step(slots, state, 1)
		eq(state.ingredient, nil)
		eq(slots[4].count, 1)
		eq(Brewing.accepts(3, "potion_speed"), true)
		eq(Brewing.accepts(4, "charcoal"), false)
		eq(Brewing.accepts(5, "sugar"), false)
	end)
end
