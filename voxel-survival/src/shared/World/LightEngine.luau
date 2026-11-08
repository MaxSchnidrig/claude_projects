--!strict
--!native
-- Block and sky light, Java-style levels 0..15 (pure; tested headless; runs on the client).
--
-- Each lit chunk gets `chunk.light`: one byte per block, sky level in the high nibble, block
-- (torch/lava) level in the low nibble. Rules:
--   * sky light enters every column at 15 and goes straight down without loss through clear
--     blocks (air, glass, torches); blocks with opacity 1 (leaves, water, ice) take 1 off;
--     opaque blocks stop it
--   * from there both kinds spread to the 6 neighbours, losing max(1, opacity) per step
--   * light sources (BlockRegistry.lightEmission) start at their level
-- Edits update light incrementally (remove-then-refill flood), also across chunk borders, and
-- report every block whose light changed so the renderer can rebuild those sections.
--
-- Chunks without data or not yet lit are walls of darkness: light simply doesn't flow there
-- until they are lit (their own pass then pulls light in from lit neighbours).

local Shared = script.Parent.Parent
local Config = require(Shared.Config)
local BlockRegistry = require(Shared.Blocks.BlockRegistry)

local CS = Config.CHUNK_SIZE
local H = Config.WORLD_HEIGHT
local LAYER = CS * CS
local VOLUME = LAYER * H

local opacity = BlockRegistry.lightOpacity -- indexed id + 1
local emission = BlockRegistry.lightEmission

export type Engine = {
	getChunk: (cx: number, cz: number) -> any?,
	onChanged: (wx: number, wy: number, wz: number) -> (),
}

local LightEngine = {}
LightEngine.__index = LightEngine

function LightEngine.new(getChunk: (cx: number, cz: number) -> any?, onChanged: (wx: number, wy: number, wz: number) -> ()): Engine
	return setmetatable({ getChunk = getChunk, onChanged = onChanged }, LightEngine) :: any
end

-- Queues: parallel arrays of world x, y, z and a level.
type Queue = { x: { number }, y: { number }, z: { number }, l: { number }, n: number }
local function newQueue(): Queue
	return { x = {}, y = {}, z = {}, l = {}, n = 0 }
end
local function push(q: Queue, x: number, y: number, z: number, l: number)
	local n = q.n + 1
	q.n = n
	q.x[n], q.y[n], q.z[n], q.l[n] = x, y, z, l
end

local DX = { 1, -1, 0, 0, 0, 0 }
local DY = { 0, 0, 1, -1, 0, 0 }
local DZ = { 0, 0, 0, 0, 1, -1 }
local DOWN = 4

-- Locate a block: (chunk, index) or nil if its chunk isn't lit.
local function locate(self: Engine, wx: number, wy: number, wz: number): (any?, number)
	if wy < 0 or wy >= H then
		return nil, 0
	end
	local cx, cz = wx // CS, wz // CS
	local chunk = self.getChunk(cx, cz)
	if not chunk or not chunk.light then
		return nil, 0
	end
	return chunk, (wx - cx * CS) + (wz - cz * CS) * CS + wy * LAYER
end

-- Flood one channel (sky = true: high nibble) from the queued cells.
local function spread(self: Engine, q: Queue, sky: boolean, checkpoint: (() -> ())?)
	local i = 1
	while i <= q.n do
		if checkpoint and i % 4096 == 0 then
			checkpoint()
		end
		local x, y, z = q.x[i], q.y[i], q.z[i]
		i += 1
		local chunk, idx = locate(self, x, y, z)
		if chunk then
			local v = buffer.readu8(chunk.light, idx)
			local level = if sky then v // 16 else v % 16
			if level > 1 then
				for d = 1, 6 do
					local nx, ny, nz = x + DX[d], y + DY[d], z + DZ[d]
					local nchunk, nidx = locate(self, nx, ny, nz)
					if nchunk then
						local id = buffer.readu16(nchunk.blocks, nidx * 2)
						local op = opacity[id + 1]
						if op < 15 then
							local new
							if sky and d == DOWN and level == 15 and op == 0 then
								new = 15
							else
								new = level - math.max(1, op)
							end
							local nv = buffer.readu8(nchunk.light, nidx)
							local cur = if sky then nv // 16 else nv % 16
							if new > cur then
								buffer.writeu8(nchunk.light, nidx, if sky then new * 16 + nv % 16 else nv - cur + new)
								push(q, nx, ny, nz, new)
								self.onChanged(nx, ny, nz)
							end
						end
					end
				end
			end
		end
	end
end

-- Light a freshly loaded chunk (its blocks are final: generated + saved edits applied), pulling
-- in light from lit neighbours and pushing ours into them.
function LightEngine.lightChunk(self: Engine, chunk: any, checkpoint: (() -> ())?)
	local light = buffer.create(VOLUME)
	chunk.light = light
	local blocks: buffer = chunk.blocks
	local x0, z0 = chunk.cx * CS, chunk.cz * CS
	local skyQ, blockQ = newQueue(), newQueue()

	-- sky columns. top[c] = lowest y that still has full sky (15) straight from above; cells
	-- below it that keep some sky (under leaves / water) are queued directly.
	local top = table.create(LAYER, H)
	for lz = 0, CS - 1 do
		for lx = 0, CS - 1 do
			local level = 15
			local col = lx + lz * CS
			local full = H
			for y = H - 1, 0, -1 do
				local idx = col + y * LAYER
				local op = opacity[buffer.readu16(blocks, idx * 2) + 1]
				if op >= 15 then
					break
				end
				level = math.max(0, level - op)
				if level == 0 then
					break
				end
				buffer.writeu8(light, idx, level * 16)
				if level == 15 then
					full = y
				elseif level > 1 then
					push(skyQ, x0 + lx, y, z0 + lz, level)
				end
			end
			top[col + 1] = full
		end
	end
	if checkpoint then
		checkpoint()
	end
	-- Full-sky cells only need to spread sideways where a neighbouring column is darker at the
	-- same height, i.e. between this column's top and the neighbour's top.
	local function neighbourTop(lx: number, lz: number): number
		if lx >= 0 and lz >= 0 and lx < CS and lz < CS then
			return top[lx + lz * CS + 1]
		end
		local nchunk, nidx = locate(self, x0 + lx, H - 1, z0 + lz)
		if not nchunk then
			return 0 -- not lit: it pulls light from us when it is
		end
		local nl: buffer = nchunk.light
		local colBase = nidx - (H - 1) * LAYER
		local y = H - 1
		while y >= 0 and buffer.readu8(nl, colBase + y * LAYER) // 16 == 15 do
			y -= 1
		end
		return y + 1
	end
	for lz = 0, CS - 1 do
		for lx = 0, CS - 1 do
			local own = top[lx + lz * CS + 1]
			local hi = math.max(neighbourTop(lx + 1, lz), neighbourTop(lx - 1, lz), neighbourTop(lx, lz + 1), neighbourTop(lx, lz - 1))
			for y = own, math.min(hi, H) - 1 do
				push(skyQ, x0 + lx, y, z0 + lz, 15)
			end
		end
	end
	-- light sources
	for i = 0, VOLUME - 1 do
		local e = emission[buffer.readu16(blocks, i * 2) + 1]
		if e > 0 then
			local v = buffer.readu8(light, i)
			buffer.writeu8(light, i, (v // 16) * 16 + e)
			local y = i // LAYER
			local r = i - y * LAYER
			push(blockQ, x0 + r % CS, y, z0 + r // CS, e)
		end
	end
	-- light already in lit neighbours flows in across the border
	local borders = {
		{ dcx = 1, dcz = 0, lx = 0, lz = nil },
		{ dcx = -1, dcz = 0, lx = CS - 1, lz = nil },
		{ dcx = 0, dcz = 1, lx = nil, lz = 0 },
		{ dcx = 0, dcz = -1, lx = nil, lz = CS - 1 },
	}
	for _, b in borders do
		local nb = self.getChunk(chunk.cx + b.dcx, chunk.cz + b.dcz)
		if nb and nb.light then
			local nx0, nz0 = nb.cx * CS, nb.cz * CS
			for y = 0, H - 1 do
				for t = 0, CS - 1 do
					local lx = b.lx or t
					local lz = b.lz or t
					local v = buffer.readu8(nb.light, lx + lz * CS + y * LAYER)
					if v // 16 > 1 then
						push(skyQ, nx0 + lx, y, nz0 + lz, v // 16)
					end
					if v % 16 > 1 then
						push(blockQ, nx0 + lx, y, nz0 + lz, v % 16)
					end
				end
			end
		end
	end
	spread(self, skyQ, true, checkpoint)
	spread(self, blockQ, false, checkpoint)
end

-- Remove light of one channel flowing from (x, y, z), then refill from the boundary.
local function relight(self: Engine, x: number, y: number, z: number, sky: boolean)
	local chunk, idx = locate(self, x, y, z)
	if not chunk then
		return
	end
	local removeQ, addQ = newQueue(), newQueue()
	local v = buffer.readu8(chunk.light, idx)
	local old = if sky then v // 16 else v % 16
	buffer.writeu8(chunk.light, idx, if sky then v % 16 else v - old)
	self.onChanged(x, y, z)
	push(removeQ, x, y, z, old)
	local i = 1
	while i <= removeQ.n do
		local cx, cy, cz, level = removeQ.x[i], removeQ.y[i], removeQ.z[i], removeQ.l[i]
		i += 1
		for d = 1, 6 do
			local nx, ny, nz = cx + DX[d], cy + DY[d], cz + DZ[d]
			local nchunk, nidx = locate(self, nx, ny, nz)
			if nchunk then
				local nv = buffer.readu8(nchunk.light, nidx)
				local nl = if sky then nv // 16 else nv % 16
				if nl > 0 and (nl < level or (sky and d == DOWN and level == 15 and nl == 15)) then
					buffer.writeu8(nchunk.light, nidx, if sky then nv % 16 else nv - nl)
					self.onChanged(nx, ny, nz)
					push(removeQ, nx, ny, nz, nl)
				elseif nl > 0 then
					push(addQ, nx, ny, nz, nl) -- lit from elsewhere: it refills the gap
				end
			end
		end
	end
	-- the changed block's own light: sources glow, open sky from above comes straight down
	local here, hidx = locate(self, x, y, z)
	if here then
		local id = buffer.readu16(here.blocks, hidx * 2)
		local hv = buffer.readu8(here.light, hidx)
		if sky then
			local above = 0
			if y + 1 >= H then
				above = 15
			else
				local achunk, aidx = locate(self, x, y + 1, z)
				above = if achunk then buffer.readu8(achunk.light, aidx) // 16 else 0
			end
			local op = opacity[id + 1]
			if above == 15 and op < 15 then
				local l = math.max(0, 15 - op)
				buffer.writeu8(here.light, hidx, l * 16 + hv % 16)
				push(addQ, x, y, z, l)
			end
		else
			local e = emission[id + 1]
			if e > 0 then
				buffer.writeu8(here.light, hidx, (hv // 16) * 16 + e)
				push(addQ, x, y, z, e)
			end
		end
		self.onChanged(x, y, z)
	end
	-- neighbours refill this block if it lets light through now
	for d = 1, 6 do
		local nx, ny, nz = x + DX[d], y + DY[d], z + DZ[d]
		local nchunk, nidx = locate(self, nx, ny, nz)
		if nchunk then
			local nv = buffer.readu8(nchunk.light, nidx)
			local nl = if sky then nv // 16 else nv % 16
			if nl > 1 then
				push(addQ, nx, ny, nz, nl)
			end
		end
	end
	spread(self, addQ, sky)
end

-- A block changed (the chunk's block buffer already holds the new id).
function LightEngine.blockChanged(self: Engine, wx: number, wy: number, wz: number)
	relight(self, wx, wy, wz, true)
	relight(self, wx, wy, wz, false)
end

-- Levels at a block: (sky, block). Unlit or missing chunks read as (15, 0) above ground level
-- would be wrong underground, so callers only ask for lit chunks; (0, 0) otherwise.
function LightEngine.get(self: Engine, wx: number, wy: number, wz: number): (number, number)
	if wy >= H then
		return 15, 0
	end
	local chunk, idx = locate(self, wx, wy, wz)
	if not chunk then
		return 0, 0
	end
	local v = buffer.readu8(chunk.light, idx)
	return v // 16, v % 16
end

-- 18^3 padded light around one section (same layout as SectionSampler): byte = max(sky, block).
-- Cells in chunks that aren't lit copy the nearest lit cell inside the section's chunk.
local P = Config.SECTION_SIZE + 2
local P2 = P * P
function LightEngine.fillPadded(self: Engine, out: buffer, chunk: any, sectionY: number)
	local x0, z0 = chunk.cx * CS, chunk.cz * CS
	local y0 = sectionY * Config.SECTION_SIZE
	for py = 0, P - 1 do
		local y = y0 + py - 1
		for pz = 0, P - 1 do
			for px = 0, P - 1 do
				local value
				if y >= H then
					value = 15
				elseif y < 0 then
					value = 0
				else
					local wx, wz = x0 + px - 1, z0 + pz - 1
					local c, idx = locate(self, wx, y, wz)
					if not c then
						c, idx = locate(self, math.clamp(wx, x0, x0 + CS - 1), y, math.clamp(wz, z0, z0 + CS - 1))
					end
					if c then
						local v = buffer.readu8(c.light, idx)
						value = math.max(v // 16, v % 16)
					else
						value = 15
					end
				end
				buffer.writeu8(out, px + pz * P + py * P2, value)
			end
		end
	end
end

return LightEngine
