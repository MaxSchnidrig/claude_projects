--!strict
-- Average colour (RGB 0-255) per texture key: used for item icons of blocks without art, the Parts
-- debug backend, map-like uses and as a check for the generated 16x16 art (Blocks/TextureGen).

local palette: { [string]: { number } } = {
	stone = { 125, 125, 125 },
	grass_top = { 96, 160, 56 },
	grass_side = { 118, 112, 62 },
	snowy_grass_side = { 170, 160, 150 },
	dirt = { 134, 96, 67 },
	cobblestone = { 105, 105, 108 },
	bedrock = { 45, 45, 48 },
	sand = { 220, 208, 160 },
	gravel = { 138, 128, 126 },
	sandstone_top = { 222, 206, 154 },
	sandstone_side = { 210, 192, 140 },
	water = { 48, 92, 205 },
	lava = { 232, 104, 24 },
	snow = { 244, 250, 252 },
	ice = { 150, 190, 250 },
	clay = { 160, 166, 180 },

	oak_log = { 104, 82, 50 },
	oak_log_top = { 164, 132, 82 },
	oak_leaves = { 58, 128, 40 },
	oak_planks = { 164, 132, 80 },
	birch_log = { 218, 216, 208 },
	birch_log_top = { 192, 172, 120 },
	birch_leaves = { 104, 152, 64 },
	birch_planks = { 196, 180, 124 },
	spruce_log = { 62, 42, 22 },
	spruce_log_top = { 112, 82, 50 },
	spruce_leaves = { 48, 88, 56 },
	spruce_planks = { 116, 86, 52 },

	coal_ore = { 78, 78, 80 },
	iron_ore = { 168, 142, 122 },
	copper_ore = { 156, 112, 80 },
	gold_ore = { 204, 182, 72 },
	diamond_ore = { 104, 204, 204 },
	emerald_ore = { 62, 182, 92 },
	lapis_ore = { 52, 72, 172 },
	volt_ore = { 150, 64, 204 },

	glass = { 205, 232, 240 },
	obsidian = { 26, 16, 40 },
	crafting_table_top = { 150, 110, 60 },
	crafting_table_side = { 130, 95, 55 },
	furnace_top = { 110, 110, 110 },
	furnace_side = { 90, 90, 92 },
	chest = { 160, 112, 40 },
	tnt_top = { 200, 60, 50 },
	tnt_side = { 210, 70, 55 },
	white_wool = { 236, 236, 236 },
	torch = { 250, 200, 90 },
	fire = { 240, 140, 40 },
	campfire_log = { 96, 70, 42 },
	campfire_top = { 120, 92, 56 },
	ladder = { 150, 116, 66 },
	oak_door_lower = { 154, 122, 72 },
	oak_door_upper = { 140, 124, 96 },
	spruce_door_lower = { 108, 80, 48 },
	spruce_door_upper = { 100, 84, 70 },
	birch_door_lower = { 190, 174, 120 },
	birch_door_upper = { 170, 166, 140 },
	iron_door_lower = { 196, 196, 200 },
	iron_door_upper = { 186, 188, 194 },
	oak_trapdoor = { 150, 118, 70 },
	spruce_trapdoor = { 106, 78, 46 },
	birch_trapdoor = { 188, 172, 118 },
	iron_trapdoor = { 192, 192, 198 },
	iron_bars = { 110, 112, 118 },
	vine = { 52, 108, 34 },
	white_bed = { 234, 236, 236 },
	orange_bed = { 240, 118, 20 },
	magenta_bed = { 190, 68, 180 },
	light_blue_bed = { 58, 176, 218 },
	yellow_bed = { 248, 198, 40 },
	lime_bed = { 112, 186, 26 },
	pink_bed = { 238, 142, 172 },
	gray_bed = { 62, 68, 72 },
	light_gray_bed = { 142, 142, 134 },
	cyan_bed = { 22, 138, 146 },
	purple_bed = { 122, 42, 172 },
	blue_bed = { 54, 58, 158 },
	brown_bed = { 114, 72, 40 },
	green_bed = { 84, 108, 28 },
	red_bed = { 160, 38, 34 },
	black_bed = { 22, 22, 26 },
}

-- Flowing water and lava levels reuse the source colour (their own keys let the renderer give
-- each level its own surface height).
for _, f in { "water", "lava" } do
	for level = 1, 7 do
		palette[`{f}_{level}`] = palette[f]
	end
	palette[`{f}_falling`] = palette[f]
end

return palette
