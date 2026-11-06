--!strict
-- Pure crafting / smelting logic (shared: the server is authoritative, tests run headless).

local Recipes = require(script.Parent.Recipes)
local ItemRegistry = require(script.Parent.ItemRegistry)

export type Stack = { item: string, count: number, durability: number? }

local Crafting = {}

-- Validate data at load time: every item named in recipes must exist.
local function checkItem(key: string, where: string)
	if string.sub(key, 1, 1) == "#" then
		assert(Recipes.TAGS[key], `Recipes: unknown tag {key} in {where}`)
		for _, k in Recipes.TAGS[key] do
			assert(ItemRegistry.get(k), `Recipes: tag {key} lists unknown item {k}`)
		end
	else
		assert(ItemRegistry.get(key), `Recipes: unknown item '{key}' in {where}`)
	end
end
for _, r in Recipes.shaped do
	for _, v in r.key do
		checkItem(v, r.result.item)
	end
	checkItem(r.result.item, "result")
end
for _, r in Recipes.shapeless do
	for _, v in r.ingredients do
		checkItem(v, r.result.item)
	end
	checkItem(r.result.item, "result")
end
for input, output in Recipes.smelting do
	checkItem(input, "smelting")
	checkItem(output, "smelting")
end
for item in Recipes.fuel do
	checkItem(item, "fuel")
end

local function matches(ingredient: string, item: string): boolean
	if string.sub(ingredient, 1, 1) == "#" then
		return table.find(Recipes.TAGS[ingredient], item) ~= nil
	end
	return ingredient == item
end

-- `grid`: w*w slots (row-major, 1-based), each a stack or nil. Returns the result or nil.
function Crafting.match(grid: { [number]: Stack? }, w: number): Recipes.Result?
	-- bounding box of filled cells
	local minR, maxR, minC, maxC = math.huge, -1, math.huge, -1
	local filled: { string } = {}
	for r = 0, w - 1 do
		for c = 0, w - 1 do
			local s = grid[r * w + c + 1]
			if s then
				minR, maxR = math.min(minR, r), math.max(maxR, r)
				minC, maxC = math.min(minC, c), math.max(maxC, c)
				table.insert(filled, s.item)
			end
		end
	end
	if maxR < 0 then
		return nil
	end
	local h, wd = maxR - minR + 1, maxC - minC + 1
	local function cell(r: number, c: number): string?
		local s = grid[(minR + r) * w + (minC + c) + 1]
		return s and s.item
	end

	for _, recipe in Recipes.shaped do
		local pattern = recipe.pattern
		local ph, pw = #pattern, #pattern[1]
		if ph == h and pw == wd then
			for _, mirror in { false, true } do
				local ok = true
				for r = 0, h - 1 do
					local row = pattern[r + 1]
					for c = 0, wd - 1 do
						local pc = if mirror then wd - 1 - c else c
						local ch = string.sub(row, pc + 1, pc + 1)
						local item = cell(r, c)
						if ch == " " then
							if item ~= nil then
								ok = false
							end
						elseif item == nil or not matches(recipe.key[ch], item) then
							ok = false
						end
						if not ok then
							break
						end
					end
					if not ok then
						break
					end
				end
				if ok then
					return recipe.result
				end
			end
		end
	end

	for _, recipe in Recipes.shapeless do
		if #recipe.ingredients == #filled then
			local used: { boolean } = {}
			local ok = true
			for _, ing in recipe.ingredients do
				local found = false
				for i, item in filled do
					if not used[i] and matches(ing, item) then
						used[i] = true
						found = true
						break
					end
				end
				if not found then
					ok = false
					break
				end
			end
			if ok then
				return recipe.result
			end
		end
	end
	return nil
end

function Crafting.smeltResult(item: string?): string?
	return item and Recipes.smelting[item]
end

function Crafting.fuelSeconds(item: string?): number
	return if item then Recipes.fuel[item] or 0 else 0
end

return Crafting
