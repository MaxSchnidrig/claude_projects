--!strict
--!native
-- ROCRAFT's own 16x16 block art, generated from code (pure, deterministic, tested headless).
--
-- Every texture is drawn by a small recipe of our own (noise, cells, bands, rings, blobs) from
-- ROCRAFT's palette, so blocks read as the familiar materials (stone, grass, logs, ores...) in a
-- blocky pixel style without copying any other game's pixel art. A texture is a buffer of
-- 16 x 16 RGBA bytes (row-major, y = 0 at the top).
--
-- Also: 10 mining crack stages (transparent overlays) for the crack overlay and the atlas.

local Hash = require(script.Parent.Parent.Util.Hash)

local TextureGen = {}
TextureGen.SIZE = 16
TextureGen.CRACK_STAGES = 10

type RGB = { number }
type Img = buffer

local N = 16

local function new(): Img
	return buffer.create(N * N * 4)
end

local function put(img: Img, x: number, y: number, c: RGB, a: number?)
	if x < 0 or y < 0 or x >= N or y >= N then
		return
	end
	local o = (y * N + x) * 4
	buffer.writeu8(img, o, math.clamp(math.floor(c[1] + 0.5), 0, 255))
	buffer.writeu8(img, o + 1, math.clamp(math.floor(c[2] + 0.5), 0, 255))
	buffer.writeu8(img, o + 2, math.clamp(math.floor(c[3] + 0.5), 0, 255))
	buffer.writeu8(img, o + 3, a or 255)
end

local function get(img: Img, x: number, y: number): RGB
	local o = (((y % N) * N) + (x % N)) * 4
	return { buffer.readu8(img, o), buffer.readu8(img, o + 1), buffer.readu8(img, o + 2) }
end

local function shade(c: RGB, f: number): RGB
	return { c[1] * f, c[2] * f, c[3] * f }
end

local function mix(a: RGB, b: RGB, t: number): RGB
	return { a[1] + (b[1] - a[1]) * t, a[2] + (b[2] - a[2]) * t, a[3] + (b[3] - a[3]) * t }
end

-- Per-texture deterministic randomness.
local function seedOf(name: string): number
	local h = 2166136261
	for i = 1, #name do
		h = bit32.bxor(h, string.byte(name, i))
		h = (h * 16777619) % 4294967296
	end
	return h
end

local function rnd(seed: number, x: number, y: number, k: number?): number
	return Hash.hash3f(seed, x, y, k or 0)
end

-- Tileable value noise on the 16x16 torus (cell = 16 / period).
local function tileNoise(seed: number, x: number, y: number, period: number): number
	local cell = N / period
	local fx, fy = x / cell, y / cell
	local x0, y0 = math.floor(fx), math.floor(fy)
	local tx, ty = fx - x0, fy - y0
	tx = tx * tx * (3 - 2 * tx)
	ty = ty * ty * (3 - 2 * ty)
	local function v(ix: number, iy: number): number
		return rnd(seed, ix % period, iy % period, 7)
	end
	local a = v(x0, y0) + (v(x0 + 1, y0) - v(x0, y0)) * tx
	local b = v(x0, y0 + 1) + (v(x0 + 1, y0 + 1) - v(x0, y0 + 1)) * tx
	return a + (b - a) * ty
end

-- Base fill: colour with per-pixel brightness jitter and soft blotches.
local function noisy(seed: number, base: RGB, jitter: number, blotch: number): Img
	local img = new()
	for y = 0, N - 1 do
		for x = 0, N - 1 do
			local f = 1 + (rnd(seed, x, y) - 0.5) * jitter + (tileNoise(seed, x, y, 4) - 0.5) * blotch
			put(img, x, y, shade(base, f))
		end
	end
	return img
end

-- Tileable Voronoi cells: returns (cell id, distance to nearest, distance to second nearest).
local function voronoi(seed: number, count: number, x: number, y: number): (number, number, number)
	local best, second, id = math.huge, math.huge, 0
	for i = 1, count do
		local px = rnd(seed, i, 0, 3) * N
		local py = rnd(seed, i, 1, 3) * N
		for oy = -1, 1 do
			for ox = -1, 1 do
				local dx, dy = x + 0.5 - (px + ox * N), y + 0.5 - (py + oy * N)
				local d = math.sqrt(dx * dx + dy * dy)
				if d < best then
					second = best
					best, id = d, i
				elseif d < second then
					second = d
				end
			end
		end
	end
	return id, best, second
end

local function blobs(img: Img, seed: number, count: number, color: RGB, light: RGB, minR: number, maxR: number)
	for i = 1, count do
		local cx = 2 + math.floor(rnd(seed, i, 10) * 12)
		local cy = 2 + math.floor(rnd(seed, i, 11) * 12)
		local r = minR + rnd(seed, i, 12) * (maxR - minR)
		for y = cy - 3, cy + 3 do
			for x = cx - 3, cx + 3 do
				local dx, dy = x - cx, y - cy
				local d = math.sqrt(dx * dx + dy * dy) + (rnd(seed, x, y, i + 20) - 0.5) * 0.9
				if d <= r then
					local c = if d < r * 0.45 and rnd(seed, x, y, i + 40) > 0.4 then light else color
					put(img, x, y, shade(c, 0.9 + rnd(seed, x, y, i + 60) * 0.2))
				end
			end
		end
	end
end

-- Palette ------------------------------------------------------------------------------------

local P = {
	stone = { 122, 122, 124 },
	dirt = { 128, 90, 62 },
	grass = { 92, 156, 58 },
	sand = { 222, 210, 164 },
	sandstone = { 214, 198, 146 },
	gravel = { 132, 124, 122 },
	snow = { 242, 248, 252 },
	ice = { 148, 188, 246 },
	clay = { 158, 164, 178 },
	water = { 46, 92, 204 },
	lava = { 236, 106, 22 },
	oakBark = { 104, 80, 48 },
	oakWood = { 170, 136, 84 },
	birchBark = { 220, 218, 210 },
	birchWood = { 196, 178, 122 },
	spruceBark = { 64, 44, 26 },
	spruceWood = { 118, 88, 54 },
	oakLeaves = { 60, 126, 40 },
	birchLeaves = { 104, 150, 62 },
	spruceLeaves = { 50, 90, 58 },
}

-- Recipes ------------------------------------------------------------------------------------

local recipes: { [string]: (seed: number) -> Img } = {}

recipes.stone = function(seed)
	local img = noisy(seed, P.stone, 0.14, 0.22)
	-- a few short darker strokes, mostly horizontal
	for i = 1, 6 do
		local x, y = math.floor(rnd(seed, i, 1, 9) * N), math.floor(rnd(seed, i, 2, 9) * N)
		local len = 2 + math.floor(rnd(seed, i, 3, 9) * 3)
		for k = 0, len - 1 do
			put(img, (x + k) % N, (y + (if rnd(seed, i, k, 8) > 0.75 then 1 else 0)) % N, shade(P.stone, 0.78))
		end
	end
	return img
end

recipes.dirt = function(seed)
	local img = noisy(seed, P.dirt, 0.2, 0.25)
	for i = 1, 14 do
		local x, y = math.floor(rnd(seed, i, 4) * N), math.floor(rnd(seed, i, 5) * N)
		put(img, x, y, shade(P.dirt, if rnd(seed, i, 6) > 0.5 then 1.25 else 0.7))
	end
	return img
end

recipes.grass_top = function(seed)
	local img = noisy(seed, P.grass, 0.24, 0.2)
	for i = 1, 20 do
		local x, y = math.floor(rnd(seed, i, 4) * N), math.floor(rnd(seed, i, 5) * N)
		put(img, x, y, shade(P.grass, 1.2))
		put(img, x, (y + 1) % N, shade(P.grass, 0.85))
	end
	return img
end

local function sideWithCap(seed: number, cap: RGB, capJitter: number): Img
	local img = recipes.dirt(seed + 1)
	for x = 0, N - 1 do
		local depth = 3 + math.floor(rnd(seed, x, 0, 30) * 2.2)
		if rnd(seed, x, 1, 30) > 0.8 then
			depth += 1
		end
		for y = 0, depth - 1 do
			local f = 1 + (rnd(seed, x, y, 31) - 0.5) * capJitter - (if y == depth - 1 then 0.12 else 0)
			put(img, x, y, shade(cap, f))
		end
	end
	return img
end

recipes.grass_side = function(seed)
	return sideWithCap(seed, P.grass, 0.25)
end

recipes.snowy_grass_side = function(seed)
	return sideWithCap(seed, P.snow, 0.06)
end

recipes.cobblestone = function(seed)
	local img = new()
	for y = 0, N - 1 do
		for x = 0, N - 1 do
			local id, d1, d2 = voronoi(seed, 9, x, y)
			local edge = d2 - d1 < 1.1
			local tone = 0.82 + rnd(seed, id, 0, 5) * 0.3
			local f = if edge then 0.55 else tone + (rnd(seed, x, y) - 0.5) * 0.1 - d1 * 0.015
			put(img, x, y, shade(P.stone, f))
		end
	end
	return img
end

recipes.bedrock = function(seed)
	local img = new()
	for y = 0, N - 1 do
		for x = 0, N - 1 do
			local n = tileNoise(seed, x, y, 8) * 0.6 + rnd(seed, x, y) * 0.4
			local c = if n > 0.62 then { 128, 128, 130 } elseif n > 0.4 then { 74, 74, 78 } else { 34, 34, 38 }
			put(img, x, y, c)
		end
	end
	return img
end

recipes.sand = function(seed)
	local img = noisy(seed, P.sand, 0.1, 0.08)
	for i = 1, 18 do
		put(img, math.floor(rnd(seed, i, 4) * N), math.floor(rnd(seed, i, 5) * N), shade(P.sand, 0.86))
	end
	return img
end

recipes.gravel = function(seed)
	local img = new()
	local tones = { { 150, 142, 140 }, { 112, 104, 104 }, { 168, 160, 150 }, { 96, 92, 96 } }
	for y = 0, N - 1 do
		for x = 0, N - 1 do
			local id, d1, d2 = voronoi(seed, 14, x, y)
			local c = tones[1 + id % #tones]
			put(img, x, y, shade(c, if d2 - d1 < 0.8 then 0.7 else 1 - d1 * 0.03))
		end
	end
	return img
end

recipes.sandstone_top = function(seed)
	return noisy(seed, P.sandstone, 0.08, 0.12)
end

recipes.sandstone_side = function(seed)
	local img = noisy(seed, P.sandstone, 0.08, 0.06)
	for x = 0, N - 1 do
		for _, y in { 3, 4, 10 } do
			put(img, x, y, shade(P.sandstone, if y == 4 then 0.86 else 0.92))
		end
		put(img, x, 15, shade(P.sandstone, 0.8))
	end
	return img
end

recipes.water = function(seed)
	local img = noisy(seed, P.water, 0.06, 0.15)
	for y = 2, N - 1, 5 do
		for x = 0, N - 1 do
			if math.sin((x + y * 1.7 + rnd(seed, y, 0) * 3) * 0.8) > 0.6 then
				put(img, x, y, shade(P.water, 1.3))
			end
		end
	end
	return img
end

recipes.lava = function(seed)
	local img = new()
	for y = 0, N - 1 do
		for x = 0, N - 1 do
			local n = tileNoise(seed, x, y, 4)
			local c = if n > 0.65 then { 255, 196, 60 } elseif n > 0.35 then P.lava else { 176, 52, 12 }
			put(img, x, y, shade(c, 0.94 + rnd(seed, x, y) * 0.12))
		end
	end
	return img
end

recipes.snow = function(seed)
	return noisy(seed, P.snow, 0.04, 0.05)
end

recipes.ice = function(seed)
	local img = noisy(seed, P.ice, 0.05, 0.12)
	for i = 0, 3 do
		for k = 0, 5 do
			local x = (i * 4 + k) % N
			local y = (k * 2 + i * 3) % N
			put(img, x, y, mix(P.ice, { 255, 255, 255 }, 0.55))
		end
	end
	return img
end

recipes.clay = function(seed)
	return noisy(seed, P.clay, 0.06, 0.12)
end

local function logSide(seed: number, bark: RGB, birch: boolean): Img
	local img = new()
	for x = 0, N - 1 do
		local col = 0.85 + rnd(seed, x, 0, 50) * 0.3
		for y = 0, N - 1 do
			local f = col + (rnd(seed, x, y) - 0.5) * 0.12
			if not birch and rnd(seed, x, y, 51) > 0.85 then
				f *= 0.75 -- bark cracks
			end
			put(img, x, y, shade(bark, f))
		end
	end
	if birch then
		-- dark horizontal marks on the pale bark
		for i = 1, 7 do
			local x, y = math.floor(rnd(seed, i, 1, 52) * N), math.floor(rnd(seed, i, 2, 52) * N)
			local len = 2 + math.floor(rnd(seed, i, 3, 52) * 4)
			for k = 0, len - 1 do
				put(img, (x + k) % N, y, { 44, 44, 40 })
			end
		end
	end
	return img
end

local function logTop(seed: number, bark: RGB, wood: RGB): Img
	local img = new()
	for y = 0, N - 1 do
		for x = 0, N - 1 do
			local d = math.max(math.abs(x - 7.5), math.abs(y - 7.5))
			local c
			if d > 6.6 then
				c = shade(bark, 0.95 + rnd(seed, x, y) * 0.1)
			else
				local ring = math.floor(d + rnd(seed, x, y, 53) * 0.5) % 2
				c = shade(wood, (if ring == 0 then 1.0 else 0.86) + (rnd(seed, x, y) - 0.5) * 0.06)
			end
			put(img, x, y, c)
		end
	end
	return img
end

recipes.oak_log = function(seed)
	return logSide(seed, P.oakBark, false)
end
recipes.oak_log_top = function(seed)
	return logTop(seed, P.oakBark, P.oakWood)
end
recipes.birch_log = function(seed)
	return logSide(seed, P.birchBark, true)
end
recipes.birch_log_top = function(seed)
	return logTop(seed, P.birchBark, P.birchWood)
end
recipes.spruce_log = function(seed)
	return logSide(seed, P.spruceBark, false)
end
recipes.spruce_log_top = function(seed)
	return logTop(seed, P.spruceBark, P.spruceWood)
end

local function leaves(seed: number, base: RGB): Img
	local img = new()
	for y = 0, N - 1 do
		for x = 0, N - 1 do
			local n = rnd(seed, x, y) * 0.6 + tileNoise(seed, x, y, 8) * 0.4
			local f = if n > 0.72 then 1.28 elseif n < 0.22 then 0.58 else 0.9 + n * 0.2
			put(img, x, y, shade(base, f))
		end
	end
	return img
end

recipes.oak_leaves = function(seed)
	return leaves(seed, P.oakLeaves)
end
recipes.birch_leaves = function(seed)
	return leaves(seed, P.birchLeaves)
end
recipes.spruce_leaves = function(seed)
	return leaves(seed, P.spruceLeaves)
end

local function planks(seed: number, wood: RGB): Img
	local img = new()
	for y = 0, N - 1 do
		local board = y // 4
		local seam = y % 4 == 3
		local cut = math.floor(rnd(seed, board, 0, 70) * N)
		for x = 0, N - 1 do
			local f = 0.95 + rnd(seed, board, 1, 70) * 0.1 + (rnd(seed, x, y) - 0.5) * 0.08
			if seam then
				f = 0.62
			elseif x == cut then
				f = 0.72 -- board ends
			elseif rnd(seed, x // 3, y, 71) > 0.82 then
				f *= 0.9 -- grain
			end
			put(img, x, y, shade(wood, f))
		end
	end
	return img
end

recipes.oak_planks = function(seed)
	return planks(seed, P.oakWood)
end
recipes.birch_planks = function(seed)
	return planks(seed, P.birchWood)
end
recipes.spruce_planks = function(seed)
	return planks(seed, P.spruceWood)
end

local function ore(seed: number, color: RGB, light: RGB, count: number): Img
	local img = recipes.stone(seedOf("stone"))
	blobs(img, seed, count, color, light, 1.1, 1.9)
	return img
end

recipes.coal_ore = function(seed)
	return ore(seed, { 40, 40, 44 }, { 70, 70, 74 }, 5)
end
recipes.iron_ore = function(seed)
	return ore(seed, { 196, 156, 128 }, { 230, 200, 178 }, 4)
end
recipes.copper_ore = function(seed)
	return ore(seed, { 192, 108, 66 }, { 96, 170, 140 }, 5)
end
recipes.gold_ore = function(seed)
	return ore(seed, { 236, 196, 52 }, { 255, 240, 140 }, 4)
end
recipes.diamond_ore = function(seed)
	return ore(seed, { 80, 214, 214 }, { 220, 255, 255 }, 4)
end
recipes.emerald_ore = function(seed)
	return ore(seed, { 40, 180, 84 }, { 160, 250, 180 }, 3)
end
recipes.lapis_ore = function(seed)
	return ore(seed, { 36, 64, 180 }, { 90, 120, 230 }, 5)
end
recipes.volt_ore = function(seed)
	return ore(seed, { 140, 52, 210 }, { 220, 150, 255 }, 6)
end

recipes.glass = function(seed)
	local img = new()
	for y = 0, N - 1 do
		for x = 0, N - 1 do
			local edge = x == 0 or y == 0 or x == N - 1 or y == N - 1
			local glint = (x - y == 3 or x - y == 4) and x > 3 and x < 10
			put(img, x, y, if edge then { 210, 236, 244 } elseif glint then { 250, 255, 255 } else { 200, 228, 238 },
				if edge then 255 elseif glint then 200 else 40)
		end
	end
	return img
end

recipes.obsidian = function(seed)
	local img = noisy(seed, { 26, 16, 40 }, 0.3, 0.4)
	for i = 1, 6 do
		put(img, math.floor(rnd(seed, i, 4) * N), math.floor(rnd(seed, i, 5) * N), { 110, 76, 170 })
	end
	return img
end

recipes.crafting_table_top = function(seed)
	local img = planks(seed, P.oakWood)
	for i = 0, N - 1 do
		for _, k in { 0, 15 } do
			put(img, i, k, shade(P.oakBark, 0.9))
			put(img, k, i, shade(P.oakBark, 0.9))
		end
		put(img, i, 7, shade(P.oakBark, 1.05))
		put(img, 7, i, shade(P.oakBark, 1.05))
	end
	return img
end

recipes.crafting_table_side = function(seed)
	local img = planks(seed, P.oakWood)
	for x = 0, N - 1 do
		put(img, x, 0, shade(P.oakBark, 0.9))
		put(img, x, 1, shade(P.oakBark, 1.1))
	end
	-- a saw and a mallet hanging on the side (our own little pictograms)
	for y = 4, 11 do
		put(img, 4, y, { 190, 190, 196 })
		put(img, 5, y, if y % 2 == 0 then { 150, 150, 156 } else { 190, 190, 196 })
	end
	put(img, 4, 3, { 90, 60, 30 })
	put(img, 5, 3, { 90, 60, 30 })
	for y = 6, 12 do
		put(img, 11, y, { 120, 84, 44 })
	end
	for x = 9, 13 do
		put(img, x, 5, { 80, 80, 86 })
		put(img, x, 6, { 80, 80, 86 })
	end
	return img
end

recipes.furnace_top = function(seed)
	return noisy(seed, { 116, 116, 118 }, 0.08, 0.1)
end

recipes.furnace_side = function(seed)
	local img = recipes.cobblestone(seed)
	for y = 8, 13 do
		for x = 4, 11 do
			local inner = y > 8 and x > 4 and x < 11
			put(img, x, y, if inner then { 24, 22, 22 } else { 70, 70, 72 })
		end
	end
	for x = 5, 10 do
		put(img, x, 13, { 50, 46, 44 })
	end
	return img
end

recipes.chest = function(seed)
	local img = planks(seed, { 160, 112, 44 })
	for x = 0, N - 1 do
		put(img, x, 5, { 60, 40, 20 })
		put(img, x, 6, { 60, 40, 20 })
		put(img, x, 0, { 92, 62, 28 })
		put(img, x, 15, { 92, 62, 28 })
	end
	for y = 4, 8 do
		put(img, 7, y, { 200, 200, 206 })
		put(img, 8, y, { 170, 170, 176 })
	end
	return img
end

recipes.tnt_side = function(seed)
	local img = new()
	for y = 0, N - 1 do
		for x = 0, N - 1 do
			-- vertical sticks with dark seams
			local f = (if x % 4 == 0 then 0.7 else 1) * (0.94 + rnd(seed, x, y) * 0.12)
			put(img, x, y, shade({ 196, 58, 46 }, f))
		end
	end
	-- a pale paper band with a row of dark dots (no lettering)
	for y = 6, 9 do
		for x = 0, N - 1 do
			put(img, x, y, if (y == 7 or y == 8) and x % 3 == 1 then { 50, 44, 40 } else { 232, 228, 214 })
		end
	end
	return img
end

recipes.tnt_top = function(seed)
	local img = new()
	for y = 0, N - 1 do
		for x = 0, N - 1 do
			local cx, cy = x % 4 - 1.5, y % 4 - 1.5
			local ring = math.sqrt(cx * cx + cy * cy) < 1.4
			put(img, x, y, if ring then { 210, 70, 56 } else { 120, 40, 32 })
		end
	end
	put(img, 7, 7, { 40, 40, 40 })
	put(img, 8, 8, { 40, 40, 40 })
	return img
end

recipes.white_wool = function(seed)
	local img = new()
	for y = 0, N - 1 do
		for x = 0, N - 1 do
			local weave = ((x + y) % 4 == 0) or ((x - y) % 4 == 0)
			put(img, x, y, shade({ 236, 236, 234 }, (if weave then 0.92 else 1) + (rnd(seed, x, y) - 0.5) * 0.06))
		end
	end
	return img
end

recipes.torch = function(seed)
	local img = new()
	for y = 0, N - 1 do
		for x = 0, N - 1 do
			put(img, x, y, { 0, 0, 0 }, 0)
		end
	end
	for y = 6, 15 do
		put(img, 7, y, { 120, 84, 46 })
		put(img, 8, y, { 96, 66, 36 })
	end
	for y = 3, 5 do
		put(img, 7, y, { 255, 214, 90 })
		put(img, 8, y, { 255, 170, 50 })
	end
	put(img, 7, 2, { 255, 240, 170 })
	return img
end

recipes.fire = function(seed)
	-- tongues of flame rising from the bottom, hotter (yellow) at the base; transparent elsewhere
	local img = new()
	for x = 0, N - 1 do
		local top = 3 + math.floor(rnd(seed, x, 0, 80) * 7 + math.sin(x * 1.3) * 2)
		for y = 0, N - 1 do
			if y >= top then
				local t = (y - top) / math.max(1, N - top)
				local c = if t > 0.7 then { 255, 236, 120 } elseif t > 0.35 then { 255, 160, 40 } else { 220, 72, 24 }
				put(img, x, y, shade(c, 0.9 + rnd(seed, x, y) * 0.2), if y == top then 160 else 255)
			else
				put(img, x, y, { 0, 0, 0 }, 0)
			end
		end
	end
	return img
end

recipes.campfire_log = function(seed)
	-- a log seen from the side with a charred band in the middle
	local img = logSide(seed, P.oakBark, false)
	for x = 0, N - 1 do
		for y = 6, 9 do
			put(img, x, y, shade({ 40, 30, 24 }, 0.8 + rnd(seed, x, y) * 0.3))
		end
	end
	return img
end

recipes.campfire_top = function(seed)
	-- crossed logs seen from above over glowing embers
	local img = new()
	for y = 0, N - 1 do
		for x = 0, N - 1 do
			local log = (x >= 2 and x <= 5) or (x >= 10 and x <= 13) or (y >= 2 and y <= 5) or (y >= 10 and y <= 13)
			local c = if log then shade(P.oakBark, 0.85 + rnd(seed, x, y) * 0.3)
				else shade({ 220, 90, 30 }, 0.7 + rnd(seed, x, y, 3) * 0.5)
			put(img, x, y, c)
		end
	end
	return img
end

-- Doors (our own designs): a framed wooden door of vertical boards with a diagonal brace on the
-- lower half and a four-pane window on the upper half; the iron door is riveted plate.
local function woodDoor(seed: number, wood: RGB, upper: boolean): Img
	local img = new()
	local frame = shade(wood, 0.7)
	for y = 0, N - 1 do
		for x = 0, N - 1 do
			local edge = x <= 1 or x >= N - 2 or (upper and y <= 1) or (not upper and y >= N - 2)
			local c
			if edge then
				c = shade(frame, 0.92 + rnd(seed, x, y) * 0.12)
			else
				-- vertical boards, 3 px wide with dark seams
				local seam = (x - 2) % 4 == 3
				c = shade(wood, (if seam then 0.72 else 0.95) + (rnd(seed, x, y) - 0.5) * 0.1)
			end
			put(img, x, y, c)
		end
	end
	if upper then
		-- window: 2 x 2 panes of pale glass in a cross-shaped frame
		for y = 3, 10 do
			for x = 3, 12 do
				local bar = x == 7 or x == 8 or y == 6 or y == 7
				if not bar then
					put(img, x, y, shade({ 168, 196, 206 }, 0.9 + rnd(seed, x, y, 4) * 0.15))
				else
					put(img, x, y, frame)
				end
			end
		end
	else
		-- diagonal brace and a dark handle
		for i = 0, 10 do
			local x, y = 3 + i, 12 - i
			if y >= 2 then
				put(img, x, y, shade(frame, 1.05))
				put(img, x, y + 1, shade(frame, 0.9))
			end
		end
		put(img, 12, 1, { 52, 48, 46 })
		put(img, 12, 2, { 40, 36, 34 })
	end
	return img
end

local function ironDoor(seed: number, upper: boolean): Img
	local img = new()
	local metal = { 200, 200, 206 }
	for y = 0, N - 1 do
		for x = 0, N - 1 do
			local edge = x == 0 or x == N - 1 or (upper and y == 0) or (not upper and y == N - 1)
			local panel = (y % 8 == 0)
			local f = if edge then 0.7 elseif panel then 0.82 else 0.95 + (rnd(seed, x, y) - 0.5) * 0.08
			put(img, x, y, shade(metal, f))
		end
	end
	for _, r in { { 2, 2 }, { 13, 2 }, { 2, 13 }, { 13, 13 }, { 2, 7 }, { 13, 7 } } do
		put(img, r[1], r[2], { 120, 120, 128 })
	end
	if upper then
		for y = 3, 5 do
			for x = 4, 11 do
				put(img, x, y, { 60, 62, 70 }) -- a narrow viewing slot
			end
		end
	else
		put(img, 12, 2, { 90, 90, 96 })
	end
	return img
end

recipes.oak_door_lower = function(seed) return woodDoor(seed, P.oakWood, false) end
recipes.oak_door_upper = function(seed) return woodDoor(seed, P.oakWood, true) end
recipes.spruce_door_lower = function(seed) return woodDoor(seed, P.spruceWood, false) end
recipes.spruce_door_upper = function(seed) return woodDoor(seed, P.spruceWood, true) end
recipes.birch_door_lower = function(seed) return woodDoor(seed, P.birchWood, false) end
recipes.birch_door_upper = function(seed) return woodDoor(seed, P.birchWood, true) end
recipes.iron_door_lower = function(seed) return ironDoor(seed, false) end
recipes.iron_door_upper = function(seed) return ironDoor(seed, true) end

-- Trapdoors (our own designs): a framed hatch of boards with two dark slots and an iron hinge
-- strip; the iron one is a riveted plate with a grille of slots.
local function woodTrapdoor(seed: number, wood: RGB): Img
	local img = new()
	local frame = shade(wood, 0.72)
	for y = 0, N - 1 do
		for x = 0, N - 1 do
			local edge = x <= 1 or x >= N - 2 or y <= 1 or y >= N - 2
			local c
			if edge then
				c = shade(frame, 0.92 + rnd(seed, x, y) * 0.12)
			elseif (y == 5 or y == 10) and x >= 4 and x <= 11 then
				c = { 40, 30, 22 } -- slots
			else
				local seam = (x - 2) % 4 == 3
				c = shade(wood, (if seam then 0.74 else 0.96) + (rnd(seed, x, y) - 0.5) * 0.1)
			end
			put(img, x, y, c)
		end
	end
	for x = 2, 13 do
		put(img, x, 2, { 92, 90, 92 }) -- hinge strip
	end
	return img
end
recipes.oak_trapdoor = function(seed) return woodTrapdoor(seed, P.oakWood) end
recipes.spruce_trapdoor = function(seed) return woodTrapdoor(seed, P.spruceWood) end
recipes.birch_trapdoor = function(seed) return woodTrapdoor(seed, P.birchWood) end
recipes.iron_trapdoor = function(seed)
	local img = new()
	for y = 0, N - 1 do
		for x = 0, N - 1 do
			local edge = x == 0 or y == 0 or x == N - 1 or y == N - 1
			local slot = x >= 3 and x <= 12 and y >= 3 and y <= 12 and (x % 3 == 0)
			local f = if edge then 0.7 elseif slot then 0.45 else 0.95 + (rnd(seed, x, y) - 0.5) * 0.08
			put(img, x, y, shade({ 200, 200, 206 }, f))
		end
	end
	for _, r in { { 1, 1 }, { 14, 1 }, { 1, 14 }, { 14, 14 } } do
		put(img, r[1], r[2], { 120, 120, 128 })
	end
	return img
end

-- Iron bars: the rods are real geometry; this is their dark, slightly mottled metal.
recipes.iron_bars = function(seed)
	local img = new()
	for y = 0, N - 1 do
		for x = 0, N - 1 do
			put(img, x, y, shade({ 118, 120, 126 }, 0.9 + rnd(seed, x, y) * 0.2))
		end
	end
	return img
end

-- Vines: a mat of small leaves over darker stems (drawn as a thin opaque sheet).
recipes.vine = function(seed)
	local img = new()
	for y = 0, N - 1 do
		for x = 0, N - 1 do
			local stem = (x + y // 3) % 5 == 0
			local leaf = rnd(seed, x // 2, y // 2, 9) > 0.35
			local c = if stem then { 46, 70, 26 } elseif leaf then shade({ 64, 124, 40 }, 0.85 + rnd(seed, x, y) * 0.3)
				else { 30, 58, 22 }
			put(img, x, y, c)
		end
	end
	return img
end

-- Ladder: the rails and rungs are real geometry; this is their wood, with a lengthwise grain.
recipes.ladder = function(seed)
	local img = new()
	for y = 0, N - 1 do
		for x = 0, N - 1 do
			local f = 0.92 + (rnd(seed, x, y // 3) - 0.5) * 0.16
			put(img, x, y, shade({ 156, 120, 70 }, f))
		end
	end
	return img
end

-- Public -------------------------------------------------------------------------------------

-- Fallback for texture keys without a recipe: noisy fill of the average colour.
-- Fluid level keys ("water_3", "lava_falling") share their fluid's art.
local function baseKey(key: string): string
	return string.match(key, "^(%a+)_%d$") or string.match(key, "^(%a+)_falling$") or key
end
TextureGen.baseKey = baseKey

function TextureGen.generate(key: string, fallback: RGB?): Img
	key = baseKey(key)
	local recipe = recipes[key]
	local seed = seedOf(key)
	if recipe then
		return recipe(seed)
	end
	return noisy(seed, fallback or { 255, 0, 255 }, 0.1, 0.1)
end

function TextureGen.hasRecipe(key: string): boolean
	return recipes[baseKey(key)] ~= nil
end

-- Mining crack overlay, stage 0..9: dark lines growing from the middle; transparent elsewhere.
function TextureGen.crack(stage: number): Img
	local img = new()
	local seed = seedOf("crack")
	local steps = 4 + stage * 5
	for branch = 1, 4 do
		local x, y = 7.5, 7.5
		local ang = (branch - 1) * math.pi / 2 + rnd(seed, branch, 0) * 0.8
		for i = 1, steps // 2 do
			ang += (rnd(seed, branch, i) - 0.5) * 1.3
			x = math.clamp(x + math.cos(ang), 0, 15)
			y = math.clamp(y + math.sin(ang), 0, 15)
			put(img, math.floor(x), math.floor(y), { 20, 20, 20 }, 200)
			if i > 3 and rnd(seed, branch, i, 2) > 0.7 then
				put(img, math.floor(x) + 1, math.floor(y), { 40, 40, 40 }, 140)
			end
		end
	end
	return img
end

-- Average colour of a texture (opaque pixels).
function TextureGen.average(img: Img): RGB
	local r, g, b, n = 0, 0, 0, 0
	for i = 0, N * N - 1 do
		if buffer.readu8(img, i * 4 + 3) > 128 then
			r += buffer.readu8(img, i * 4)
			g += buffer.readu8(img, i * 4 + 1)
			b += buffer.readu8(img, i * 4 + 2)
			n += 1
		end
	end
	if n == 0 then
		return { 0, 0, 0 }
	end
	return { r / n, g / n, b / n }
end

TextureGen.get = get

return TextureGen
