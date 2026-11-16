--!strict
-- Plants (short grass, flowers, crops) are drawn ONLY where their pixels are: each plant
-- texture is split into a few solid rectangles of pixels, and every rectangle becomes its own
-- piece of sheet in the terrain mesh, textured with exactly those pixels. Nothing see-through is
-- ever drawn, so the look doesn't depend on Roblox showing transparent texture pixels (it drew
-- them as dark squares).
--
-- Sheets (Java's models): short grass and flowers are an X (two sheets corner to corner across
-- the block), crops a # (sheets at 4/16 and 12/16 along x and along z). Both sides of every
-- sheet show the same pixels.
--
-- Plant quads use their own directions in GreedyMesher's quad format (see GreedyMesher.quadCorners):
--   7 / 8    sheet from (i, j) towards +x +z, front / back
--   9 / 10   sheet from (i, j) towards +x -z, front / back
--   11 / 12  sheet at x = i across z from j, front / back
--   13 / 14  sheet at z = j across x from i, front / back
-- with k = bottom, w = length (in x or z units), h = height, and the texture rectangle packed in
-- the last fields: [7] brightness, [8] = px0 + px1 * 32, [9] = py0 + py1 * 32 (pixels, y down),
-- [10] brightness.

local BlockRegistry = require(script.Parent.Parent.Blocks.BlockRegistry)
local TextureGen = require(script.Parent.Parent.Blocks.TextureGen)

local PlantGeometry = {}

export type Rect = { number } -- px0, py0, px1, py1 (end exclusive)

local cache: { [number]: { Rect } } = {}

-- Solid rectangles covering a 16x16 RGBA image's opaque pixels (alpha >= 128): column-first
-- greedy (plant stalks are vertical), so a straight stalk is one rectangle.
function PlantGeometry.rectsOf(img: buffer): { Rect }
	local mask = table.create(256, false)
	for i = 0, 255 do
		mask[i + 1] = buffer.readu8(img, i * 4 + 3) >= 128
	end
	local used = table.create(256, false)
	local out: { Rect } = {}
	for x = 0, 15 do
		for y = 0, 15 do
			local i = y * 16 + x + 1
			if mask[i] and not used[i] then
				-- down as far as it goes, then right while whole columns match
				local y1 = y
				while y1 + 1 <= 15 and mask[(y1 + 1) * 16 + x + 1] and not used[(y1 + 1) * 16 + x + 1] do
					y1 += 1
				end
				local x1 = x
				while x1 + 1 <= 15 do
					local ok = true
					for yy = y, y1 do
						local j = yy * 16 + x1 + 2
						if not mask[j] or used[j] then
							ok = false
							break
						end
					end
					if not ok then
						break
					end
					x1 += 1
				end
				for yy = y, y1 do
					for xx = x, x1 do
						used[yy * 16 + xx + 1] = true
					end
				end
				table.insert(out, { x, y, x1 + 1, y1 + 1 })
			end
		end
	end
	return out
end

-- Rectangles of a texture (by atlas texture index), cached.
function PlantGeometry.rects(tex: number): { Rect }
	local r = cache[tex]
	if not r then
		local key = BlockRegistry.textureKeys[tex]
		r = PlantGeometry.rectsOf(TextureGen.generate(key))
		cache[tex] = r
	end
	return r
end

-- Append the quads of one plant block at section-local (x, y, z) to `list`. `kind` is "cross"
-- (short grass, flowers) or "crop". Returns the number of quads.
function PlantGeometry.emit(list: { number }, tex: number, kind: string, x: number, y: number, z: number, bright: number): number
	local n = 0
	local function quad(d: number, k: number, i: number, j: number, w: number, h: number, r: Rect)
		local o = #list
		list[o + 1], list[o + 2], list[o + 3], list[o + 4], list[o + 5], list[o + 6] = d, k, i, j, w, h
		list[o + 7], list[o + 8], list[o + 9], list[o + 10] = bright, r[1] + r[3] * 32, r[2] + r[4] * 32, bright
		n += 1
	end
	for _, r in PlantGeometry.rects(tex) do
		local s0, s1 = r[1] / 16, r[3] / 16
		local k, h = y + (1 - r[4] / 16), (r[4] - r[2]) / 16
		local w = s1 - s0
		if kind == "cross" then
			quad(7, k, x + s0, z + s0, w, h, r)
			quad(8, k, x + s0, z + s0, w, h, r)
			quad(9, k, x + s0, z + 1 - s0, w, h, r)
			quad(10, k, x + s0, z + 1 - s0, w, h, r)
		else
			for _, at in { 4 / 16, 12 / 16 } do
				quad(11, k, x + at, z + s0, w, h, r)
				quad(12, k, x + at, z + s0, w, h, r)
				quad(13, k, x + s0, z + at, w, h, r)
				quad(14, k, x + s0, z + at, w, h, r)
			end
		end
	end
	return n
end

return PlantGeometry
