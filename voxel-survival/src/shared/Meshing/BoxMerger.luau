--!strict
--!native
-- 3D greedy box merging over a 16^3 section. Used for:
--   * collision: one invisible Part per merged box of solid blocks
--   * the Parts render backend: one Part per merged box of exposed blocks of one type
--
-- `keyOf(id, paddedIndex)` returns 0 to skip a cell, otherwise a group key; only cells with the
-- same key merge. A key of -1 is a WILDCARD: the cell never starts a box, but any box may grow
-- through it. Used for buried blocks that can never be seen, which lets visible boxes extend into
-- the ground and cuts Part counts a lot. Output is a flat list of 7 numbers per box: x, y, z, sx, sy, sz, key
-- (section-local block units).

local Shared = script.Parent.Parent
local Config = require(Shared.Config)
local SectionSampler = require(script.Parent.SectionSampler)

local SS = Config.SECTION_SIZE
local P = SectionSampler.SIZE
local P2 = P * P
local N = SS * SS * SS

local BoxMerger = {}

local keys = table.create(N, 0)

local function li(x: number, y: number, z: number): number
	return x + z * SS + y * SS * SS + 1
end

local WILDCARD = -1
BoxMerger.WILDCARD = WILDCARD

function BoxMerger.merge(padded: buffer, keyOf: (id: number, p: number) -> number): ({ number }, number)
	-- Resolve keys once.
	for y = 0, SS - 1 do
		for z = 0, SS - 1 do
			for x = 0, SS - 1 do
				local p = (x + 1) + (z + 1) * P + (y + 1) * P2
				local id = buffer.readu16(padded, p * 2)
				keys[li(x, y, z)] = if id == 0 then 0 else keyOf(id, p)
			end
		end
	end

	local out: { number } = {}
	local count = 0
	for y = 0, SS - 1 do
		for z = 0, SS - 1 do
			for x = 0, SS - 1 do
				local key = keys[li(x, y, z)]
				if key > 0 then
					-- grow along x
					local sx = 1
					local function fits(k: number): boolean
						return k == key or k == WILDCARD
					end
					while x + sx < SS and fits(keys[li(x + sx, y, z)]) do
						sx += 1
					end
					-- grow along z
					local sz = 1
					local ok = true
					while z + sz < SS and ok do
						for t = 0, sx - 1 do
							if not fits(keys[li(x + t, y, z + sz)]) then
								ok = false
								break
							end
						end
						if ok then
							sz += 1
						end
					end
					-- grow along y
					local sy = 1
					ok = true
					while y + sy < SS and ok do
						for tz = 0, sz - 1 do
							for tx = 0, sx - 1 do
								if not fits(keys[li(x + tx, y + sy, z + tz)]) then
									ok = false
									break
								end
							end
							if not ok then
								break
							end
						end
						if ok then
							sy += 1
						end
					end
					-- consume
					for ty = 0, sy - 1 do
						for tz = 0, sz - 1 do
							for tx = 0, sx - 1 do
								keys[li(x + tx, y + ty, z + tz)] = 0
							end
						end
					end
					local n = #out
					out[n + 1] = x
					out[n + 2] = y
					out[n + 3] = z
					out[n + 4] = sx
					out[n + 5] = sy
					out[n + 6] = sz
					out[n + 7] = key
					count += 1
				end
			end
		end
	end
	return out, count
end

-- Offsets of the 6 axis neighbours in the padded buffer.
BoxMerger.NEIGHBOR_OFFSETS = { 1, -1, P2, -P2, P, -P }

return BoxMerger
