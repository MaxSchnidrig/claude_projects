--!strict
--!native
-- Face-culled greedy mesher (Mikola Lysenko's algorithm) for one 16^3 section.
--
-- Output: quads grouped by texture index. Each quad is GreedyMesher.QUAD (10) numbers:
--     dir, k, i, j, w, h, b0, b1, b2, b3
-- dir  1..6 (BlockRegistry.Dir), k = slice along the face normal axis, (i, j) = start on the
-- face's (u, v) axes, (w, h) = size along (u, v). All in section-local block units.
-- b0..b3: brightness 0..255 at the 4 corners (quadCorners order): smooth light x ambient
-- occlusion. `mesh` (merged, used by tests, the bench and the Parts backend) writes 255.
-- `meshLit` (textured terrain) emits one quad per block face with lighting, because a texture
-- atlas can't tile across merged faces; see-through specials (water, lava, glass, ice) still merge.
--
-- Merging only joins faces with the same texture, which lets a backend tile one texture over a
-- whole merged quad (see ARCHITECTURE.md, "why one MeshPart per texture").

local Shared = script.Parent.Parent
local Config = require(Shared.Config)
local BlockRegistry = require(Shared.Blocks.BlockRegistry)
local SectionSampler = require(script.Parent.SectionSampler)
local Shapes = require(Shared.Blocks.Shapes)

local SS = Config.SECTION_SIZE
local P = SectionSampler.SIZE
local P2 = P * P

local isOpaque = BlockRegistry.isOpaque
local isLiquid = BlockRegistry.isLiquid
local cullSelf = BlockRegistry.cullSelf
local isCube = BlockRegistry.isCube
local isBoxShape = BlockRegistry.isBoxShape

-- Per direction: normal axis (0 x, 1 y, 2 z), sign, and the (u, v) axes with u x v = normal.
-- This ordering gives counter-clockwise winding seen from outside (see quadCorners).
local DIRS = {
	{ axis = 0, sign = 1, u = 1, v = 2 }, -- EAST  +X : u = y, v = z
	{ axis = 0, sign = -1, u = 2, v = 1 }, -- WEST  -X : u = z, v = y
	{ axis = 1, sign = 1, u = 2, v = 0 }, -- TOP   +Y : u = z, v = x
	{ axis = 1, sign = -1, u = 0, v = 2 }, -- BOTTOM -Y : u = x, v = z
	{ axis = 2, sign = 1, u = 0, v = 1 }, -- SOUTH +Z : u = x, v = y
	{ axis = 2, sign = -1, u = 1, v = 0 }, -- NORTH -Z : u = y, v = x
}
-- Stride of each axis inside the padded buffer.
local STRIDE = { [0] = 1, [1] = P2, [2] = P }

-- Precomputed face texture per (block id, dir): faceTex[id * 6 + dir]
local faceTex = table.create(256 * 6 + 6, 0)
for id, def in BlockRegistry.byId do
	for d = 1, 6 do
		faceTex[id * 6 + d] = def.faceTexture[d]
	end
end

local GreedyMesher = {}
GreedyMesher.QUAD = 10
GreedyMesher.DIRS = DIRS
GreedyMesher.STRIDE = STRIDE -- padded-buffer stride per axis (0 x, 1 y, 2 z)

export type MeshResult = {
	groups: { [number]: { number } }, -- texture index -> flat quad list
	quadCount: number,
	faceCount: number, -- faces before merging (for benchmarking)
}

-- Is the face of block `b` towards neighbour `n` visible?
-- (Reference implementation; the hot loop below inlines the same rules.)
local function faceVisible(b: number, n: number): boolean
	if n == 0 then
		return true
	end
	if isOpaque[n + 1] then
		return false
	end
	if n == b then
		return not cullSelf[b + 1]
	end
	-- Liquid next to another liquid: hide the seam (water/lava, water under ice is handled
	-- because ice is not liquid and therefore drawn).
	if isLiquid[b + 1] and isLiquid[n + 1] then
		return false
	end
	return true
end
GreedyMesher.faceVisible = faceVisible

local mask = table.create(SS * SS, 0)

-- Quick classification of a padded section so we can skip work:
--   "empty"   no blocks at all in the 16^3 interior
--   "buried"  interior and its 6 border layers are all opaque => no visible faces
--   "mesh"    needs meshing
function GreedyMesher.classify(padded: buffer): string
	local anyBlock = false
	local allOpaque = true
	for y = 1, P - 2 do
		for z = 1, P - 2 do
			local row = 1 + z * P + y * P2
			for x = 0, SS - 1 do
				local b = buffer.readu16(padded, (row + x) * 2)
				if b ~= 0 then
					anyBlock = true
				end
				if not isOpaque[b + 1] then
					allOpaque = false
				end
			end
		end
		if anyBlock and not allOpaque then
			return "mesh"
		end
	end
	if not anyBlock then
		return "empty"
	end
	-- interior fully opaque: check the 6 border faces of the padded volume
	for a = 1, P - 2 do
		for c = 1, P - 2 do
			if not isOpaque[buffer.readu16(padded, (0 + a * P + c * P2) * 2) + 1] -- x = 0
				or not isOpaque[buffer.readu16(padded, ((P - 1) + a * P + c * P2) * 2) + 1] -- x = 17
				or not isOpaque[buffer.readu16(padded, (a + 0 * P + c * P2) * 2) + 1] -- z = 0
				or not isOpaque[buffer.readu16(padded, (a + (P - 1) * P + c * P2) * 2) + 1] -- z = 17
				or not isOpaque[buffer.readu16(padded, (a + c * P + 0 * P2) * 2) + 1] -- y = 0
				or not isOpaque[buffer.readu16(padded, (a + c * P + (P - 1) * P2) * 2) + 1] -- y = 17
			then
				return "mesh"
			end
		end
	end
	return "buried"
end

-- Box-shaped blocks (slabs, stairs, fences, doors, ladders) ----------------------------------------
-- Each box face becomes one quad with fractional coordinates; the backend maps its texture by the
-- face's position inside the block (a slab side shows the lower half of the texture, like Java).
-- Faces on the cell boundary are hidden when the neighbour covers that whole face. Brightness:
-- the neighbour cell's light for boundary faces, the block's own cell for inner faces; no AO.
local OPP = { 2, 1, 4, 3, 6, 5 }
local glassPane: { [number]: boolean } = {}
for id, def in BlockRegistry.byId do
	if def.shape == "pane" and not def.state.bars then
		glassPane[id] = true
	end
end
local CURVE_REF: { number } = {}
local function emitShapes(padded: buffer, light: buffer?, groups: { [number]: { number } }): (number, number)
	local quads, faces = 0, 0
	for y = 0, SS - 1 do
		for z = 0, SS - 1 do
			for x = 0, SS - 1 do
				local p = (x + 1) + (z + 1) * P + (y + 1) * P2
				local b = buffer.readu16(padded, p * 2)
				if b ~= 0 and isBoxShape[b + 1] then
					local function get(dx: number, dy: number, dz: number): number?
						return buffer.readu16(padded, (p + dx + dz * P + dy * P2) * 2)
					end
					local own = if light then buffer.readu8(light, p) else 15
					for _, box in Shapes.boxes(b, get, false) do
						local lo = { box[1], box[2], box[3] }
						local hi = { box[4], box[5], box[6] }
						for d = 1, 6 do
							local dir = DIRS[d]
							local a = dir.axis + 1
							local onEdge = if dir.sign > 0 then hi[a] >= 1 else lo[a] <= 0
							local nOff = STRIDE[dir.axis] * dir.sign
							local visible = true
							if onEdge then
								local n = buffer.readu16(padded, (p + nOff) * 2)
								-- glass panes: no faces against each other or against a solid full block
								-- (glass included), or they'd show as lines through the glass
								if n ~= 0 and (Shapes.coversFace(n, OPP[d]) or (glassPane[b] and (n == b or Shapes.sturdyCube(n)))) then
									visible = false -- (glass panes in a row / stack: no seams between them)
								end
							end
							if visible then
								faces += 1
								local tex = box[7] or faceTex[b * 6 + d] -- a box may carry its own texture (bed legs)
								local list = groups[tex]
								if not list then
									list = {}
									groups[tex] = list
								end
								local base = { x, y, z }
								local plane = base[a] + (if dir.sign > 0 then hi[a] else lo[a])
								local ua, va = dir.u + 1, dir.v + 1
								local level = own
								if light and onEdge then
									local nl = buffer.readu8(light, p + nOff)
									local n = buffer.readu16(padded, (p + nOff) * 2)
									level = if isOpaque[n + 1] then own else nl
								end
								local bright = if light then math.floor(CURVE_REF[level * 4 + 1] * 255 + 0.5) else 255
								local nl = #list
								list[nl + 1] = d
								list[nl + 2] = if dir.sign > 0 then plane - 1 else plane
								list[nl + 3] = base[ua] + lo[ua]
								list[nl + 4] = base[va] + lo[va]
								list[nl + 5] = hi[ua] - lo[ua]
								list[nl + 6] = hi[va] - lo[va]
								list[nl + 7] = bright
								list[nl + 8] = bright
								list[nl + 9] = bright
								list[nl + 10] = bright
								quads += 1
							end
						end
					end
				end
			end
		end
	end
	return quads, faces
end

-- `padded` is a buffer filled by SectionSampler.fill. `checkpoint` (optional) is called after
-- each of the 6 directions so a time-sliced caller can yield.
function GreedyMesher.mesh(padded: buffer, checkpoint: (() -> ())?): MeshResult
	local groups: { [number]: { number } } = {}
	local quadCount, faceCount = 0, 0

	for d = 1, 6 do
		local dir = DIRS[d]
		local sA, sU, sV = STRIDE[dir.axis], STRIDE[dir.u], STRIDE[dir.v]
		local nOff = sA * dir.sign
		local texBase = d
		for k = 0, SS - 1 do
			-- Build the 16x16 visibility mask for this slice.
			local any = false
			local sliceBase = (k + 1) * sA + sU + sV
			local mi = 1
			for j = 0, SS - 1 do
				local p = sliceBase + j * sV
				for _ = 0, SS - 1 do
					local b = buffer.readu16(padded, p * 2)
					local m = 0
					if b ~= 0 and isCube[b + 1] then
						local n = buffer.readu16(padded, (p + nOff) * 2)
						-- inlined faceVisible(b, n)
						if n == 0 or (
							not isOpaque[n + 1]
							and (n ~= b or not cullSelf[b + 1])
							and not (n ~= b and isLiquid[b + 1] and isLiquid[n + 1])
						) then
							m = faceTex[b * 6 + texBase]
							faceCount += 1
							any = true
						end
					end
					mask[mi] = m
					mi += 1
					p += sU
				end
			end
			if any then
				-- Greedy merge rectangles of equal texture.
				for j = 0, SS - 1 do
					local row = j * SS + 1
					local i = 0
					while i < SS do
						local m = mask[row + i]
						if m == 0 then
							i += 1
						else
							local w = 1
							while i + w < SS and mask[row + i + w] == m do
								w += 1
							end
							local h = 1
							local grow = true
							while j + h < SS and grow do
								local r2 = row + h * SS + i
								for t = 0, w - 1 do
									if mask[r2 + t] ~= m then
										grow = false
										break
									end
								end
								if grow then
									h += 1
								end
							end
							for jj = 0, h - 1 do
								local r2 = row + jj * SS + i
								for t = 0, w - 1 do
									mask[r2 + t] = 0
								end
							end
							local list = groups[m]
							if not list then
								list = {}
								groups[m] = list
							end
							local n = #list
							list[n + 1] = d
							list[n + 2] = k
							list[n + 3] = i
							list[n + 4] = j
							list[n + 5] = w
							list[n + 6] = h
							list[n + 7] = 255
							list[n + 8] = 255
							list[n + 9] = 255
							list[n + 10] = 255
							quadCount += 1
							i += w
						end
					end
				end
			end
		end
		if checkpoint then
			checkpoint()
		end
	end

	local sq, sf = emitShapes(padded, nil, groups)
	return { groups = groups, quadCount = quadCount + sq, faceCount = faceCount + sf }
end

-- Lit, per-face meshing ------------------------------------------------------------------------

-- Java-like light curve (level 0..15 -> 0..1) with the default brightness setting's lift, and a
-- small floor so pitch-black caves still show a hint of shape.
local CURVE = table.create(16 * 4 + 1, 0)
for i = 0, 60 do
	local l = i / 4 -- quarter-level steps (corner averages)
	local f = l / 15
	local base = f / (4 - 3 * f)
	local v = base * 0.5 + (1 - (1 - base) ^ 4) * 0.5
	CURVE[i + 1] = 0.035 + 0.965 * v
end
CURVE_REF = CURVE
-- Ambient occlusion factor by number of occluders around a corner (0 = fully enclosed).
local AO = { [0] = 0.5, [1] = 0.66, [2] = 0.82, [3] = 1.0 }
-- corner -> (sign along u, sign along v), matching quadCorners order
local CU = { -1, 1, 1, -1 }
local CV = { -1, -1, 1, 1 }

-- `light`: 18^3 padded max(sky, block) levels (LightEngine.fillPadded). `merge`: textures that
-- are merged instead (see-through specials). Faces of non-cube blocks (torches) are skipped.
function GreedyMesher.meshLit(padded: buffer, light: buffer, merge: { [number]: boolean }, checkpoint: (() -> ())?): MeshResult
	local groups: { [number]: { number } } = {}
	local quadCount, faceCount = 0, 0
	for d = 1, 6 do
		local dir = DIRS[d]
		local sA, sU, sV = STRIDE[dir.axis], STRIDE[dir.u], STRIDE[dir.v]
		local nOff = sA * dir.sign
		for k = 0, SS - 1 do
			local any = false
			local sliceBase = (k + 1) * sA + sU + sV
			local mi = 1
			for j = 0, SS - 1 do
				local p = sliceBase + j * sV
				for i = 0, SS - 1 do
					local b = buffer.readu16(padded, p * 2)
					local m = 0
					if b ~= 0 and isCube[b + 1] then
						local n = buffer.readu16(padded, (p + nOff) * 2)
						if n == 0 or (
							not isOpaque[n + 1]
							and (n ~= b or not cullSelf[b + 1])
							and not (n ~= b and isLiquid[b + 1] and isLiquid[n + 1])
						) then
							local tex = faceTex[b * 6 + d]
							faceCount += 1
							if merge[tex] then
								m = tex
								any = true
							else
								-- one lit quad for this face
								local q = p + nOff
								local list = groups[tex]
								if not list then
									list = {}
									groups[tex] = list
								end
								local nl = #list
								list[nl + 1] = d
								list[nl + 2] = k
								list[nl + 3] = i
								list[nl + 4] = j
								list[nl + 5] = 1
								list[nl + 6] = 1
								local centre = buffer.readu8(light, q)
								for c = 1, 4 do
									local o1 = q + CU[c] * sU
									local o2 = q + CV[c] * sV
									local oc = o1 + CV[c] * sV
									local s1 = isOpaque[buffer.readu16(padded, o1 * 2) + 1]
									local s2 = isOpaque[buffer.readu16(padded, o2 * 2) + 1]
									local sc = isOpaque[buffer.readu16(padded, oc * 2) + 1]
									local ao
									if s1 and s2 then
										ao = 0
									else
										ao = 3 - ((if s1 then 1 else 0) + (if s2 then 1 else 0) + (if sc then 1 else 0))
									end
									local sum, cnt = centre, 1
									if not s1 then
										sum += buffer.readu8(light, o1)
										cnt += 1
									end
									if not s2 then
										sum += buffer.readu8(light, o2)
										cnt += 1
									end
									if not sc and not (s1 and s2) then
										sum += buffer.readu8(light, oc)
										cnt += 1
									end
									local level4 = math.floor(sum / cnt * 4 + 0.5)
									list[nl + 6 + c] = math.floor(CURVE[level4 + 1] * AO[ao] * 255 + 0.5)
								end
								quadCount += 1
							end
						end
					end
					mask[mi] = m
					mi += 1
					p += sU
				end
			end
			if any then
				for j = 0, SS - 1 do
					local row = j * SS + 1
					local i = 0
					while i < SS do
						local m = mask[row + i]
						if m == 0 then
							i += 1
						else
							local w = 1
							while i + w < SS and mask[row + i + w] == m do
								w += 1
							end
							local h = 1
							local grow = true
							while j + h < SS and grow do
								local r2 = row + h * SS + i
								for t = 0, w - 1 do
									if mask[r2 + t] ~= m then
										grow = false
										break
									end
								end
								if grow then
									h += 1
								end
							end
							for jj = 0, h - 1 do
								local r2 = row + jj * SS + i
								for t = 0, w - 1 do
									mask[r2 + t] = 0
								end
							end
							-- uniform brightness from the light in front of the first face
							local pFront = (k + 1) * sA + sU + sV + j * sV + i * sU + nOff
							local bright = math.floor(CURVE[buffer.readu8(light, pFront) * 4 + 1] * 255 + 0.5)
							local list = groups[m]
							if not list then
								list = {}
								groups[m] = list
							end
							local n = #list
							list[n + 1] = d
							list[n + 2] = k
							list[n + 3] = i
							list[n + 4] = j
							list[n + 5] = w
							list[n + 6] = h
							list[n + 7] = bright
							list[n + 8] = bright
							list[n + 9] = bright
							list[n + 10] = bright
							quadCount += 1
							i += w
						end
					end
				end
			end
		end
		if checkpoint then
			checkpoint()
		end
	end
	local sq, sf = emitShapes(padded, light, groups)
	return { groups = groups, quadCount = quadCount + sq, faceCount = faceCount + sf }
end

-- Corner positions (section-local block units) of a quad, in counter-clockwise order seen from
-- the side the normal points to. Returns 12 numbers: x0,y0,z0, x1,y1,z1, x2,y2,z2, x3,y3,z3.
-- Triangles are (0,1,2) and (0,2,3).
function GreedyMesher.quadCorners(d: number, k: number, i: number, j: number, w: number, h: number): { number }
	local dir = DIRS[d]
	local plane = if dir.sign > 0 then k + 1 else k
	local base = { 0, 0, 0 }
	base[dir.axis + 1] = plane
	base[dir.u + 1] = i
	base[dir.v + 1] = j
	local du = { 0, 0, 0 }
	du[dir.u + 1] = w
	local dv = { 0, 0, 0 }
	dv[dir.v + 1] = h
	return {
		base[1], base[2], base[3],
		base[1] + du[1], base[2] + du[2], base[3] + du[3],
		base[1] + du[1] + dv[1], base[2] + du[2] + dv[2], base[3] + du[3] + dv[3],
		base[1] + dv[1], base[2] + dv[2], base[3] + dv[3],
	}
end

return GreedyMesher
