--!strict
-- Geometry for 3D items (pure, so it's tested headless):
--
--   flat(icon)    Java-style extruded item: every opaque pixel of the 16x16 icon becomes a 1-pixel
--                 deep block. Front and back faces are merged into rectangles of one colour;
--                 side faces exist only on edges next to an empty pixel, coloured like that edge
--                 pixel and merged along runs of the same colour. Units: pixels, centred
--                 (x -8..8, y -8..8, z -0.5..0.5), front facing +Z.
--   boxes(list)   block items: the faces of the block's boxes (Items/BlockIconGen shapes) with
--                 their texture coordinates (s, t in 0..1 of the face texture, t down, mapped
--                 world-aligned like the terrain). Units: blocks, centred (-0.5..0.5).
--
-- Every quad's corners go counter-clockwise seen from outside: (c1 - c0) x (c2 - c0) points
-- along the normal (the winding the terrain mesher uses).

local ItemExtrude = {}

export type Quad = {
	dir: number, -- 1 +X, 2 -X, 3 +Y, 4 -Y, 5 +Z, 6 -Z (BlockRegistry.Dir order)
	v: { number }, -- 4 corners x, y, z
	c: { number }?, -- flat: colour r, g, b (0..255)
	st: { number }?, -- boxes: 4 corners s, t
}

local N = 16

local function alphaAt(img: buffer, x: number, y: number): number
	if x < 0 or y < 0 or x >= N or y >= N then
		return 0
	end
	return buffer.readu8(img, (y * N + x) * 4 + 3)
end

local function colorAt(img: buffer, x: number, y: number): number
	return bit32.band(buffer.readu32(img, (y * N + x) * 4), 0x00FFFFFF) -- r, g, b packed
end

local function rgb(packed: number, f: number): { number }
	return {
		math.floor(bit32.band(packed, 0xFF) * f + 0.5),
		math.floor(bit32.band(bit32.rshift(packed, 8), 0xFF) * f + 0.5),
		math.floor(bit32.band(bit32.rshift(packed, 16), 0xFF) * f + 0.5),
	}
end

-- side faces are a touch darker so the thickness reads (the world light shades them further)
ItemExtrude.SIDE_SHADE = 0.86

function ItemExtrude.flat(img: buffer): { Quad }
	local quads: { Quad } = {}
	local solid = function(x: number, y: number): boolean
		return alphaAt(img, x, y) > 0
	end

	-- front and back: greedy rectangles of one colour
	local used = table.create(N * N, false)
	for y = 0, N - 1 do
		for x = 0, N - 1 do
			if solid(x, y) and not used[y * N + x + 1] then
				local col = colorAt(img, x, y)
				local w = 1
				while x + w < N and solid(x + w, y) and not used[y * N + x + w + 1] and colorAt(img, x + w, y) == col do
					w += 1
				end
				local h = 1
				while y + h < N do
					local ok = true
					for i = 0, w - 1 do
						local xx = x + i
						if not solid(xx, y + h) or used[(y + h) * N + xx + 1] or colorAt(img, xx, y + h) ~= col then
							ok = false
							break
						end
					end
					if not ok then
						break
					end
					h += 1
				end
				for yy = y, y + h - 1 do
					for xx = x, x + w - 1 do
						used[yy * N + xx + 1] = true
					end
				end
				local X0, X1, YT, YB = x - 8, x + w - 8, 8 - y, 8 - (y + h)
				local c = rgb(col, 1)
				table.insert(quads, { dir = 5, v = { X0, YB, 0.5, X1, YB, 0.5, X1, YT, 0.5, X0, YT, 0.5 }, c = c })
				table.insert(quads, { dir = 6, v = { X0, YB, -0.5, X0, YT, -0.5, X1, YT, -0.5, X1, YB, -0.5 }, c = c })
			end
		end
	end

	-- top / bottom edges: runs along x
	for y = 0, N - 1 do
		for _, side in { -1, 1 } do -- -1: the edge above the pixel (top face), 1: below
			local x = 0
			while x < N do
				if solid(x, y) and not solid(x, y + side) then
					local col = colorAt(img, x, y)
					local w = 1
					while x + w < N and solid(x + w, y) and not solid(x + w, y + side) and colorAt(img, x + w, y) == col do
						w += 1
					end
					local X0, X1 = x - 8, x + w - 8
					local c = rgb(col, ItemExtrude.SIDE_SHADE)
					if side == -1 then
						local Y = 8 - y
						table.insert(quads, { dir = 3, v = { X0, Y, 0.5, X1, Y, 0.5, X1, Y, -0.5, X0, Y, -0.5 }, c = c })
					else
						local Y = 8 - (y + 1)
						table.insert(quads, { dir = 4, v = { X0, Y, -0.5, X1, Y, -0.5, X1, Y, 0.5, X0, Y, 0.5 }, c = c })
					end
					x += w
				else
					x += 1
				end
			end
		end
	end

	-- left / right edges: runs along y
	for x = 0, N - 1 do
		for _, side in { -1, 1 } do -- -1: left edge, 1: right edge
			local y = 0
			while y < N do
				if solid(x, y) and not solid(x + side, y) then
					local col = colorAt(img, x, y)
					local h = 1
					while y + h < N and solid(x, y + h) and not solid(x + side, y + h) and colorAt(img, x, y + h) == col do
						h += 1
					end
					local YT, YB = 8 - y, 8 - (y + h)
					local c = rgb(col, ItemExtrude.SIDE_SHADE)
					if side == -1 then
						local X = x - 8
						table.insert(quads, { dir = 2, v = { X, YB, -0.5, X, YB, 0.5, X, YT, 0.5, X, YT, -0.5 }, c = c })
					else
						local X = x + 1 - 8
						table.insert(quads, { dir = 1, v = { X, YB, 0.5, X, YB, -0.5, X, YT, -0.5, X, YT, 0.5 }, c = c })
					end
					y += h
				else
					y += 1
				end
			end
		end
	end
	return quads
end

-- Faces of boxes { x0, y0, z0, x1, y1, z1 } (block units 0..1) with world-aligned texture coords.
function ItemExtrude.boxes(list: { { number } }): { Quad }
	local quads: { Quad } = {}
	for _, b in list do
		local x0, y0, z0, x1, y1, z1 = b[1], b[2], b[3], b[4], b[5], b[6]
		local function add(dir: number, corners: { { number } }, st: { { number } })
			local v, s = {}, {}
			for k = 1, 4 do
				local c = corners[k]
				table.insert(v, c[1] - 0.5)
				table.insert(v, c[2] - 0.5)
				table.insert(v, c[3] - 0.5)
				table.insert(s, st[k][1])
				table.insert(s, st[k][2])
			end
			table.insert(quads, { dir = dir, v = v, st = s })
		end
		add(3, { { x0, y1, z1 }, { x1, y1, z1 }, { x1, y1, z0 }, { x0, y1, z0 } }, { { x0, z1 }, { x1, z1 }, { x1, z0 }, { x0, z0 } })
		add(4, { { x0, y0, z0 }, { x1, y0, z0 }, { x1, y0, z1 }, { x0, y0, z1 } }, { { x0, z0 }, { x1, z0 }, { x1, z1 }, { x0, z1 } })
		add(1, { { x1, y0, z1 }, { x1, y0, z0 }, { x1, y1, z0 }, { x1, y1, z1 } },
			{ { 1 - z1, 1 - y0 }, { 1 - z0, 1 - y0 }, { 1 - z0, 1 - y1 }, { 1 - z1, 1 - y1 } })
		add(2, { { x0, y0, z0 }, { x0, y0, z1 }, { x0, y1, z1 }, { x0, y1, z0 } },
			{ { z0, 1 - y0 }, { z1, 1 - y0 }, { z1, 1 - y1 }, { z0, 1 - y1 } })
		add(5, { { x0, y0, z1 }, { x1, y0, z1 }, { x1, y1, z1 }, { x0, y1, z1 } },
			{ { x0, 1 - y0 }, { x1, 1 - y0 }, { x1, 1 - y1 }, { x0, 1 - y1 } })
		add(6, { { x1, y0, z0 }, { x0, y0, z0 }, { x0, y1, z0 }, { x1, y1, z0 } },
			{ { 1 - x1, 1 - y0 }, { 1 - x0, 1 - y0 }, { 1 - x0, 1 - y1 }, { 1 - x1, 1 - y1 } })
	end
	return quads
end

ItemExtrude.NORMALS = {
	{ 1, 0, 0 }, { -1, 0, 0 }, { 0, 1, 0 }, { 0, -1, 0 }, { 0, 0, 1 }, { 0, 0, -1 },
}

return ItemExtrude
