--!strict
-- 3D inventory icons for block items (like Java's GUI block models): the block's boxes seen from
-- above at the front-left corner (Java's 30 deg / 225 deg view), each face painted with its own
-- texture and shaded like Java's GUI light (top brightest, left side, then right side darker).
-- Drawn by casting one ray per output pixel, so texture pixels stay crisp (nearest texel), and
-- see-through texels (leaves, glass) show what's behind them.
--
-- Shapes: full blocks, slabs, stairs, walls, fences. Other block items (doors, plants, beds...)
-- keep their flat icon (Items/ItemIconGen), as Java shows most of them flat too.
-- Output: SIZE x SIZE RGBA buffer, transparent background.

local BlockRegistry = require(script.Parent.Parent.Blocks.BlockRegistry)
local TextureGen = require(script.Parent.Parent.Blocks.TextureGen)
local TexturePalette = require(script.Parent.Parent.Blocks.TexturePalette)

local BlockIconGen = {}
BlockIconGen.SIZE = 64

type Box = { number } -- x0, y0, z0, x1, y1, z1 in block units

local SHAPES: { [string]: { Box } } = {
	cube = { { 0, 0, 0, 1, 1, 1 } },
	slab = { { 0, 0, 0, 1, 0.5, 1 } },
	stairs = { { 0, 0, 0, 1, 0.5, 1 }, { 0, 0.5, 0, 1, 1, 0.5 } },
	wall = { { 0.25, 0, 0.25, 0.75, 1, 0.75 }, { 0.3125, 0, 0, 0.6875, 0.875, 1 } },
	cactus = { { 1 / 16, 0, 1 / 16, 15 / 16, 1, 15 / 16 } },
	carpet = { { 0, 0, 0, 1, 1 / 16, 1 } },
	enchanting_table = { { 0, 0, 0, 1, 12 / 16, 1 } },
	campfire = { { 0, 0, 0, 1, 7 / 16, 1 } },
	fence = {
		{ 0.375, 0, 0, 0.625, 1, 0.25 }, { 0.375, 0, 0.75, 0.625, 1, 1 },
		{ 0.4375, 0.375, 0.25, 0.5625, 0.5625, 0.75 }, { 0.4375, 0.75, 0.25, 0.5625, 0.9375, 0.75 },
	},
}

BlockIconGen.SHAPES = SHAPES

-- Which shape a block item uses, or nil if it keeps a flat icon. `icon` is the item's flat-icon
-- kind (ItemRegistry), `blockShape` the block's own shape (BlockRegistry).
function BlockIconGen.shapeOf(icon: string?, blockShape: string?): string?
	if icon == nil then
		if blockShape == nil or blockShape == "cube" then
			return "cube"
		end
		return if SHAPES[blockShape] then blockShape else nil -- (torches: flat)
	elseif SHAPES[icon] then
		return icon
	end
	return nil
end

-- Shape for a block item def (ItemRegistry.ItemDef), or nil (flat icon).
function BlockIconGen.shapeForItem(def: any): string?
	if not def.block then
		return nil
	end
	local b = BlockRegistry.byId[def.block]
	return BlockIconGen.shapeOf(def.icon, b and b.shape)
end

-- View (Java GUI: pitch 30 deg, yaw 225 deg, orthographic). The camera sits toward +X, +Y, +Z.
local pitch, yaw = math.rad(30), math.rad(45)
local D = { math.cos(pitch) * math.sin(yaw), math.sin(pitch), math.cos(pitch) * math.cos(yaw) } -- toward camera
local F = { -D[1], -D[2], -D[3] }
local R = { math.cos(yaw), 0, -math.sin(yaw) } -- screen right
-- screen up = R x F
local U = { R[2] * F[3] - R[3] * F[2], R[3] * F[1] - R[1] * F[3], R[1] * F[2] - R[2] * F[1] }
-- Java GUI light per face direction (Dir order: east, west, top, bottom, south, north)
local LIGHT = { 0.8, 0.8, 1.0, 0.5, 0.62, 0.62 }

-- the cube's corners span this much of the screen in R / U (fit with a small margin)
local HALF_W, CENTER_U, HALF_H
do
	local minR, maxR, minU, maxU = math.huge, -math.huge, math.huge, -math.huge
	for _, x in { 0, 1 } do
		for _, y in { 0, 1 } do
			for _, z in { 0, 1 } do
				local px, py, pz = x - 0.5, y - 0.5, z - 0.5
				local r = px * R[1] + py * R[2] + pz * R[3]
				local u = px * U[1] + py * U[2] + pz * U[3]
				minR, maxR = math.min(minR, r), math.max(maxR, r)
				minU, maxU = math.min(minU, u), math.max(maxU, u)
			end
		end
	end
	HALF_W = math.max(maxR - minR, maxU - minU) / 2 * 1.04
	CENTER_U = (minU + maxU) / 2
	HALF_H = HALF_W
end

local texCache: { [number]: buffer } = {}
local function texture(index: number): buffer
	local t = texCache[index]
	if not t then
		local key = BlockRegistry.textureKeys[index]
		t = TextureGen.generate(key, TexturePalette[key])
		texCache[index] = t
	end
	return t
end

-- Texel (RGBA) of face `dir` at the hit point (x, y, z), world-aligned like Java's block UVs.
local function texel(tex: buffer, dir: number, x: number, y: number, z: number): (number, number, number, number)
	local u, v
	if dir == 3 or dir == 4 then
		u, v = x, z
	elseif dir == 1 then
		u, v = 1 - z, 1 - y
	elseif dir == 2 then
		u, v = z, 1 - y
	elseif dir == 5 then
		u, v = x, 1 - y
	else
		u, v = 1 - x, 1 - y
	end
	local tx = math.clamp(math.floor(u * 16), 0, 15)
	local ty = math.clamp(math.floor(v * 16), 0, 15)
	local o = (ty * 16 + tx) * 4
	return buffer.readu8(tex, o), buffer.readu8(tex, o + 1), buffer.readu8(tex, o + 2), buffer.readu8(tex, o + 3)
end

type Hit = { t: number, dir: number, x: number, y: number, z: number }

-- All face hits of a ray with an axis-aligned box (entry and exit faces), unsorted.
local function boxHits(o: { number }, d: { number }, b: Box, out: { Hit })
	for axis = 1, 3 do
		if math.abs(d[axis]) > 1e-9 then
			for side = 0, 1 do
				local plane = b[axis + side * 3]
				local t = (plane - o[axis]) / d[axis]
				local p = { o[1] + d[1] * t, o[2] + d[2] * t, o[3] + d[3] * t }
				local a2, a3 = axis % 3 + 1, (axis + 1) % 3 + 1
				local e = 1e-7
				if p[a2] >= b[a2] - e and p[a2] <= b[a2 + 3] + e and p[a3] >= b[a3] - e and p[a3] <= b[a3 + 3] + e then
					-- Dir: x -> east(1)/west(2), y -> top(3)/bottom(4), z -> south(5)/north(6)
					local dir = if axis == 1 then (if side == 1 then 1 else 2)
						elseif axis == 2 then (if side == 1 then 3 else 4)
						else (if side == 1 then 5 else 6)
					table.insert(out, { t = t, dir = dir, x = p[1], y = p[2], z = p[3] })
				end
			end
		end
	end
end

-- Render the icon of block `blockId` with shape `shape` ("cube", "slab", ...).
function BlockIconGen.render(blockId: number, shape: string): buffer
	local S = BlockIconGen.SIZE
	local img = buffer.create(S * S * 4)
	local def = BlockRegistry.byId[blockId]
	local boxes = SHAPES[shape] or SHAPES.cube
	if not def then
		return img
	end
	local faceTex = {}
	for dir = 1, 6 do
		faceTex[dir] = texture(def.faceTexture[dir])
	end
	local hits: { Hit } = {}
	for py = 0, S - 1 do
		for px = 0, S - 1 do
			-- screen point -> ray in block space (centre of the block at the screen centre)
			local sx = ((px + 0.5) / S * 2 - 1) * HALF_W
			local sy = (1 - (py + 0.5) / S * 2) * HALF_H + CENTER_U
			local o = {
				0.5 + R[1] * sx + U[1] * sy - F[1] * 4,
				0.5 + R[2] * sx + U[2] * sy - F[2] * 4,
				0.5 + R[3] * sx + U[3] * sy - F[3] * 4,
			}
			table.clear(hits)
			for _, b in boxes do
				boxHits(o, F, b, hits)
			end
			table.sort(hits, function(a, b)
				return a.t < b.t
			end)
			for _, h in hits do
				local r, g, bl, a = texel(faceTex[h.dir], h.dir, h.x, h.y, h.z)
				if a > 0 then
					-- faces seen from behind (through a see-through texel) are the darkest
					local facing = (h.dir == 1 and F[1] < 0) or (h.dir == 2 and F[1] > 0) or (h.dir == 3 and F[2] < 0)
						or (h.dir == 4 and F[2] > 0) or (h.dir == 5 and F[3] < 0) or (h.dir == 6 and F[3] > 0)
					local l = if facing then LIGHT[h.dir] else 0.45
					local out = (py * S + px) * 4
					buffer.writeu8(img, out, math.floor(r * l + 0.5))
					buffer.writeu8(img, out + 1, math.floor(g * l + 0.5))
					buffer.writeu8(img, out + 2, math.floor(bl * l + 0.5))
					buffer.writeu8(img, out + 3, 255)
					break
				end
			end
		end
	end
	return img
end

return BlockIconGen
