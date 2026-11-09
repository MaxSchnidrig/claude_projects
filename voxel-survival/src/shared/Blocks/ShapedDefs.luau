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
	return out
end

return ShapedDefs
