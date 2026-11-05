--!strict
--!native
-- Seeded gradient noise (Ken Perlin's "improved noise") in 2D and 3D, plus fBm helpers.
--
-- We don't use math.noise because it can't be seeded (only offset) and we want identical
-- results in headless tests. Only +, -, * and floor are used, so results are bit-identical
-- across platforms.

local Hash = require(script.Parent.Parent.Util.Hash)

local Noise = {}
Noise.__index = Noise

export type Noise = {
	perm: { number },
	noise2: (self: Noise, x: number, y: number) -> number,
	noise3: (self: Noise, x: number, y: number, z: number) -> number,
	fbm2: (self: Noise, x: number, y: number, octaves: number, lacunarity: number?, gain: number?) -> number,
	ridged2: (self: Noise, x: number, y: number, octaves: number) -> number,
}

local floor = math.floor

local function fade(t: number): number
	return t * t * t * (t * (t * 6 - 15) + 10)
end

local function lerp(t: number, a: number, b: number): number
	return a + t * (b - a)
end

-- 3D gradient: one of 12 cube-edge directions selected by the low 4 bits.
local function grad3(h: number, x: number, y: number, z: number): number
	h = h % 16
	local u = if h < 8 then x else y
	local v = if h < 4 then y elseif h == 12 or h == 14 then x else z
	return (if h % 2 == 0 then u else -u) + (if (h // 2) % 2 == 0 then v else -v)
end

-- 2D gradient: 8 directions.
local function grad2(h: number, x: number, y: number): number
	h = h % 8
	if h == 0 then
		return x + y
	elseif h == 1 then
		return -x + y
	elseif h == 2 then
		return x - y
	elseif h == 3 then
		return -x - y
	elseif h == 4 then
		return x
	elseif h == 5 then
		return -x
	elseif h == 6 then
		return y
	else
		return -y
	end
end

-- Build a noise generator. `seed` is any integer; `salt` lets one world seed drive many
-- independent noise fields (height, temperature, caves, ...).
function Noise.new(seed: number, salt: number): Noise
	local rng = Hash.newRng(Hash.hash3(seed, salt, 0x51ED, 0))
	local p = table.create(256, 0)
	for i = 1, 256 do
		p[i] = i - 1
	end
	-- Fisher-Yates shuffle
	for i = 256, 2, -1 do
		local j = rng:nextInt(1, i)
		p[i], p[j] = p[j], p[i]
	end
	local perm = table.create(512, 0)
	for i = 1, 512 do
		perm[i] = p[((i - 1) % 256) + 1]
	end
	return (setmetatable({ perm = perm }, Noise) :: any) :: Noise
end

-- Returns roughly [-1, 1].
function Noise.noise3(self: Noise, x: number, y: number, z: number): number
	local perm = self.perm
	local fx, fy, fz = floor(x), floor(y), floor(z)
	local X, Y, Z = fx % 256, fy % 256, fz % 256
	x -= fx
	y -= fy
	z -= fz
	local u, v, w = fade(x), fade(y), fade(z)
	-- perm is 1-based: perm[i + 1] == P[i]
	local A = perm[X + 1] + Y
	local AA = perm[A + 1] + Z
	local AB = perm[A + 2] + Z
	local B = perm[X + 2] + Y
	local BA = perm[B + 1] + Z
	local BB = perm[B + 2] + Z
	return lerp(
		w,
		lerp(
			v,
			lerp(u, grad3(perm[AA + 1], x, y, z), grad3(perm[BA + 1], x - 1, y, z)),
			lerp(u, grad3(perm[AB + 1], x, y - 1, z), grad3(perm[BB + 1], x - 1, y - 1, z))
		),
		lerp(
			v,
			lerp(u, grad3(perm[AA + 2], x, y, z - 1), grad3(perm[BA + 2], x - 1, y, z - 1)),
			lerp(u, grad3(perm[AB + 2], x, y - 1, z - 1), grad3(perm[BB + 2], x - 1, y - 1, z - 1))
		)
	)
end

-- Returns roughly [-1, 1].
function Noise.noise2(self: Noise, x: number, y: number): number
	local perm = self.perm
	local fx, fy = floor(x), floor(y)
	local X, Y = fx % 256, fy % 256
	x -= fx
	y -= fy
	local u, v = fade(x), fade(y)
	local A = perm[X + 1] + Y
	local B = perm[X + 2] + Y
	return lerp(
		v,
		lerp(u, grad2(perm[A + 1], x, y), grad2(perm[B + 1], x - 1, y)),
		lerp(u, grad2(perm[A + 2], x, y - 1), grad2(perm[B + 2], x - 1, y - 1))
	)
end

-- Fractal Brownian motion, normalised to roughly [-1, 1].
function Noise.fbm2(self: Noise, x: number, y: number, octaves: number, lacunarity: number?, gain: number?): number
	local lac = lacunarity or 2
	local g = gain or 0.5
	local sum, amp, norm = 0, 1, 0
	for _ = 1, octaves do
		sum += self:noise2(x, y) * amp
		norm += amp
		amp *= g
		x *= lac
		y *= lac
	end
	return sum / norm
end

-- Ridged multifractal: sharp crests, useful for mountain ranges. Returns [0, 1].
function Noise.ridged2(self: Noise, x: number, y: number, octaves: number): number
	local sum, amp, norm = 0, 1, 0
	for _ = 1, octaves do
		local n = 1 - math.abs(self:noise2(x, y))
		sum += n * n * amp
		norm += amp
		amp *= 0.5
		x *= 2
		y *= 2
	end
	return sum / norm
end

return Noise
