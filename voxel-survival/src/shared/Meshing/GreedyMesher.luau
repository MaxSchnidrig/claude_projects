--!strict
--!native
-- Face-culled greedy mesher (Mikola Lysenko's algorithm) for one 16^3 section.
--
-- Output: quads grouped by texture index. Each quad is 6 numbers in a flat array:
--     dir, k, i, j, w, h
-- dir  1..6 (BlockRegistry.Dir), k = slice along the face normal axis, (i, j) = start on the
-- face's (u, v) axes, (w, h) = size along (u, v). All in section-local block units.
--
-- Merging only joins faces with the same texture, which lets a backend tile one texture over a
-- whole merged quad (see ARCHITECTURE.md, "why one MeshPart per texture").

local Shared = script.Parent.Parent
local Config = require(Shared.Config)
local BlockRegistry = require(Shared.Blocks.BlockRegistry)
local SectionSampler = require(script.Parent.SectionSampler)

local SS = Config.SECTION_SIZE
local P = SectionSampler.SIZE
local P2 = P * P

local isOpaque = BlockRegistry.isOpaque
local isLiquid = BlockRegistry.isLiquid
local cullSelf = BlockRegistry.cullSelf

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
				local b = buffer.readu8(padded, row + x)
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
			if not isOpaque[buffer.readu8(padded, 0 + a * P + c * P2) + 1] -- x = 0
				or not isOpaque[buffer.readu8(padded, (P - 1) + a * P + c * P2) + 1] -- x = 17
				or not isOpaque[buffer.readu8(padded, a + 0 * P + c * P2) + 1] -- z = 0
				or not isOpaque[buffer.readu8(padded, a + (P - 1) * P + c * P2) + 1] -- z = 17
				or not isOpaque[buffer.readu8(padded, a + c * P + 0 * P2) + 1] -- y = 0
				or not isOpaque[buffer.readu8(padded, a + c * P + (P - 1) * P2) + 1] -- y = 17
			then
				return "mesh"
			end
		end
	end
	return "buried"
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
					local b = buffer.readu8(padded, p)
					local m = 0
					if b ~= 0 then
						local n = buffer.readu8(padded, p + nOff)
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

	return { groups = groups, quadCount = quadCount, faceCount = faceCount }
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
