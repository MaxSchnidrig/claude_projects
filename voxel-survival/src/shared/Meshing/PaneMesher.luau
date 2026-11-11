--!strict
--!native
-- Glass panes of one section, as the outer faces of all the glass together.
--
-- A pane is a thin post with an arm toward each neighbour it joins. Drawn piece by piece, every
-- face between two pieces (post and arm, pane and pane, pane and glass block) would show as a
-- line through the glass. So the panes of a section are treated as one solid: each cell is cut
-- into 3 x 3 columns (0 .. 7/16 .. 9/16 .. 1 along x and z; a pane fills the middle one and
-- the arms), a face is only kept where glass meets something that is not glass, and the kept
-- faces of one plane are merged into rectangles. A straight window is one rectangle per side.
--
-- Output: quads in GreedyMesher's format (dir, k, i, j, w, h, 255 x 4), fractional coordinates.

local Shared = script.Parent.Parent
local Config = require(Shared.Config)
local BlockRegistry = require(Shared.Blocks.BlockRegistry)
local SectionSampler = require(script.Parent.SectionSampler)
local Shapes = require(Shared.Blocks.Shapes)

local SS = Config.SECTION_SIZE
local P = SectionSampler.SIZE
local P2 = P * P

local PaneMesher = {}

-- Which block ids are glass panes (iron bars are rods: meshed like other shapes).
local isPane: { [number]: boolean } = {}
for id, def in BlockRegistry.byId do
	if def.shape == "pane" and not def.state.bars then
		isPane[id] = true
	end
end
PaneMesher.isPane = isPane

-- Column edges inside a cell: column r (0..2) spans EDGE[r + 1] .. EDGE[r + 2].
local EDGE = { 0, 7 / 16, 9 / 16, 1 }

-- Shape of a pane cell as bits: 1 post, 2 west arm, 4 east, 8 north (-z), 16 south (+z).
-- FILLED[mask * 9 + rx + rz * 3 + 1]: is column (rx, rz) glass?
local FILLED: { boolean } = table.create(32 * 9, false)
for mask = 1, 31, 2 do
	local base = mask * 9
	FILLED[base + 1 + 1 * 3 + 1] = true
	FILLED[base + 0 + 1 * 3 + 1] = bit32.band(mask, 2) ~= 0
	FILLED[base + 2 + 1 * 3 + 1] = bit32.band(mask, 4) ~= 0
	FILLED[base + 1 + 0 * 3 + 1] = bit32.band(mask, 8) ~= 0
	FILLED[base + 1 + 2 * 3 + 1] = bit32.band(mask, 16) ~= 0
end

-- Per direction (BlockRegistry.Dir order): axis (0 x, 1 y, 2 z), sign, and the face's u, v axes.
local DIRS = {
	{ axis = 0, sign = 1, u = 1, v = 2 },
	{ axis = 0, sign = -1, u = 2, v = 1 },
	{ axis = 1, sign = 1, u = 2, v = 0 },
	{ axis = 1, sign = -1, u = 0, v = 2 },
	{ axis = 2, sign = 1, u = 0, v = 1 },
	{ axis = 2, sign = -1, u = 1, v = 0 },
}
local OPP = { 2, 1, 4, 3, 6, 5 }

-- Position (blocks) of fine index `s` on an axis: x and z count columns (3 per cell), y cells.
local function lowEdge(axis: number, s: number): number
	if axis == 1 then
		return s
	end
	return s // 3 + EDGE[s % 3 + 1]
end
local function highEdge(axis: number, s: number): number
	if axis == 1 then
		return s + 1
	end
	return s // 3 + EDGE[s % 3 + 2]
end

-- Appends the glass panes' faces to `groups` (texture -> quad list). `cells` lists the padded
-- indices of the section's own pane cells. Returns (quads, faces before merging).
function PaneMesher.emit(padded: buffer, cells: { number }, groups: { [number]: { number } }): (number, number)
	local paneConnects = Shapes.paneConnects
	local coversFace, sturdyCube = Shapes.coversFace, Shapes.sturdyCube
	local shapeCache: { [number]: number } = {}

	-- Shape bits of the padded cell (px, py, pz); 0 if it isn't a pane (or is outside the buffer).
	local function shapeAt(px: number, py: number, pz: number): number
		if px < 0 or px >= P or py < 0 or py >= P or pz < 0 or pz >= P then
			return 0
		end
		local p = px + pz * P + py * P2
		local m = shapeCache[p]
		if m then
			return m
		end
		m = 0
		if isPane[buffer.readu16(padded, p * 2)] then
			m = 1
			if px > 0 and paneConnects(buffer.readu16(padded, (p - 1) * 2)) then
				m += 2
			end
			if px < P - 1 and paneConnects(buffer.readu16(padded, (p + 1) * 2)) then
				m += 4
			end
			if pz > 0 and paneConnects(buffer.readu16(padded, (p - P) * 2)) then
				m += 8
			end
			if pz < P - 1 and paneConnects(buffer.readu16(padded, (p + P) * 2)) then
				m += 16
			end
		end
		shapeCache[p] = m
		return m
	end

	-- faces by (texture, direction, plane): fine (u, v) cells of that plane that show
	local buckets: { [number]: { tex: number, d: number, plane: number, cells: { number }, mask: { [number]: boolean } } } = {}
	local faces = 0
	for _, p in cells do
		local px, py, pz = p % P, p // P2, (p // P) % P
		local id = buffer.readu16(padded, p * 2)
		local tex = BlockRegistry.byId[id].faceTexture[1]
		local own = shapeAt(px, py, pz)
		local x, y, z = px - 1, py - 1, pz - 1
		for rz = 0, 2 do
			for rx = 0, 2 do
				if FILLED[own * 9 + rx + rz * 3 + 1] then
					for d = 1, 6 do
						local dir = DIRS[d]
						-- the column on the other side of this face
						local nx, ny, nz, nrx, nrz = px, py, pz, rx, rz
						if dir.axis == 0 then
							nrx += dir.sign
							if nrx < 0 then
								nx, nrx = px - 1, 2
							elseif nrx > 2 then
								nx, nrx = px + 1, 0
							end
						elseif dir.axis == 2 then
							nrz += dir.sign
							if nrz < 0 then
								nz, nrz = pz - 1, 2
							elseif nrz > 2 then
								nz, nrz = pz + 1, 0
							end
						else
							ny = py + dir.sign
						end
						local otherCell = nx ~= px or ny ~= py or nz ~= pz
						local hidden = FILLED[(if otherCell then shapeAt(nx, ny, nz) else own) * 9 + nrx + nrz * 3 + 1]
						if not hidden and otherCell then
							-- against a full block (glass too) there is no face either
							local n = buffer.readu16(padded, (nx + nz * P + ny * P2) * 2)
							hidden = n ~= 0 and (coversFace(n, OPP[d]) or sturdyCube(n))
						end
						if not hidden then
							faces += 1
							-- fine coordinates: x and z in columns, y in cells
							local fine = { x * 3 + rx, y, z * 3 + rz }
							local plane = fine[dir.axis + 1] + (if dir.sign > 0 then 1 else 0)
							local key = (tex * 8 + d) * 64 + plane
							local b = buckets[key]
							if not b then
								b = { tex = tex, d = d, plane = plane, cells = {}, mask = {} }
								buckets[key] = b
							end
							local c = fine[dir.u + 1] + fine[dir.v + 1] * 64
							b.mask[c] = true
							table.insert(b.cells, c)
						end
					end
				end
			end
		end
	end

	-- merge each plane's cells into rectangles (rows first, then stacked rows of the same span)
	local quads = 0
	for _, b in buckets do
		local dir = DIRS[b.d]
		local mask = b.mask
		table.sort(b.cells)
		local list = groups[b.tex]
		if not list then
			list = {}
			groups[b.tex] = list
		end
		for _, c in b.cells do
			if mask[c] then
				local u0, v0 = c % 64, c // 64
				local w = 1
				while mask[u0 + w + v0 * 64] do
					w += 1
				end
				local h = 1
				while true do
					local row = (v0 + h) * 64
					local full = true
					for u = u0, u0 + w - 1 do
						if not mask[u + row] then
							full = false
							break
						end
					end
					if not full then
						break
					end
					h += 1
				end
				for v = v0, v0 + h - 1 do
					for u = u0, u0 + w - 1 do
						mask[u + v * 64] = nil
					end
				end
				-- back to block units
				local plane = if dir.sign > 0 then highEdge(dir.axis, b.plane - 1) else lowEdge(dir.axis, b.plane)
				local i0, i1 = lowEdge(dir.u, u0), highEdge(dir.u, u0 + w - 1)
				local j0, j1 = lowEdge(dir.v, v0), highEdge(dir.v, v0 + h - 1)
				local n = #list
				list[n + 1] = b.d
				list[n + 2] = if dir.sign > 0 then plane - 1 else plane
				list[n + 3] = i0
				list[n + 4] = j0
				list[n + 5] = i1 - i0
				list[n + 6] = j1 - j0
				list[n + 7], list[n + 8], list[n + 9], list[n + 10] = 255, 255, 255, 255
				quads += 1
			end
		end
	end
	return quads, faces
end

return PaneMesher
