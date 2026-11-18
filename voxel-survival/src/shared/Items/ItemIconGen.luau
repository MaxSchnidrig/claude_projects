--!strict
-- ROCRAFT's own 16x16 item icons (pure, deterministic): every non-block item is a pixel-art
-- sprite from Items/ItemSprites; block items with a shape icon (doors, plants, beds...) are drawn
-- here from their textures. Full blocks get 3D icons (Items/BlockIconGen).
-- Output: 16 x 16 RGBA buffer, transparent background. Blocks use their face texture instead.

local TextureGen = require(script.Parent.Parent.Blocks.TextureGen)
local ItemSprites = require(script.Parent.ItemSprites)

local ItemIconGen = {}

local N = 16

local function new(): buffer
	return buffer.create(N * N * 4) -- all zero = transparent
end

local function put(img: buffer, x: number, y: number, c: { number }, a: number?)
	if x < 0 or y < 0 or x >= N or y >= N then
		return
	end
	local o = (y * N + x) * 4
	buffer.writeu8(img, o, math.clamp(math.floor(c[1]), 0, 255))
	buffer.writeu8(img, o + 1, math.clamp(math.floor(c[2]), 0, 255))
	buffer.writeu8(img, o + 2, math.clamp(math.floor(c[3]), 0, 255))
	buffer.writeu8(img, o + 3, a or 255)
end

local function shade(c: { number }, f: number): { number }
	return { c[1] * f, c[2] * f, c[3] * f }
end

-- Dark 1-pixel outline around everything drawn (reads well on any slot background).
local function outline(img: buffer, color: { number })
	local solid = table.create(N * N, false)
	for i = 0, N * N - 1 do
		solid[i + 1] = buffer.readu8(img, i * 4 + 3) > 0
	end
	for y = 0, N - 1 do
		for x = 0, N - 1 do
			if not solid[y * N + x + 1] then
				for _, d in { { 1, 0 }, { -1, 0 }, { 0, 1 }, { 0, -1 } } do
					local nx, ny = x + d[1], y + d[2]
					if nx >= 0 and ny >= 0 and nx < N and ny < N and solid[ny * N + nx + 1] then
						put(img, x, y, color)
						break
					end
				end
			end
		end
	end
end

local HANDLE = { 124, 88, 48 }

local function handle(img: buffer, from: number, to: number)
	-- diagonal from bottom-left upward to the right
	for i = from, to do
		put(img, i, 15 - i, if i % 2 == 0 then HANDLE else shade(HANDLE, 0.8))
	end
end

local tools: { [string]: (buffer, { number }) -> () } = {
	pickaxe = function(img, c)
		handle(img, 2, 10)
		-- a curved head across the top-right
		for _, p in { { 5, 2 }, { 6, 2 }, { 7, 2 }, { 8, 3 }, { 9, 3 }, { 10, 4 }, { 11, 5 }, { 12, 6 }, { 12, 7 }, { 13, 8 }, { 13, 9 }, { 13, 10 },
			{ 6, 3 }, { 7, 3 }, { 9, 4 }, { 10, 5 }, { 11, 6 }, { 12, 8 } } do
			put(img, p[1], p[2], if p[2] <= 3 or p[1] >= 13 then shade(c, 1.15) else c)
		end
	end,
	axe = function(img, c)
		handle(img, 2, 11)
		for y = 2, 7 do
			for x = 8, 12 do
				if x - 8 + (7 - y) >= 2 and not (x == 12 and (y == 2 or y == 7)) then
					put(img, x, y, if x == 12 then shade(c, 1.2) else c)
				end
			end
		end
	end,
	shovel = function(img, c)
		handle(img, 2, 9)
		for y = 1, 6 do
			for x = 9, 14 do
				local dx, dy = x - 11.5, y - 3.5
				if dx * dx + dy * dy < 7 then
					put(img, x, y, if dx + dy < -1 then shade(c, 1.2) else c)
				end
			end
		end
	end,
	hoe = function(img, c)
		handle(img, 2, 11)
		for x = 8, 12 do
			put(img, x, 3, shade(c, 1.1))
			put(img, x, 4, c)
		end
		put(img, 8, 5, c)
	end,
	sword = function(img, c)
		-- grip and guard bottom-left, blade up to the top-right
		for i = 1, 3 do
			put(img, i, 15 - i, HANDLE)
		end
		for _, p in { { 3, 10 }, { 4, 11 }, { 2, 9 }, { 5, 12 }, { 4, 9 }, { 3, 11 } } do
			put(img, p[1], p[2], shade(c, 0.7))
		end
		for i = 4, 13 do
			put(img, i, 15 - i, c)
			put(img, i + 1, 15 - i, shade(c, 1.25))
			put(img, i, 14 - i, shade(c, 0.85))
		end
	end,
}

local function bar(img: buffer, c: { number })
	for y = 6, 10 do
		for x = 3 + (10 - y) // 2, 12 - (y - 6) // 3 do
			put(img, x, y, if y == 6 then shade(c, 1.2) elseif y == 10 then shade(c, 0.75) else c)
		end
	end
end

local function lump(img: buffer, c: { number }, seed: number)
	for y = 3, 12 do
		for x = 3, 12 do
			local dx, dy = x - 7.5, y - 7.5
			local r = 4.6 + math.sin(seed + math.atan2(dy, dx) * 3) * 0.8
			if dx * dx + dy * dy < r * r then
				put(img, x, y, shade(c, 1 - (dx + dy) * 0.04))
			end
		end
	end
end

local function gem(img: buffer, c: { number })
	for y = 3, 12 do
		local half = if y < 6 then (y - 2) * 1.5 else (12 - y) * 0.9
		for x = 8 - math.floor(half), 7 + math.floor(half) do
			put(img, x, y, if y < 6 then shade(c, 1.25) elseif x < 8 then c else shade(c, 0.8))
		end
	end
end

local function dust(img: buffer, c: { number })
	for i = 0, 13 do
		local x = 3 + (i * 7) % 10
		local y = 5 + (i * 5) % 8
		put(img, x, y, if i % 3 == 0 then shade(c, 1.2) else c)
	end
end

local function stick(img: buffer, c: { number })
	for i = 3, 12 do
		put(img, i, 15 - i, c)
		put(img, i + 1, 15 - i, shade(c, 0.8))
	end
end

local function round(img: buffer, c: { number }, stem: boolean)
	for y = 4, 13 do
		for x = 3, 12 do
			local dx, dy = x - 7.5, y - 8.5
			if dx * dx + dy * dy < 20 then
				put(img, x, y, shade(c, if dx + dy < -2 then 1.25 else 1 - (dx + dy) * 0.03))
			end
		end
	end
	if stem then
		put(img, 8, 3, { 90, 60, 30 })
		put(img, 9, 2, { 70, 140, 50 })
	end
end

local function meat(img: buffer, c: { number })
	for y = 4, 12 do
		for x = 2, 12 do
			local dx, dy = (x - 7) / 5, (y - 8) / 3.8
			if dx * dx + dy * dy < 1 then
				put(img, x, y, shade(c, 1 - dy * 0.15))
			end
		end
	end
	for x = 11, 14 do
		put(img, x, 6, { 236, 230, 214 })
	end
	put(img, 14, 5, { 236, 230, 214 })
end

local function long(img: buffer, c: { number }, tip: { number }?)
	for i = 2, 13 do
		put(img, i, 15 - i, c)
	end
	if tip then
		put(img, 13, 2, tip)
		put(img, 12, 2, tip)
		put(img, 13, 3, tip)
	end
end

local function wavy(img: buffer, c: { number })
	for x = 2, 13 do
		put(img, x, 8 + math.floor(math.sin(x * 0.9) * 2.5), c)
	end
end

local function loaf(img: buffer, c: { number })
	for y = 6, 11 do
		for x = 2, 13 do
			local dx, dy = (x - 7.5) / 6, (y - 8.5) / 3
			if dx * dx + dy * dy < 1 then
				put(img, x, y, if y == 6 or (x + y) % 4 == 0 then shade(c, 1.2) else c)
			end
		end
	end
end

local function sphere(img: buffer, c: { number })
	round(img, c, false)
	put(img, 7, 8, { 20, 10, 40 })
	put(img, 8, 8, { 20, 10, 40 })
end

local function bucket(img: buffer, fill: { number }?)
	local metal = { 196, 198, 204 }
	for y = 5, 13 do
		local half = 5 - (y - 5) // 4
		for x = 8 - half, 7 + half do
			local edge = x == 8 - half or x == 7 + half or y == 13
			put(img, x, y, if edge then shade(metal, 0.75) else metal)
		end
	end
	-- handle
	for x = 4, 11 do
		put(img, x, 3, shade(metal, 0.7))
	end
	put(img, 3, 4, shade(metal, 0.7))
	put(img, 12, 4, shade(metal, 0.7))
	if fill then
		for x = 4, 11 do
			put(img, x, 5, fill)
			put(img, x, 6, shade(fill, 0.85))
		end
	end
end

-- A bowl seen from the side, optionally filled (soups and stews).
local function bowl(img: buffer, fill: { number }?)
	local wood = { 150, 106, 62 }
	for x = 2, 13 do
		put(img, x, 8, shade(wood, 1.15))
	end
	for y = 9, 12 do
		local inset = y - 9
		for x = 2 + inset, 13 - inset do
			put(img, x, y, shade(wood, 1 - inset * 0.07))
		end
	end
	if fill then
		for x = 3, 12 do
			put(img, x, 7, fill)
			put(img, x, 8, shade(fill, 0.85))
		end
	end
end

-- Seeds: a few small grains.
local function seeds(img: buffer, c: { number })
	for _, p in { { 4, 6 }, { 8, 4 }, { 11, 7 }, { 6, 10 }, { 10, 11 }, { 7, 7 } } do
		put(img, p[1], p[2], c)
		put(img, p[1] + 1, p[2], shade(c, 0.8))
		put(img, p[1], p[2] + 1, shade(c, 0.7))
	end
end

-- A sheaf of wheat: stalks gathered in the middle.
local function sheaf(img: buffer, c: { number })
	for i = 0, 4 do
		local x0 = 4 + i * 2
		for y = 2, 14 do
			local x = x0 + math.floor((y - 8) * (i - 2) * 0.12 + 0.5)
			put(img, x, y, shade(c, if y < 5 then 1.15 else 0.95))
		end
	end
	for x = 5, 11 do
		put(img, x, 9, { 140, 110, 50 }) -- the band
	end
end

local SHAPES: { [string]: (buffer, { number }, number) -> () } = {
	bowl = function(img, _c)
		bowl(img, nil)
	end,
	soup = function(img, c)
		bowl(img, c)
	end,
	seeds = function(img, c)
		seeds(img, c)
	end,
	sheaf = function(img, c)
		sheaf(img, c)
	end,
	bucket = function(img, _c)
		bucket(img, nil)
	end,
	water_bucket = function(img, c)
		bucket(img, c)
	end,
	lava_bucket = function(img, c)
		bucket(img, c)
	end,
	milk_bucket = function(img, c)
		bucket(img, c)
	end,
	-- a pie seen from the side: a wide crust with a filled top
	pie = function(img, c)
		local crust = { 200, 150, 90 }
		for y = 7, 12 do
			local inset = if y == 7 then 3 else 2
			for x = inset, 15 - inset do
				local col = if y <= 8 then c else crust
				put(img, x, y, shade(col, if y == 12 then 0.75 else if (x + y) % 4 == 0 then 0.9 else 1))
			end
		end
	end,
	-- a smooth oval, lighter at the top left
	egg = function(img, c)
		for y = 3, 13 do
			for x = 4, 11 do
				local dx, dy = (x - 7.5) / 3.8, (y - 8.2) / (if y < 8 then 5.2 else 4.8)
				if dx * dx + dy * dy <= 1 then
					put(img, x, y, shade(c, if x < 7 and y < 7 then 1.08 else if x > 9 or y > 11 then 0.85 else 1))
				end
			end
		end
	end,
	bar = function(img, c)
		bar(img, c)
	end,
	lump = lump,
	gem = function(img, c)
		gem(img, c)
	end,
	dust = function(img, c)
		dust(img, c)
	end,
	stick = function(img, c)
		stick(img, c)
	end,
	fruit = function(img, c)
		round(img, c, true)
	end,
	ball = function(img, c)
		round(img, c, false)
	end,
	meat = function(img, c)
		meat(img, c)
	end,
	arrow = function(img, c)
		long(img, { 120, 90, 60 }, c)
	end,
	feather = function(img, c)
		long(img, c, nil)
	end,
	bone = function(img, c)
		long(img, c, c)
	end,
	string = function(img, c)
		wavy(img, c)
	end,
	loaf = function(img, c)
		loaf(img, c)
	end,
	sphere = function(img, c)
		sphere(img, c)
	end,
}

-- Item key -> shape (anything unlisted is a lump in its colour).
local SHAPE_OF: { [string]: string } = {
	iron_ingot = "bar", gold_ingot = "bar", copper_ingot = "bar",
	diamond = "gem", emerald = "gem", lapis_lazuli = "gem",
	volt_dust = "dust", gunpowder = "dust",
	stick = "stick",
	apple = "fruit", spider_eye = "ball", snowball = "ball", clay_ball = "ball", potato = "lump",
	carrot = "stick", baked_potato = "lump",
	raw_porkchop = "meat", cooked_porkchop = "meat", raw_beef = "meat", steak = "meat",
	raw_chicken = "meat", cooked_chicken = "meat", raw_mutton = "meat", cooked_mutton = "meat",
	rotten_flesh = "meat",
	arrow = "arrow", feather = "feather", bone = "bone", string = "string",
	bread = "loaf", void_shard = "sphere", glow_ink_sac = "ball",
	bucket = "bucket", water_bucket = "water_bucket", lava_bucket = "lava_bucket",
	wheat_seeds = "seeds", beetroot_seeds = "seeds", bone_meal = "dust", wheat = "sheaf",
	beetroot = "fruit", bowl = "bowl", beetroot_soup = "soup", poisonous_potato = "lump",
	pumpkin_seeds = "seeds", melon_seeds = "seeds", melon_slice = "fruit", sugar = "dust", paper = "bar",
	gold_nugget = "ball", golden_apple = "fruit", enchanted_golden_apple = "fruit", golden_carrot = "stick",
	pumpkin_pie = "pie", egg = "egg", milk_bucket = "milk_bucket",
}

local function texel(tex: buffer, x: number, y: number, f: number?): { number }
	local o = ((y % N) * N + (x % N)) * 4
	local k = f or 1
	return { buffer.readu8(tex, o) * k, buffer.readu8(tex, o + 1) * k, buffer.readu8(tex, o + 2) * k }
end

-- Block items whose block isn't a cube: a flat silhouette painted with the block's texture.
local BLOCK_ICONS: { [string]: (img: buffer, tex: buffer, def: any) -> () } = {
	-- plants: the texture as it is (its see-through background stays see-through)
	plant = function(img, tex)
		for y = 0, 15 do
			for x = 0, 15 do
				local o = (y * N + x) * 4
				if buffer.readu8(tex, o + 3) > 0 then
					put(img, x, y, texel(tex, x, y))
				end
			end
		end
	end,
	slab = function(img, tex)
		for y = 8, 15 do
			for x = 0, 15 do
				put(img, x, y, texel(tex, x, y, if y == 8 then 1.15 else 1))
			end
		end
	end,
	stairs = function(img, tex)
		for y = 0, 15 do
			for x = 0, 15 do
				if y >= 8 or x < 8 then
					put(img, x, y, texel(tex, x, y, if y == 0 or (y == 8 and x >= 8) then 1.15 else 1))
				end
			end
		end
	end,
	fence = function(img, tex)
		for y = 1, 15 do
			for _, x in { 2, 3, 4, 11, 12, 13 } do
				put(img, x, y, texel(tex, x, y, if x == 2 or x == 11 then 1.1 else 1))
			end
		end
		for x = 5, 10 do
			for _, y in { 4, 5, 10, 11 } do
				put(img, x, y, texel(tex, x, y, 0.9))
			end
		end
	end,
	door = function(img, tex, def)
		local upper = TextureGen.generate(string.gsub(def.iconTexture, "_lower$", "_upper"))
		for y = 0, 15 do
			for x = 4, 11 do
				local sx = (x - 4) * 2
				local src = if y < 8 then upper else tex
				put(img, x, y, texel(src, sx, (y % 8) * 2))
			end
		end
	end,
	ladder = function(img, tex)
		for y = 0, 15 do
			for _, x in { 3, 4, 11, 12 } do
				put(img, x, y, texel(tex, x, y, if x == 3 or x == 11 then 1.1 else 0.9))
			end
			if y % 4 == 2 then
				for x = 5, 10 do
					put(img, x, y, texel(tex, x, y))
				end
			end
		end
	end,
	trapdoor = function(img, tex)
		for y = 1, 14 do
			for x = 1, 14 do
				put(img, x, y, texel(tex, x, y))
			end
		end
	end,
	fence_gate = function(img, tex)
		for y = 2, 14 do
			for _, x in { 1, 2, 13, 14 } do
				put(img, x, y, texel(tex, x, y, if x == 1 or x == 13 then 1.1 else 1))
			end
		end
		for x = 3, 12 do
			for _, y in { 4, 5, 10, 11 } do
				put(img, x, y, texel(tex, x, y, 0.9))
			end
		end
		for i = 0, 4 do
			put(img, 6 + i, 6 + i // 1, texel(tex, 6 + i, 6 + i, 0.8))
		end
	end,
	wall = function(img, tex)
		for y = 1, 15 do
			for x = 4, 11 do
				put(img, x, y, texel(tex, x, y, if x == 4 then 1.1 else 1))
			end
		end
		for y = 4, 15 do
			for _, x in { 0, 1, 2, 3, 12, 13, 14, 15 } do
				put(img, x, y, texel(tex, x, y, 0.9))
			end
		end
	end,
	pane = function(img, tex)
		for y = 0, 15 do
			for x = 6, 9 do
				put(img, x, y, texel(tex, x, y), 200)
			end
		end
		for y = 0, 15 do
			put(img, 6, y, { 210, 230, 236 })
		end
	end,
	bars = function(img, tex)
		for y = 0, 15 do
			for _, x in { 1, 5, 10, 14 } do
				put(img, x, y, texel(tex, x, y, 1.2))
			end
		end
		for x = 1, 14 do
			put(img, x, 1, texel(tex, x, 1, 1.1))
			put(img, x, 14, texel(tex, x, 14, 1.1))
		end
	end,
	vine = function(img, tex)
		for y = 0, 15 do
			for x = 0, 15 do
				if (x * 7 + y * 3) % 5 ~= 0 and math.abs(x - 7.5) + (y % 4) < 9 then
					put(img, x, y, texel(tex, x, y))
				end
			end
		end
	end,
	bed = function(img, tex)
		for y = 6, 10 do
			for x = 1, 14 do
				put(img, x, y, texel(tex, x, y, if y == 6 then 1.1 else 1))
			end
		end
		for y = 4, 6 do
			for x = 2, 5 do
				put(img, x, y, { 236, 236, 234 }) -- pillow
			end
		end
		for _, x in { 1, 2, 13, 14 } do
			put(img, x, 11, { 120, 88, 50 })
			put(img, x, 12, { 100, 72, 40 })
		end
	end,
	hanging_sign = function(img, tex)
		for y = 6, 13 do
			for x = 1, 14 do
				put(img, x, y, texel(tex, x, y, if y == 6 then 1.12 else 1))
			end
		end
		for y = 0, 5 do
			put(img, 3, y, if y % 2 == 0 then { 70, 72, 78 } else { 110, 112, 120 })
			put(img, 12, y, if y % 2 == 0 then { 70, 72, 78 } else { 110, 112, 120 })
		end
	end,
	sign = function(img, tex)
		for y = 2, 9 do
			for x = 1, 14 do
				put(img, x, y, texel(tex, x, y, if y == 2 then 1.12 else 1))
			end
		end
		for y = 10, 15 do
			put(img, 7, y, texel(tex, 7, y, 0.7))
			put(img, 8, y, texel(tex, 8, y, 0.6))
		end
		for x = 3, 12 do
			if x % 3 ~= 0 then
				put(img, x, 5, { 70, 54, 36 }) -- a hint of writing
				put(img, x, 7, { 70, 54, 36 })
			end
		end
	end,
}

-- `def` is an ItemRegistry definition (fields used: key, tool, color, icon, iconTexture).
function ItemIconGen.generate(def: any): buffer
	if def.icon and BLOCK_ICONS[def.icon] and def.iconTexture then
		local img = new()
		BLOCK_ICONS[def.icon](img, TextureGen.generate(def.iconTexture), def)
		outline(img, { 30, 26, 24 })
		return img
	end
	local sprite = ItemSprites.icon(def.key)
	if sprite then
		return sprite
	end
	-- (every item has a sprite - tested; this is only a safety net for new items)
	local img = new()
	local shape = SHAPES[SHAPE_OF[def.key] or "lump"]
	shape(img, def.color or { 200, 200, 200 }, 0)
	outline(img, { 30, 26, 24 })
	return img
end

return ItemIconGen
