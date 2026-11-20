--!strict
-- Generated block defs for the first non-cube blocks (Phase 8b): slabs, stairs, fences, doors,
-- ladders and signs. Every orientation / state is its own block id (like Java block states).
--
-- IDS ARE PERMANENT. Each family has a fixed base id and a fixed order below; only ever append
-- new materials at the end of a list, never reorder.
--
--   100..117  slabs   6 materials x (bottom, top, double)
--   120..167  stairs  6 materials x 4 facings x (bottom, top)      facing order N, E, S, W
--   170..172  fences  oak, spruce, birch
--   180..247  doors   oak, spruce, birch, iron x 17: 16 lower states (facing x open x hinge) + upper
--   250..253  ladder  facing N, E, S, W (the side it faces; its wall is behind it)
--   260..319  signs   oak, spruce, birch x 20: 16 standing rotations + 4 wall facings
--   380..443  trapdoors     oak, spruce, birch, iron x 16 (facing x half x open)
--   450..473  fence gates   oak, spruce, birch x 8 (facing x open)
--   480..481  walls         cobblestone, sandstone (connections follow neighbours)
--   490, 491  glass pane, iron bars (connections follow neighbours)
--   500..530  vines         one id per set of faces (north 1, east 2, south 4, west 8, up 16)
--   540..599  hanging signs oak, spruce, birch x 20: 16 ceiling rotations + 4 wall facings
--   600..727  beds          16 colours x 8 (facing x foot / head)
--   730..732  plants        short grass, dandelion, poppy (Phase 9a)
--   733..740  farmland      moisture 0..7
--   741..748  wheat         age 0..7
--   749..756  carrots       age 0..7
--   757..764  potatoes      age 0..7
--   765..768  beetroots     age 0..3
--   769..772  flowers       azure bluet, oxeye daisy, cornflower, red tulip (Phase 9b)
--   773..778  saplings      oak, birch, spruce x stage 0..1
--   779..794  sugar cane    age 0..15
--   795..810  cactus        age 0..15
--   811, 812  pumpkin, melon
--   813..820  pumpkin stem  age 0..7;  821..824 attached pumpkin stem facing N, E, S, W
--   825..832  melon stem    age 0..7;  833..836 attached melon stem facing N, E, S, W
--   841..855  coloured wool (Phase 9e), Java colour order without white (white_wool is 37)
--   856..871  carpets       16 colours
--   872..887  stained glass 16 colours
--   888..903  stained glass panes 16 colours
--   904       enchanting table (Phase 10b);  905 bookshelf

local ShapedDefs = {}

export type Def = { [string]: any }

local FACINGS = { "north", "east", "south", "west" }
ShapedDefs.FACINGS = FACINGS

-- Slab / stairs materials: key prefix, display name, textures, hardness, tool, tier, flammable, sound
local MATERIALS = {
	{ key = "oak", name = "Oak", tex = { all = "oak_planks" }, hardness = 2.0, tool = "axe", flammable = { 5, 20 } },
	{ key = "spruce", name = "Spruce", tex = { all = "spruce_planks" }, hardness = 2.0, tool = "axe", flammable = { 5, 20 } },
	{ key = "birch", name = "Birch", tex = { all = "birch_planks" }, hardness = 2.0, tool = "axe", flammable = { 5, 20 } },
	{ key = "cobblestone", name = "Cobblestone", tex = { all = "cobblestone" }, hardness = 2.0, tool = "pickaxe", minTier = 1 },
	{ key = "stone", name = "Stone", tex = { all = "stone" }, hardness = 1.5, slabHardness = 2.0, tool = "pickaxe", minTier = 1 },
	{ key = "sandstone", name = "Sandstone", tex = { top = "sandstone_top", side = "sandstone_side", bottom = "sandstone_top" }, hardness = 0.8, slabHardness = 2.0, tool = "pickaxe", minTier = 1 },
}
ShapedDefs.MATERIALS = MATERIALS
-- the full block each material is made from (recipes)
ShapedDefs.BASE_BLOCK = {
	oak = "oak_planks", spruce = "spruce_planks", birch = "birch_planks",
	cobblestone = "cobblestone", stone = "stone", sandstone = "sandstone",
}

local WOODS = { "oak", "spruce", "birch" }
ShapedDefs.BED_COLORS = { "white", "orange", "magenta", "light_blue", "yellow", "lime", "pink", "gray", "light_gray", "cyan", "purple", "blue", "brown", "green", "red", "black" }
ShapedDefs.WOODS = WOODS
local DOORS = { "oak", "spruce", "birch", "iron" }
ShapedDefs.DOORS = DOORS

local function cap(s: string): string
	return string.upper(string.sub(s, 1, 1)) .. string.sub(s, 2)
end

function ShapedDefs.list(): { Def }
	local out: { Def } = {}
	-- slabs
	for i, m in MATERIALS do
		local base = 100 + (i - 1) * 3
		local family = `{m.key}_slab`
		local common = function(id: number, key: string, half: string): Def
			return {
				id = id, key = key, name = `{m.name} Slab`, hardness = m.slabHardness or m.hardness,
				tool = m.tool, minTier = m.minTier, textures = m.tex, flammable = m.flammable,
				transparent = half ~= "double", opacity = if half == "double" then nil else 0,
				shape = if half == "double" then "cube" else "slab",
				state = { half = half }, family = family,
				drop = family, dropMin = if half == "double" then 2 else 1,
				noItem = key ~= family, icon = "slab",
			}
		end
		table.insert(out, common(base, family, "bottom"))
		table.insert(out, common(base + 1, `{family}_top`, "top"))
		table.insert(out, common(base + 2, `{family}_double`, "double"))
	end
	-- stairs
	for i, m in MATERIALS do
		local family = `{m.key}_stairs`
		for f, facing in FACINGS do
			for h, half in { "bottom", "top" } do
				local id = 120 + (i - 1) * 8 + (f - 1) * 2 + (h - 1)
				local key = if f == 1 and h == 1 then family else `{family}_{facing}_{half}`
				table.insert(out, {
					id = id, key = key, name = `{m.name} Stairs`, hardness = m.hardness, tool = m.tool,
					minTier = m.minTier, textures = m.tex, flammable = m.flammable, transparent = true,
					opacity = 0, shape = "stairs", state = { facing = facing, half = half }, family = family,
					drop = family, noItem = key ~= family, icon = "stairs",
				})
			end
		end
	end
	-- fences
	for i, w in WOODS do
		table.insert(out, {
			id = 170 + i - 1, key = `{w}_fence`, name = `{cap(w)} Fence`, hardness = 2.0, tool = "axe",
			textures = { all = `{w}_planks` }, flammable = { 5, 20 }, transparent = true, opacity = 0,
			shape = "fence", family = `{w}_fence`, icon = "fence",
		})
	end
	-- doors
	for t, d in ipairs(DOORS) do
		local base = 180 + (t - 1) * 17
		local family = `{d}_door`
		local iron = d == "iron"
		local props = {
			name = if iron then "Iron Door" else `{cap(d)} Door`, hardness = if iron then 5.0 else 3.0,
			tool = if iron then "pickaxe" else "axe", minTier = if iron then 1 else nil,
			flammable = if iron then nil else { 5, 20 }, transparent = true, opacity = 0, shape = "door",
			family = family, drop = family, icon = "door", sound = if iron then "stone" else "wood",
		}
		for f, facing in FACINGS do
			for open = 0, 1 do
				for hinge = 0, 1 do
					local id = base + (f - 1) * 4 + open * 2 + hinge
					local key = if id == base then family else `{family}_{facing}_{if open == 1 then "open" else "closed"}_{if hinge == 1 then "right" else "left"}`
					local def: Def = table.clone(props)
					def.id = id
					def.key = key
					def.textures = { all = `{d}_door_lower` }
					def.state = { facing = facing, open = open == 1, hinge = if hinge == 1 then "right" else "left", upper = false }
					def.noItem = key ~= family
					table.insert(out, def)
				end
			end
		end
		local upper: Def = table.clone(props)
		upper.id = base + 16
		upper.key = `{family}_upper`
		upper.textures = { all = `{d}_door_upper` }
		upper.state = { upper = true }
		upper.noItem = true
		table.insert(out, upper)
	end
	-- ladders
	for f, facing in FACINGS do
		table.insert(out, {
			id = 250 + f - 1, key = if f == 1 then "ladder" else `ladder_{facing}`, name = "Ladder",
			hardness = 0.4, tool = "axe", textures = { all = "ladder" }, solid = true, transparent = true,
			opacity = 0, shape = "ladder", state = { facing = facing }, family = "ladder", drop = "ladder",
			noItem = f ~= 1, icon = "ladder", sound = "wood", flammable = nil,
		})
	end
	-- signs
	for t, w in WOODS do
		local base = 260 + (t - 1) * 20
		local family = `{w}_sign`
		for r = 0, 15 do
			table.insert(out, {
				id = base + r, key = if r == 0 then family else `{family}_{r}`, name = `{cap(w)} Sign`,
				hardness = 1.0, tool = "axe", textures = { all = `{w}_planks` }, solid = false,
				transparent = true, opacity = 0, shape = "sign", state = { rotation = r }, family = family,
				drop = family, noItem = r ~= 0, icon = "sign", sound = "wood", flammable = { 5, 20 },
			})
		end
		for f, facing in FACINGS do
			table.insert(out, {
				id = base + 16 + f - 1, key = `{w}_wall_sign_{facing}`, name = `{cap(w)} Sign`,
				hardness = 1.0, tool = "axe", textures = { all = `{w}_planks` }, solid = false,
				transparent = true, opacity = 0, shape = "wall_sign", state = { facing = facing },
				family = family, drop = family, noItem = true, icon = "sign", sound = "wood", flammable = { 5, 20 },
			})
		end
	end
	-- trapdoors
	for t, d in ipairs(DOORS) do
		local iron = d == "iron"
		local family = `{d}_trapdoor`
		for f, facing in FACINGS do
			for h, half in { "bottom", "top" } do
				for open = 0, 1 do
					local id = 380 + (t - 1) * 16 + (f - 1) * 4 + (h - 1) * 2 + open
					local key = if f == 1 and h == 1 and open == 0 then family
						else `{family}_{facing}_{half}{if open == 1 then "_open" else ""}`
					table.insert(out, {
						id = id, key = key, name = if iron then "Iron Trapdoor" else `{cap(d)} Trapdoor`,
						hardness = if iron then 5.0 else 3.0, tool = if iron then "pickaxe" else "axe",
						minTier = if iron then 1 else nil, flammable = if iron then nil else { 5, 20 },
						textures = { all = `{d}_trapdoor` }, transparent = true, opacity = 0, shape = "trapdoor",
						state = { facing = facing, half = half, open = open == 1 }, family = family, drop = family,
						noItem = key ~= family, icon = "trapdoor", sound = if iron then "stone" else "wood",
					})
				end
			end
		end
	end
	-- fence gates
	for w, wood in WOODS do
		local family = `{wood}_fence_gate`
		for f, facing in FACINGS do
			for open = 0, 1 do
				local id = 450 + (w - 1) * 8 + (f - 1) * 2 + open
				local key = if f == 1 and open == 0 then family else `{family}_{facing}{if open == 1 then "_open" else ""}`
				table.insert(out, {
					id = id, key = key, name = `{cap(wood)} Fence Gate`, hardness = 2.0, tool = "axe",
					textures = { all = `{wood}_planks` }, flammable = { 5, 20 }, transparent = true, opacity = 0,
					shape = "fence_gate", state = { facing = facing, open = open == 1 }, family = family,
					drop = family, noItem = key ~= family, icon = "fence_gate",
				})
			end
		end
	end
	-- walls
	table.insert(out, { id = 480, key = "cobblestone_wall", name = "Cobblestone Wall", hardness = 2.0, tool = "pickaxe",
		minTier = 1, textures = { all = "cobblestone" }, transparent = true, opacity = 0, shape = "wall", icon = "wall" })
	table.insert(out, { id = 481, key = "sandstone_wall", name = "Sandstone Wall", hardness = 0.8, tool = "pickaxe",
		minTier = 1, textures = { top = "sandstone_top", side = "sandstone_side", bottom = "sandstone_top" },
		transparent = true, opacity = 0, shape = "wall", icon = "wall" })
	-- panes and bars
	table.insert(out, { id = 490, key = "glass_pane", name = "Glass Pane", hardness = 0.3, drop = false,
		textures = { all = "glass" }, transparent = true, opacity = 0, shape = "pane", state = { bars = false },
		sound = "glass", icon = "pane" })
	table.insert(out, { id = 491, key = "iron_bars", name = "Iron Bars", hardness = 5.0, tool = "pickaxe",
		textures = { all = "iron_bars" }, transparent = true, opacity = 0, shape = "pane", state = { bars = true },
		sound = "stone", icon = "bars" })
	-- vines: one id per face set
	for mask = 1, 31 do
		table.insert(out, {
			id = 499 + mask, key = if mask == 4 then "vine" else `vine_{mask}`, name = "Vines",
			hardness = 0.2, tool = "shears", textures = { all = "vine" }, solid = false, transparent = true,
			opacity = 0, shape = "vine", state = { faces = mask }, family = "vine", drop = "vine",
			noItem = mask ~= 4, icon = "vine", sound = "grass", flammable = { 15, 100 }, shearsOnly = true,
		})
	end
	-- hanging signs
	for t, w in WOODS do
		local base = 540 + (t - 1) * 20
		local family = `{w}_hanging_sign`
		for r = 0, 15 do
			table.insert(out, {
				id = base + r, key = if r == 0 then family else `{family}_{r}`, name = `{cap(w)} Hanging Sign`,
				hardness = 1.0, tool = "axe", textures = { all = `{w}_planks` }, solid = false, transparent = true,
				opacity = 0, shape = "hanging_sign", state = { rotation = r }, family = family, drop = family,
				noItem = r ~= 0, icon = "hanging_sign", sound = "wood", flammable = { 5, 20 },
			})
		end
		for f, facing in FACINGS do
			table.insert(out, {
				id = base + 16 + f - 1, key = `{w}_wall_hanging_sign_{facing}`, name = `{cap(w)} Hanging Sign`,
				hardness = 1.0, tool = "axe", textures = { all = `{w}_planks` }, solid = false, transparent = true,
				opacity = 0, shape = "wall_hanging_sign", state = { facing = facing }, family = family,
				drop = family, noItem = true, icon = "hanging_sign", sound = "wood", flammable = { 5, 20 },
			})
		end
	end
	-- beds (Java dye colour order)
	for c, colour in ShapedDefs.BED_COLORS do
		local family = `{colour}_bed`
		local name = string.gsub(" " .. colour, "_(%a)", function(a) return " " .. string.upper(a) end)
		name = string.gsub(name, " (%a)", function(a) return " " .. string.upper(a) end)
		name = string.sub(name, 2) .. " Bed"
		for f, facing in FACINGS do
			for part = 0, 1 do
				local id = 600 + (c - 1) * 8 + (f - 1) * 2 + part
				local key = if f == 1 and part == 0 then family else `{family}_{facing}_{if part == 1 then "head" else "foot"}`
				table.insert(out, {
					id = id, key = key, name = name, hardness = 0.2, textures = { all = family },
					transparent = true, opacity = 0, shape = "bed",
					state = { facing = facing, part = if part == 1 then "head" else "foot", colour = colour },
					family = family, drop = if part == 1 then family else false, noItem = key ~= family,
					icon = "bed", sound = "wool", flammable = nil,
				})
			end
		end
	end
	-- plants (Phase 9a): no collision, broken at once. Short grass is replaced by a placed block
	-- and drops seeds (Gameplay/Farming); shears give the grass itself.
	table.insert(out, {
		id = 730, key = "short_grass", name = "Short Grass", hardness = 0, drop = false, textures = { all = "short_grass" },
		transparent = true, opacity = 0, solid = false, shape = "plant", state = {}, replaceable = true,
		icon = "plant", sound = "grass", flammable = { 60, 100 },
	})
	for i, f in { { key = "dandelion", name = "Dandelion" }, { key = "poppy", name = "Poppy" } } do
		table.insert(out, {
			id = 730 + i, key = f.key, name = f.name, hardness = 0, textures = { all = f.key },
			transparent = true, opacity = 0, solid = false, shape = "plant", state = { flower = true },
			icon = "plant", sound = "grass", flammable = { 60, 100 },
		})
	end
	-- farmland: 15/16 high, moisture 0..7 (Java: wet looks darker only at 7); drops dirt
	for m = 0, 7 do
		table.insert(out, {
			id = 733 + m, key = if m == 0 then "farmland" else `farmland_moist_{m}`, name = "Farmland",
			hardness = 0.6, tool = "shovel", drop = "dirt",
			textures = { top = if m == 7 then "farmland_wet" else "farmland_dry", side = "dirt", bottom = "dirt" },
			transparent = true, opacity = 0, shape = "farmland", state = { moisture = m }, family = "farmland",
			noItem = true, sound = "gravel",
		})
	end
	-- crops: one id per age; the texture follows Java's growth stages
	local CROPS = {
		{ family = "wheat", name = "Wheat Crops", base = 741, maxAge = 7, stages = { 0, 1, 2, 3, 4, 5, 6, 7 } },
		{ family = "carrots", name = "Carrots", base = 749, maxAge = 7, stages = { 0, 0, 1, 1, 2, 2, 2, 3 } },
		{ family = "potatoes", name = "Potatoes", base = 757, maxAge = 7, stages = { 0, 0, 1, 1, 2, 2, 2, 3 } },
		{ family = "beetroots", name = "Beetroots", base = 765, maxAge = 3, stages = { 0, 1, 2, 3 } },
	}
	ShapedDefs.CROPS = CROPS
	-- Phase 9b ------------------------------------------------------------------------------
	for i, f in {
		{ key = "azure_bluet", name = "Azure Bluet" }, { key = "oxeye_daisy", name = "Oxeye Daisy" },
		{ key = "cornflower", name = "Cornflower" }, { key = "red_tulip", name = "Red Tulip" },
	} do
		table.insert(out, {
			id = 768 + i, key = f.key, name = f.name, hardness = 0, textures = { all = f.key },
			transparent = true, opacity = 0, solid = false, shape = "plant", state = { flower = true },
			icon = "plant", sound = "grass", flammable = { 60, 100 },
		})
	end
	-- saplings: stage 0 -> 1 -> a tree (random ticks / bone meal)
	for i, w in { "oak", "birch", "spruce" } do
		for stage = 0, 1 do
			local family = `{w}_sapling`
			table.insert(out, {
				id = 773 + (i - 1) * 2 + stage, key = if stage == 0 then family else `{family}_stage_1`,
				name = string.upper(string.sub(w, 1, 1)) .. string.sub(w, 2) .. " Sapling",
				hardness = 0, drop = family, textures = { all = family }, transparent = true, opacity = 0,
				solid = false, shape = "plant", state = { sapling = w, stage = stage }, family = family,
				noItem = stage ~= 0, icon = "plant", sound = "grass",
			})
		end
	end
	-- sugar cane and cactus: age 0..15, a new block on top at 15, up to 3 tall
	for age = 0, 15 do
		table.insert(out, {
			id = 779 + age, key = if age == 0 then "sugar_cane" else `sugar_cane_age_{age}`, name = "Sugar Cane",
			hardness = 0, drop = "sugar_cane", textures = { all = "sugar_cane" }, transparent = true, opacity = 0,
			solid = false, shape = "plant", state = { cane = true, age = age }, family = "sugar_cane",
			noItem = age ~= 0, icon = "plant", sound = "grass",
		})
	end
	for age = 0, 15 do
		table.insert(out, {
			id = 795 + age, key = if age == 0 then "cactus" else `cactus_age_{age}`, name = "Cactus",
			hardness = 0.4, drop = "cactus", textures = { top = "cactus_top", side = "cactus_side", bottom = "cactus_bottom" },
			transparent = true, opacity = 0, shape = "cactus", state = { age = age }, family = "cactus",
			noItem = age ~= 0, sound = "wool",
		})
	end
	table.insert(out, {
		id = 811, key = "pumpkin", name = "Pumpkin", hardness = 1.0, tool = "axe",
		textures = { top = "pumpkin_top", side = "pumpkin_side", bottom = "pumpkin_top" }, sound = "wood",
	})
	table.insert(out, {
		id = 812, key = "melon", name = "Melon", hardness = 1.0, tool = "axe", drop = "melon_slice", dropMin = 3, dropMax = 7,
		textures = { top = "melon_top", side = "melon_side", bottom = "melon_top" }, sound = "wood",
	})
	-- stems (planted from seeds on farmland): grow like crops, then grow their fruit beside them
	for s, fruit in { "pumpkin", "melon" } do
		local base = if s == 1 then 813 else 825
		for age = 0, 7 do
			table.insert(out, {
				id = base + age, key = if age == 0 then `{fruit}_stem` else `{fruit}_stem_age_{age}`,
				name = string.upper(string.sub(fruit, 1, 1)) .. string.sub(fruit, 2) .. " Stem",
				hardness = 0, drop = false, textures = { all = "stem" }, transparent = true, opacity = 0, solid = false,
				shape = "crop", state = { crop = `{fruit}_stem`, age = age, maxAge = 7, fruit = fruit, stem = true },
				family = `{fruit}_stem`, noItem = true, sound = "wood",
			})
		end
		for f, facing in { "north", "east", "south", "west" } do
			table.insert(out, {
				id = base + 7 + f, key = `attached_{fruit}_stem_{facing}`, name = "Attached Stem",
				hardness = 0, drop = false, textures = { all = "attached_stem" }, transparent = true, opacity = 0,
				solid = false, shape = "plant", state = { attachedStem = fruit, facing = facing },
				family = `attached_{fruit}_stem`, noItem = true, sound = "wood",
			})
		end
	end
	for _, c in CROPS do
		for age = 0, c.maxAge do
			table.insert(out, {
				id = c.base + age, key = if age == 0 then c.family else `{c.family}_age_{age}`, name = c.name,
				hardness = 0, drop = false, textures = { all = `{c.family}_stage_{c.stages[age + 1]}` },
				transparent = true, opacity = 0, solid = false, shape = "crop",
				state = { crop = c.family, age = age, maxAge = c.maxAge }, family = c.family,
				noItem = true, sound = "grass", flammable = { 60, 100 },
			})
		end
	end
	-- Phase 9e: the 16 colours (Java dye order, ShapedDefs.BED_COLORS)
	for c, colour in ShapedDefs.BED_COLORS do
		local name = ShapedDefs.colorName(colour)
		local woolTex = `{colour}_wool`
		if c > 1 then
			table.insert(out, {
				id = 839 + c, key = woolTex, name = `{name} Wool`, hardness = 0.8, tool = "shears",
				textures = { all = woolTex }, sound = "wool", flammable = { 30, 60 },
			})
		end
		-- carpet: a 1/16 sheet of wool that needs a block under it (Java CarpetBlock)
		table.insert(out, {
			id = 855 + c, key = `{colour}_carpet`, name = `{name} Carpet`, hardness = 0.1,
			textures = { all = woolTex }, transparent = true, opacity = 0, shape = "carpet",
			sound = "wool", flammable = { 60, 20 },
		})
		-- stained glass drops nothing without Silk Touch, like glass (Java)
		table.insert(out, {
			id = 871 + c, key = `{colour}_stained_glass`, name = `{name} Stained Glass`, hardness = 0.3,
			drop = false, textures = { all = `{colour}_stained_glass` }, transparent = true, sound = "glass",
		})
		table.insert(out, {
			id = 887 + c, key = `{colour}_stained_glass_pane`, name = `{name} Stained Glass Pane`, hardness = 0.3,
			drop = false, textures = { all = `{colour}_stained_glass` }, transparent = true, opacity = 0,
			shape = "pane", state = { bars = false }, sound = "glass", icon = "pane",
		})
	end
	-- Phase 10b: the enchanting table (Java: 12/16 high, light 7, needs a pickaxe) and bookshelves
	-- (drop 3 books; Silk Touch keeps the block, 10c)
	table.insert(out, {
		id = 904, key = "enchanting_table", name = "Enchanting Table", hardness = 5, tool = "pickaxe", minTier = 1,
		textures = { top = "enchanting_table_top", side = "enchanting_table_side", bottom = "obsidian" },
		transparent = true, opacity = 0, light = 7, shape = "enchanting_table", sound = "stone",
	})
	table.insert(out, {
		id = 905, key = "bookshelf", name = "Bookshelf", hardness = 1.5, tool = "axe", drop = "book", dropMin = 3, dropMax = 3,
		textures = { top = "oak_planks", side = "bookshelf", bottom = "oak_planks" }, sound = "wood", flammable = { 30, 20 },
	})
	return out
end

-- "light_blue" -> "Light Blue"
function ShapedDefs.colorName(colour: string): string
	local words = {}
	for w in string.gmatch(colour, "[^_]+") do
		table.insert(words, string.upper(string.sub(w, 1, 1)) .. string.sub(w, 2))
	end
	return table.concat(words, " ")
end

return ShapedDefs
