--!strict
-- ROCRAFT's own 16x16 item icons for non-block items, drawn from simple shape recipes (pure,
-- deterministic). Tools: a diagonal handle with a head shape per kind in the tier colour.
-- Materials and food: a shape per item family (bar, lump, gem, dust, stick, round fruit, meat...).
-- Output: 16 x 16 RGBA buffer, transparent background. Blocks use their face texture instead.

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

local SHAPES: { [string]: (buffer, { number }, number) -> () } = {
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
	bread = "loaf", void_shard = "sphere",
}

-- `def` is an ItemRegistry definition (fields used: key, tool, color).
function ItemIconGen.generate(def: any): buffer
	local img = new()
	local color = def.color or { 200, 200, 200 }
	local tool = def.tool
	local seed = 0
	for i = 1, #def.key do
		seed += string.byte(def.key, i) * i
	end
	if tool and tools[tool.kind] then
		tools[tool.kind](img, color)
	elseif tool and tool.kind == "shears" then
		for i = 0, 5 do
			put(img, 4 + i, 4 + i, { 200, 200, 206 })
			put(img, 11 - i, 4 + i, { 170, 170, 176 })
		end
		put(img, 3, 12, { 160, 40, 40 })
		put(img, 12, 12, { 160, 40, 40 })
	else
		local shape = SHAPES[SHAPE_OF[def.key] or "lump"]
		shape(img, color, seed)
	end
	outline(img, { 30, 26, 24 })
	return img
end

return ItemIconGen
