--!strict
-- Enchantments (Phase 10b): every Java Edition enchantment's data and the enchanting table's
-- exact algorithm (EnchantmentMenu / EnchantmentHelper, checked against the Minecraft Wiki
-- "Enchanting table mechanics" and "Enchantment/Levels" pages), run on java.util.Random
-- (Util/JavaRandom) so the same seed gives the same offers as Java.
--
-- Excluded: Swift Sneak (ancient cities); Density, Breach, Wind Burst (the mace, trial chambers).
-- Trident enchantments are here but do nothing until the trident exists (Phase 20).
-- Effects come in 10c (tools, weapons, bows, crossbows, Mending) and 10d (armour, fishing).
--
-- Stacks keep enchantments as `ench = { [id] = level }` (Items/SlotLogic).

local JavaRandom = require(script.Parent.Parent.Util.JavaRandom)

local Enchantments = {}

export type Def = {
	id: string,
	name: string,
	max: number,
	weight: number,
	minBase: number, minPer: number, -- min cost = minBase + minPer * (level - 1)
	maxBase: number, maxPer: number, -- max cost = maxBase + maxPer * (level - 1)
	supported: string, -- item category it can be on (anvil, commands)
	primary: string, -- item category the enchanting table offers it for
	exclusive: string?, -- enchantments in the same group don't go together
	treasure: boolean?, -- never from the table (loot, trading)
	curse: boolean?,
}

local function D(id: string, name: string, max: number, weight: number, minBase: number, minPer: number,
	maxBase: number, maxPer: number, supported: string, primary: string?, extra: { [string]: any }?): Def
	local d: Def = {
		id = id, name = name, max = max, weight = weight,
		minBase = minBase, minPer = minPer, maxBase = maxBase, maxPer = maxPer,
		supported = supported, primary = primary or supported,
	}
	if extra then
		d.exclusive = extra.exclusive
		d.treasure = extra.treasure
		d.curse = extra.curse
	end
	return d
end

-- Java's registry order (it decides the order candidates are weighed in).
Enchantments.LIST = {
	D("protection", "Protection", 4, 10, 1, 11, 12, 11, "armor", nil, { exclusive = "armor" }),
	D("fire_protection", "Fire Protection", 4, 5, 10, 8, 18, 8, "armor", nil, { exclusive = "armor" }),
	D("feather_falling", "Feather Falling", 4, 5, 5, 6, 11, 6, "feet"),
	D("blast_protection", "Blast Protection", 4, 2, 5, 8, 13, 8, "armor", nil, { exclusive = "armor" }),
	D("projectile_protection", "Projectile Protection", 4, 5, 3, 6, 9, 6, "armor", nil, { exclusive = "armor" }),
	D("respiration", "Respiration", 3, 2, 10, 10, 40, 10, "head"),
	D("aqua_affinity", "Aqua Affinity", 1, 2, 1, 0, 41, 0, "head"),
	D("thorns", "Thorns", 3, 1, 10, 20, 60, 20, "armor", "chest"),
	D("depth_strider", "Depth Strider", 3, 2, 10, 10, 25, 10, "feet", nil, { exclusive = "boots" }),
	D("frost_walker", "Frost Walker", 2, 2, 10, 10, 25, 10, "feet", nil, { exclusive = "boots", treasure = true }),
	D("binding_curse", "Curse of Binding", 1, 1, 25, 0, 50, 0, "equippable", nil, { treasure = true, curse = true }),
	D("soul_speed", "Soul Speed", 3, 1, 10, 10, 25, 10, "feet", nil, { treasure = true }),
	D("sharpness", "Sharpness", 5, 10, 1, 11, 21, 11, "sharp_weapon", "sword", { exclusive = "damage" }),
	D("smite", "Smite", 5, 5, 5, 8, 25, 8, "weapon", "sword", { exclusive = "damage" }),
	D("bane_of_arthropods", "Bane of Arthropods", 5, 5, 5, 8, 25, 8, "weapon", "sword", { exclusive = "damage" }),
	D("knockback", "Knockback", 2, 5, 5, 20, 55, 20, "sword"),
	D("fire_aspect", "Fire Aspect", 2, 2, 10, 20, 60, 20, "sword"),
	D("looting", "Looting", 3, 2, 15, 9, 65, 9, "sword"),
	D("sweeping_edge", "Sweeping Edge", 3, 2, 5, 9, 20, 9, "sword"),
	D("efficiency", "Efficiency", 5, 10, 1, 10, 51, 10, "mining"),
	D("silk_touch", "Silk Touch", 1, 1, 15, 0, 65, 0, "mining_loot", nil, { exclusive = "mining" }),
	D("unbreaking", "Unbreaking", 3, 5, 5, 8, 55, 8, "durability"),
	D("fortune", "Fortune", 3, 2, 15, 9, 65, 9, "mining_loot", nil, { exclusive = "mining" }),
	D("power", "Power", 5, 10, 1, 10, 16, 10, "bow"),
	D("punch", "Punch", 2, 2, 12, 20, 37, 20, "bow"),
	D("flame", "Flame", 1, 2, 20, 0, 50, 0, "bow"),
	D("infinity", "Infinity", 1, 1, 20, 0, 50, 0, "bow", nil, { exclusive = "bow" }),
	D("luck_of_the_sea", "Luck of the Sea", 3, 2, 15, 9, 65, 9, "fishing"),
	D("lure", "Lure", 3, 2, 15, 9, 65, 9, "fishing"),
	D("loyalty", "Loyalty", 3, 5, 12, 7, 50, 0, "trident"),
	D("impaling", "Impaling", 5, 2, 1, 8, 21, 8, "trident"),
	D("riptide", "Riptide", 3, 2, 17, 7, 50, 0, "trident", nil, { exclusive = "riptide" }),
	D("channeling", "Channeling", 1, 1, 25, 0, 50, 0, "trident"),
	D("multishot", "Multishot", 1, 2, 20, 0, 50, 0, "crossbow", nil, { exclusive = "crossbow" }),
	D("quick_charge", "Quick Charge", 3, 5, 12, 20, 50, 0, "crossbow"),
	D("piercing", "Piercing", 4, 10, 1, 10, 50, 0, "crossbow", nil, { exclusive = "crossbow" }),
	D("mending", "Mending", 1, 2, 25, 25, 75, 25, "durability", nil, { exclusive = "bow", treasure = true }),
	D("vanishing_curse", "Curse of Vanishing", 1, 1, 25, 0, 50, 0, "vanishing", nil, { treasure = true, curse = true }),
}

local byId: { [string]: Def } = {}
for _, d in Enchantments.LIST do
	byId[d.id] = d
end
Enchantments.byId = byId

function Enchantments.minCost(d: Def, level: number): number
	return d.minBase + d.minPer * (level - 1)
end
function Enchantments.maxCost(d: Def, level: number): number
	return d.maxBase + d.maxPer * (level - 1)
end

-- Riptide can't go with Loyalty or Channeling; Infinity and Mending exclude each other ("bow").
local EXTRA_CONFLICTS: { [string]: { [string]: boolean } } = {
	riptide = { loyalty = true, channeling = true },
	loyalty = { riptide = true },
	channeling = { riptide = true },
}

-- Enchantment.areCompatible: different, and not in the same exclusive set.
function Enchantments.compatible(a: string, b: string): boolean
	if a == b then
		return false
	end
	local da, db = byId[a], byId[b]
	if not da or not db then
		return true
	end
	if da.exclusive and da.exclusive == db.exclusive and da.exclusive ~= "riptide" then
		return false
	end
	local x = EXTRA_CONFLICTS[a]
	return not (x and x[b])
end

-- Items ---------------------------------------------------------------------------------------

local TOOL_KINDS = { sword = true, axe = true, pickaxe = true, shovel = true, hoe = true }
local ARMOR_SLOTS = { helmet = "head", chestplate = "chest", leggings = "legs", boots = "feet" }
local TOOL_ENCHANTABILITY = { wooden = 15, stone = 5, iron = 14, golden = 22, diamond = 10, cindersteel = 15 }
local ARMOR_ENCHANTABILITY = { leather = 15, chainmail = 12, iron = 9, golden = 25, diamond = 10, cindersteel = 15, turtle = 9 }

-- The categories an item belongs to (Java item tags).
function Enchantments.categories(item: string): { [string]: boolean }
	local c: { [string]: boolean } = {}
	if item == "book" or item == "enchanted_book" then
		return c
	end
	local material, kind = string.match(item, "^(.-)_([%a]+)$")
	if kind and TOOL_KINDS[kind] and material and TOOL_ENCHANTABILITY[material] then
		c[kind] = true
		c.durability = true
		c.vanishing = true
		if kind == "sword" or kind == "axe" then
			c.sharp_weapon = true
			c.weapon = true
		end
		if kind ~= "sword" then
			c.mining = true
			c.mining_loot = true
		end
	elseif kind and ARMOR_SLOTS[kind] and material and ARMOR_ENCHANTABILITY[material] then
		c.armor = true
		c[ARMOR_SLOTS[kind]] = true
		c.equippable = true
		c.durability = true
		c.vanishing = true
	elseif item == "turtle_helmet" then
		c.armor, c.head, c.equippable, c.durability, c.vanishing = true, true, true, true, true
	elseif item == "bow" or item == "crossbow" or item == "crossbow_loaded" or item == "fishing_rod" or item == "trident" then
		local cat = if item == "fishing_rod" then "fishing" elseif item == "crossbow_loaded" then "crossbow" else item
		c[cat] = true
		c.durability = true
		c.vanishing = true
	elseif item == "shears" then
		c.mining = true -- (Efficiency by anvil only: shears can't go in the enchanting table)
		c.durability = true
		c.vanishing = true
	elseif item == "shield" or item == "flint_and_steel" or item == "elytra" or item == "carrot_on_a_stick"
		or item == "brush"
	then
		c.durability = true
		c.vanishing = true
		if item == "elytra" then
			c.equippable = true
		end
	elseif item == "carved_pumpkin" or item == "compass" or item == "recovery_compass" then
		c.vanishing = true
		if item == "carved_pumpkin" then
			c.equippable = true
		end
	end
	return c
end

-- Java's enchantable component: 0 = the table won't take it.
function Enchantments.enchantability(item: string): number
	if item == "book" or item == "bow" or item == "crossbow" or item == "fishing_rod" or item == "trident" then
		return 1
	end
	local material, kind = string.match(item, "^(.-)_([%a]+)$")
	if kind and material then
		if TOOL_KINDS[kind] then
			return TOOL_ENCHANTABILITY[material] or 0
		elseif ARMOR_SLOTS[kind] then
			return ARMOR_ENCHANTABILITY[material] or 0
		end
	end
	if item == "turtle_helmet" then
		return 9
	end
	return 0
end

-- Can this stack go through the enchanting table? (enchantable, not enchanted yet; a book only
-- one at a time)
function Enchantments.canEnchant(stack: { item: string, count: number, ench: { [string]: number }? }?): boolean
	if not stack or Enchantments.enchantability(stack.item) <= 0 then
		return false
	end
	if stack.ench and next(stack.ench) then
		return false
	end
	return stack.item ~= "book" or stack.count == 1
end

-- Can enchantment `id` sit on `item` at all? (anvil, commands; books take anything)
function Enchantments.supports(id: string, item: string): boolean
	local d = byId[id]
	if not d then
		return false
	end
	if item == "book" or item == "enchanted_book" then
		return true
	end
	return Enchantments.categories(item)[d.supported] == true
end

-- Display --------------------------------------------------------------------------------------

local ROMAN = { "I", "II", "III", "IV", "V", "VI", "VII", "VIII", "IX", "X" }
function Enchantments.roman(n: number): string
	return ROMAN[n] or tostring(n)
end

-- "Sharpness III"; one-level enchantments show no number (Java)
function Enchantments.label(id: string, level: number): string
	local d = byId[id]
	if not d then
		return id
	end
	if d.max == 1 and level == 1 then
		return d.name
	end
	return `{d.name} {Enchantments.roman(level)}`
end

-- Tooltip lines in Java's order (registry order). Curses first are red in Java; `curse` tells.
function Enchantments.lines(ench: { [string]: number }?): { { text: string, curse: boolean } }
	local out = {}
	if not ench then
		return out
	end
	for _, d in Enchantments.LIST do
		local l = ench[d.id]
		if l then
			table.insert(out, { text = Enchantments.label(d.id, l), curse = d.curse == true })
		end
	end
	return out
end

-- The enchanting table -------------------------------------------------------------------------

-- Bookshelf spots (EnchantingTableBlock.BOOKSHELF_OFFSETS): two blocks out on one horizontal
-- axis, up to two along the other, at the table's height or one above; the block between (the
-- offset halved, rounded toward zero) must let power through (air, plants, snow layers...).
function Enchantments.bookshelves(get: (number, number, number) -> number, x: number, y: number, z: number,
	isShelf: (number) -> boolean, transmits: (number) -> boolean): number
	local n = 0
	for dy = 0, 1 do
		for dx = -2, 2 do
			for dz = -2, 2 do
				if math.abs(dx) == 2 or math.abs(dz) == 2 then
					local mx = if dx < 0 then -math.floor(-dx / 2) else math.floor(dx / 2)
					local mz = if dz < 0 then -math.floor(-dz / 2) else math.floor(dz / 2)
					if isShelf(get(x + dx, y + dy, z + dz)) and transmits(get(x + mx, y + dy, z + mz)) then
						n += 1
					end
				end
			end
		end
	end
	return n
end

-- Java Math.round(float): floor(x + 0.5) in float.
local f32buf = buffer.create(4)
local function f32(x: number): number
	buffer.writef32(f32buf, 0, x)
	return buffer.readf32(f32buf, 0)
end

-- EnchantmentHelper.getEnchantmentCost
local function slotCost(r: JavaRandom.JavaRandom, slot: number, shelves: number, enchantability: number): number
	if enchantability <= 0 then
		return 0
	end
	shelves = math.min(shelves, 15)
	local i = r:nextInt(8) + 1 + bit32.rshift(shelves, 1) + r:nextInt(shelves + 1)
	if slot == 0 then
		return math.max(i // 3, 1)
	elseif slot == 1 then
		return i * 2 // 3 + 1
	end
	return math.max(i, shelves * 2)
end

export type Entry = { id: string, level: number }

-- EnchantmentHelper.getAvailableEnchantmentResults: each candidate's highest level whose cost
-- range holds `level`.
local function available(level: number, item: string): { Entry }
	local out = {}
	local isBook = item == "book"
	local cats = Enchantments.categories(item)
	for _, d in Enchantments.LIST do
		if not d.treasure and (isBook or cats[d.primary]) then
			for l = d.max, 1, -1 do
				if level >= Enchantments.minCost(d, l) and level <= Enchantments.maxCost(d, l) then
					table.insert(out, { id = d.id, level = l })
					break
				end
			end
		end
	end
	return out
end

local function weighted(r: JavaRandom.JavaRandom, list: { Entry }): Entry?
	local total = 0
	for _, e in list do
		total += byId[e.id].weight
	end
	if total <= 0 then
		return nil
	end
	local i = r:nextInt(total)
	for _, e in list do
		i -= byId[e.id].weight
		if i < 0 then
			return e
		end
	end
	return nil
end

-- EnchantmentHelper.selectEnchantment
function Enchantments.select(r: JavaRandom.JavaRandom, item: string, level: number): { Entry }
	local out: { Entry } = {}
	local e = Enchantments.enchantability(item)
	if e <= 0 then
		return out
	end
	level += 1 + r:nextInt(e // 4 + 1) + r:nextInt(e // 4 + 1)
	local f = f32((r:nextFloat() + r:nextFloat() - 1) * 0.15)
	level = math.max(1, math.floor(f32(f32(level) + f32(level * f)) + 0.5))
	local list = available(level, item)
	if #list == 0 then
		return out
	end
	local first = weighted(r, list)
	if first then
		table.insert(out, first)
	end
	while r:nextInt(50) <= level do
		if #out > 0 then
			local last = out[#out]
			for k = #list, 1, -1 do
				if not Enchantments.compatible(list[k].id, last.id) then
					table.remove(list, k)
				end
			end
		end
		if #list == 0 then
			break
		end
		local pick = weighted(r, list)
		if pick then
			table.insert(out, pick)
		end
		level //= 2
	end
	return out
end

local function addInt(a: number, b: number): number
	return (a + b + 2147483648) % 4294967296 - 2147483648 -- Java int overflow
end

-- EnchantmentMenu.getEnchantmentList
function Enchantments.list(r: JavaRandom.JavaRandom, seed: number, item: string, slot: number, cost: number): { Entry }
	r:setSeed(addInt(seed, slot))
	local list = Enchantments.select(r, item, cost)
	if item == "book" and #list > 1 then
		table.remove(list, r:nextInt(#list) + 1)
	end
	return list
end

export type Offer = { cost: number, clue: string?, clueLevel: number? }

-- EnchantmentMenu.slotsChanged: the three offers for an item, with one enchantment shown as a
-- hint for each. A slot with cost 0 offers nothing.
function Enchantments.offers(seed: number, shelves: number, item: string): { Offer }
	local r = JavaRandom.new(seed)
	local e = Enchantments.enchantability(item)
	local offers: { Offer } = {}
	for i = 0, 2 do
		local c = slotCost(r, i, shelves, e)
		if c < i + 1 then
			c = 0
		end
		offers[i + 1] = { cost = c }
	end
	for i = 0, 2 do
		local o = offers[i + 1]
		if o.cost > 0 then
			local list = Enchantments.list(r, seed, item, i, o.cost)
			if #list > 0 then
				local pick = list[r:nextInt(#list) + 1]
				o.clue, o.clueLevel = pick.id, pick.level
			end
		end
	end
	return offers
end

-- What clicking offer `slot` (0, 1, 2) gives. Empty = nothing happens, nothing is paid.
function Enchantments.enchant(seed: number, item: string, slot: number, cost: number): { Entry }
	return Enchantments.list(JavaRandom.new(seed), seed, item, slot, cost)
end

return Enchantments
