--!strict
--!native
-- Deterministic integer hashing and a tiny PRNG.
--
-- Why not Roblox's Random? World generation must give bit-identical results on server, client
-- and in headless tests (Lune). Everything here uses exact integer arithmetic on doubles
-- (all intermediates < 2^53), so it is deterministic on every platform.

local Hash = {}

local TWO32 = 4294967296

-- Wrap any integer (including negatives) into an unsigned 32-bit value.
local function u32(x: number): number
	return x % TWO32
end
Hash.u32 = u32

-- Exact 32-bit multiply (mod 2^32), split into 16-bit halves so nothing exceeds 2^53.
local function mul32(a: number, b: number): number
	local aLo = a % 65536
	local aHi = (a - aLo) / 65536
	local bLo = b % 65536
	local bHi = (b - bLo) / 65536
	local cross = (aHi * bLo + aLo * bHi) % 65536
	return (cross * 65536 + aLo * bLo) % TWO32
end
Hash.mul32 = mul32

-- "lowbias32" integer finaliser: good avalanche, cheap.
local function mix(x: number): number
	x = bit32.bxor(x, bit32.rshift(x, 16))
	x = mul32(x, 0x7feb352d)
	x = bit32.bxor(x, bit32.rshift(x, 15))
	x = mul32(x, 0x846ca68b)
	x = bit32.bxor(x, bit32.rshift(x, 16))
	return x
end
Hash.mix = mix

-- Hash of up to three integer coordinates plus a seed/salt. Returns u32.
function Hash.hash3(seed: number, x: number, y: number, z: number): number
	local h = mix(u32(seed))
	h = mix(bit32.bxor(h, u32(x)))
	h = mix(bit32.bxor(h, u32(u32(y) + 0x9e3779b9)))
	h = mix(bit32.bxor(h, u32(z)))
	return h
end

-- Hash to a float in [0, 1).
function Hash.hash3f(seed: number, x: number, y: number, z: number): number
	return Hash.hash3(seed, x, y, z) / TWO32
end

-- Small counter-based PRNG. Same seed => same sequence everywhere.
export type Rng = {
	state: number,
	nextU32: (self: Rng) -> number,
	nextFloat: (self: Rng) -> number,
	nextInt: (self: Rng, lo: number, hi: number) -> number, -- inclusive
}

local Rng = {}
Rng.__index = Rng

function Rng.nextU32(self: Rng): number
	self.state = (self.state + 0x6d2b79f5) % TWO32
	return mix(self.state)
end

function Rng.nextFloat(self: Rng): number
	return self:nextU32() / TWO32
end

function Rng.nextInt(self: Rng, lo: number, hi: number): number
	return lo + (self:nextU32() % (hi - lo + 1))
end

function Hash.newRng(seed: number): Rng
	return (setmetatable({ state = u32(seed) }, Rng) :: any) :: Rng
end

return Hash
