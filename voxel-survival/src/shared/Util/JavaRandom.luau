--!strict
-- java.util.Random, exactly: the 48-bit linear congruential generator Java Edition uses for the
-- enchanting table (offers must come out of the same algorithm as Java's). Luau numbers are
-- doubles, so the 48-bit state is kept in two 24-bit halves and every step is exact.

local JavaRandom = {}
JavaRandom.__index = JavaRandom

local TWO24 = 16777216
local TWO32 = 4294967296
local TWO48 = 281474976710656
-- multiplier 0x5DEECE66D = MH * 2^24 + ML
local MH, ML = 0x5DE, 0xECE66D
local ADD = 0xB

export type JavaRandom = typeof(setmetatable({} :: { hi: number, lo: number }, JavaRandom))

-- setSeed(long): (seed ^ 0x5DEECE66D) & (2^48 - 1). `seed` may be negative (two's complement).
local function scramble(self: any, seed: number)
	seed = math.floor(seed) % TWO48 -- low 48 bits (works for negative longs too)
	local lo32 = seed % TWO32
	local hi16 = (seed - lo32) / TWO32
	lo32 = bit32.bxor(lo32, 0xDEECE66D)
	hi16 = bit32.bxor(hi16, 0x5)
	local v = hi16 * TWO32 + lo32
	self.lo = v % TWO24
	self.hi = (v - self.lo) / TWO24
end

function JavaRandom.new(seed: number): JavaRandom
	local self = setmetatable({ hi = 0, lo = 0 }, JavaRandom)
	scramble(self, seed)
	return self
end

function JavaRandom.setSeed(self: JavaRandom, seed: number)
	scramble(self, seed)
end

-- next(bits): advance the state, return the top `bits` bits (as Java's signed int).
function JavaRandom.next(self: JavaRandom, bits: number): number
	local lo, hi = self.lo, self.hi
	local p0 = lo * ML + ADD -- < 2^48
	local p1 = hi * ML + lo * MH -- < 2^49
	local newLo = p0 % TWO24
	local carry = (p0 - newLo) / TWO24
	local newHi = (p1 + carry) % TWO24
	self.lo, self.hi = newLo, newHi
	local state = newHi * TWO24 + newLo
	local r = math.floor(state / 2 ^ (48 - bits))
	if bits == 32 and r >= 2147483648 then
		r -= TWO32
	end
	return r
end

-- nextInt(): any int
function JavaRandom.nextInt(self: JavaRandom, bound: number?): number
	if bound == nil then
		return self:next(32)
	end
	local n = bound :: number
	assert(n > 0, "bound must be positive")
	if bit32.band(n, n - 1) == 0 then
		return math.floor(n * self:next(31) / 2147483648)
	end
	while true do
		local bits = self:next(31)
		local val = bits % n
		if bits - val + (n - 1) < 2147483648 then
			return val
		end
	end
end

-- nextFloat(): next(24) / 2^24
function JavaRandom.nextFloat(self: JavaRandom): number
	return self:next(24) / TWO24
end

return JavaRandom
