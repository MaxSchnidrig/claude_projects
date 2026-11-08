--!strict
--!native
-- Builds an 18x18x18 "padded" copy of one 16^3 section: the section plus a 1-block border taken
-- from the neighbouring chunks/sections. Meshing then never has to branch on chunk borders.
--
-- Padded index: px + pz * 18 + py * 324, with p = local + 1 (so local -1 .. 16 maps to 0 .. 17).

local Shared = script.Parent.Parent
local Config = require(Shared.Config)

local CS = Config.CHUNK_SIZE
local H = Config.WORLD_HEIGHT
local SS = Config.SECTION_SIZE
local LAYER = CS * CS
local P = SS + 2
local P2 = P * P

local SectionSampler = {}
SectionSampler.SIZE = P
SectionSampler.VOLUME = P * P * P
SectionSampler.BYTES = P * P * P * 2 -- block ids are u16: padded block buffers are this many bytes

-- Block id used for missing neighbours / below the world: opaque, so border faces are culled.
local BORDER_SOLID = 1 -- stone

export type Neighbors = { east: any?, west: any?, south: any?, north: any? }

local function idx(px: number, py: number, pz: number): number
	return px + pz * P + py * P2
end
SectionSampler.index = idx

-- Writes into `out` (a buffer of SectionSampler.BYTES bytes, one u16 id per cell, reused between calls).
function SectionSampler.fill(out: buffer, chunk: any, nb: Neighbors, sectionY: number)
	local blocks: buffer = chunk.blocks
	local y0 = sectionY * SS
	buffer.fill(out, 0, 0)

	for py = 0, P - 1 do
		local y = y0 + py - 1
		if y < 0 then
			-- below the world: treat as solid so the underside of bedrock is never drawn
			for pz = 0, P - 1 do
				for px = 0, P - 1 do
					buffer.writeu16(out, (idx(px, py, pz)) * 2, BORDER_SOLID)
				end
			end
		elseif y < H then
			local rowBase = y * LAYER
			-- interior 16x16 plus the 4 edge strips
			for lz = 0, CS - 1 do
				local src = rowBase + lz * CS
				local dst = idx(1, py, lz + 1)
				buffer.copy(out, dst * 2, blocks, src * 2, CS * 2)
			end
			local e, w, s, n = nb.east, nb.west, nb.south, nb.north
			for l = 0, CS - 1 do
				buffer.writeu16(out, (idx(P - 1, py, l + 1)) * 2, if e then buffer.readu16(e.blocks, (rowBase + l * CS) * 2) else BORDER_SOLID)
				buffer.writeu16(out, (idx(0, py, l + 1)) * 2, if w then buffer.readu16(w.blocks, (rowBase + l * CS + (CS - 1)) * 2) else BORDER_SOLID)
				buffer.writeu16(out, (idx(l + 1, py, P - 1)) * 2, if s then buffer.readu16(s.blocks, (rowBase + l) * 2) else BORDER_SOLID)
				buffer.writeu16(out, (idx(l + 1, py, 0)) * 2, if n then buffer.readu16(n.blocks, (rowBase + (CS - 1) * CS + l) * 2) else BORDER_SOLID)
			end
		end
		-- y >= H stays 0 (air above the world)
	end
end

return SectionSampler
