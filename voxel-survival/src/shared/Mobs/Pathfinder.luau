--!strict
--!native
-- A* over walkable voxel cells (pure). A cell (x, y, z) is walkable for a mob `height` blocks
-- tall when the block below is solid and `height` blocks from y up are free. Moves: the 4
-- horizontal neighbours on the same level, one block up (needs headroom), or down up to
-- `maxDrop` blocks. If the goal can't be reached within `maxNodes` expansions, the path to the
-- explored cell closest to the goal is returned, so mobs still get closer.

export type SolidFn = (x: number, y: number, z: number) -> boolean
export type Opts = { height: number, maxNodes: number?, maxDrop: number? }

local Pathfinder = {}

local function key(x: number, y: number, z: number): number
	return ((x + 65536) * 512 + (y + 128)) * 131072 + (z + 65536)
end

-- tiny binary heap of {f, key}
local function push(heap: { { number } }, f: number, k: number)
	table.insert(heap, { f, k })
	local i = #heap
	while i > 1 do
		local p = i // 2
		if heap[p][1] <= heap[i][1] then
			break
		end
		heap[p], heap[i] = heap[i], heap[p]
		i = p
	end
end
local function pop(heap: { { number } }): { number }?
	local n = #heap
	if n == 0 then
		return nil
	end
	local top = heap[1]
	heap[1] = heap[n]
	heap[n] = nil
	n -= 1
	local i = 1
	while true do
		local l, r = i * 2, i * 2 + 1
		local m = i
		if l <= n and heap[l][1] < heap[m][1] then
			m = l
		end
		if r <= n and heap[r][1] < heap[m][1] then
			m = r
		end
		if m == i then
			break
		end
		heap[m], heap[i] = heap[i], heap[m]
		i = m
	end
	return top
end

function Pathfinder.walkable(solid: SolidFn, x: number, y: number, z: number, height: number): boolean
	if not solid(x, y - 1, z) then
		return false
	end
	for dy = 0, height - 1 do
		if solid(x, y + dy, z) then
			return false
		end
	end
	return true
end

local DIRS = { { 1, 0 }, { -1, 0 }, { 0, 1 }, { 0, -1 } }

-- Returns a list of cells { {x, y, z}, ... } from just after start to the goal (or as close as
-- possible), and whether the goal itself was reached.
function Pathfinder.find(solid: SolidFn, sx: number, sy: number, sz: number, gx: number, gy: number, gz: number, opts: Opts): ({ { number } }?, boolean)
	local height = opts.height
	local maxNodes = opts.maxNodes or 300
	local maxDrop = opts.maxDrop or 3
	local function h(x: number, y: number, z: number): number
		return math.abs(x - gx) + math.abs(y - gy) + math.abs(z - gz)
	end
	local startK = key(sx, sy, sz)
	local cells: { [number]: { number } } = { [startK] = { sx, sy, sz } }
	local g: { [number]: number } = { [startK] = 0 }
	local came: { [number]: number } = {}
	local closed: { [number]: boolean } = {}
	local heap = {}
	push(heap, h(sx, sy, sz), startK)
	local bestK, bestH = startK, h(sx, sy, sz)
	local expanded = 0
	local reached = false

	while true do
		local top = pop(heap)
		if not top then
			break
		end
		local k = top[2]
		if not closed[k] then
			closed[k] = true
			local c = cells[k]
			local x, y, z = c[1], c[2], c[3]
			local hc = h(x, y, z)
			if hc < bestH then
				bestK, bestH = k, hc
			end
			if x == gx and z == gz and math.abs(y - gy) <= 1 then
				bestK = k
				reached = true
				break
			end
			expanded += 1
			if expanded >= maxNodes then
				break
			end
			for _, d in DIRS do
				local nx, nz = x + d[1], z + d[2]
				local ny: number? = nil
				local cost = 1
				if Pathfinder.walkable(solid, nx, y, nz, height) then
					ny = y
				elseif Pathfinder.walkable(solid, nx, y + 1, nz, height) and not solid(x, y + height, z) then
					ny, cost = y + 1, 2 -- step up (needs headroom above the current cell)
				else
					-- step off the ledge: the neighbour column must be open at our level...
					local open = true
					for dy = 0, height - 1 do
						if solid(nx, y + dy, nz) then
							open = false
							break
						end
					end
					-- ...then fall until the first floor, at most maxDrop blocks down
					if open then
						for land = y - 1, y - maxDrop, -1 do
							if solid(nx, land, nz) then
								break -- (the floor would be at `land`, i.e. same level: not a drop)
							end
							if solid(nx, land - 1, nz) then
								ny, cost = land, 1 + (y - land) * 0.5
								break
							end
						end
					end
				end
				if ny then
					local nk = key(nx, ny :: number, nz)
					local ng = g[k] + cost
					if not closed[nk] and (g[nk] == nil or ng < g[nk]) then
						g[nk] = ng
						came[nk] = k
						cells[nk] = { nx, ny :: number, nz }
						push(heap, ng + h(nx, ny :: number, nz), nk)
					end
				end
			end
		end
	end

	if bestK == startK then
		return nil, reached
	end
	local path = {}
	local k = bestK
	while k ~= startK do
		table.insert(path, 1, cells[k])
		k = came[k]
	end
	return path, reached
end

return Pathfinder
