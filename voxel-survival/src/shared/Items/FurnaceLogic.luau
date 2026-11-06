--!strict
-- Pure furnace simulation (classic rules):
--   * an item smelts in Recipes.SMELT_SECONDS while the furnace is burning
--   * when the fire is out and there is something smeltable with room in the output, one fuel
--     item is consumed and burns for Crafting.fuelSeconds(item)
--   * progress resets if the input is removed or can't be smelted; it pauses (decays) without fuel

local SlotLogic = require(script.Parent.SlotLogic)
local Crafting = require(script.Parent.Crafting)
local Recipes = require(script.Parent.Recipes)

export type Stack = SlotLogic.Stack
-- slots: [1] input, [2] fuel, [3] output
export type State = { slots: { [number]: Stack? }, burn: number, burnMax: number, progress: number }

local FurnaceLogic = {}
FurnaceLogic.INPUT, FurnaceLogic.FUEL, FurnaceLogic.OUTPUT = 1, 2, 3

function FurnaceLogic.new(): State
	return { slots = {}, burn = 0, burnMax = 0, progress = 0 }
end

local function canSmelt(st: State): (boolean, string?)
	local input = st.slots[1]
	local result = Crafting.smeltResult(input and input.item)
	if not result then
		return false, nil
	end
	local out = st.slots[3]
	if out and (out.item ~= result or out.count >= SlotLogic.maxStack(result)) then
		return false, nil
	end
	return true, result
end

-- Advance by dt seconds. Returns true if anything visible changed.
function FurnaceLogic.step(st: State, dt: number): boolean
	local changed = false
	local ok, result = canSmelt(st)
	local remaining = dt
	while remaining > 0 do
		if st.burn <= 0 then
			if not ok then
				break
			end
			local fuel = st.slots[2]
			local seconds = Crafting.fuelSeconds(fuel and fuel.item)
			if not fuel or seconds <= 0 then
				break
			end
			fuel.count -= 1
			if fuel.count <= 0 then
				st.slots[2] = nil
			end
			st.burn, st.burnMax = seconds, seconds
			changed = true
		end
		local slice = math.min(remaining, st.burn)
		st.burn -= slice
		remaining -= slice
		if ok then
			st.progress += slice
			if st.progress >= Recipes.SMELT_SECONDS then
				st.progress -= Recipes.SMELT_SECONDS
				local input = st.slots[1] :: Stack
				input.count -= 1
				if input.count <= 0 then
					st.slots[1] = nil
				end
				local out = st.slots[3]
				if out then
					out.count += 1
				else
					st.slots[3] = { item = result :: string, count = 1 }
				end
				changed = true
				ok, result = canSmelt(st)
				if not ok then
					st.progress = 0
				end
			end
		end
	end
	if not ok and st.progress > 0 then
		st.progress = 0
		changed = true
	end
	if st.burn <= 0 and st.progress > 0 then
		-- no fire: progress cools down (classic behaviour)
		st.progress = math.max(0, st.progress - dt * 2)
	end
	return changed
end

return FurnaceLogic
