--!strict
--!native
-- Voxel grid raycast (Amanatides & Woo). Exact, cheap, and identical on server and client, so
-- block targeting (client) and line-of-sight validation (server) agree.
--
-- All coordinates are in BLOCK units (studs / Config.BLOCK_SIZE).

export type Hit = {
	x: number,
	y: number,
	z: number, -- the block that was hit
	nx: number,
	ny: number,
	nz: number, -- face normal (which side was entered); 0,0,0 if the ray started inside
	distance: number, -- along the ray, in blocks
	id: number,
}

local VoxelRaycast = {}

-- `getBlock(x, y, z)` returns a block id, or nil if unknown (unloaded) which stops the ray.
-- `stopsAt(id)` decides what counts as a hit (e.g. solid, or "not air and not liquid").
function VoxelRaycast.cast(
	getBlock: (number, number, number) -> number?,
	ox: number, oy: number, oz: number,
	dx: number, dy: number, dz: number,
	maxDist: number,
	stopsAt: (number) -> boolean
): Hit?
	local len = math.sqrt(dx * dx + dy * dy + dz * dz)
	if len < 1e-9 then
		return nil
	end
	dx, dy, dz = dx / len, dy / len, dz / len

	local x, y, z = math.floor(ox), math.floor(oy), math.floor(oz)
	local stepX = if dx > 0 then 1 elseif dx < 0 then -1 else 0
	local stepY = if dy > 0 then 1 elseif dy < 0 then -1 else 0
	local stepZ = if dz > 0 then 1 elseif dz < 0 then -1 else 0
	local INF = math.huge
	local tDeltaX = if stepX ~= 0 then math.abs(1 / dx) else INF
	local tDeltaY = if stepY ~= 0 then math.abs(1 / dy) else INF
	local tDeltaZ = if stepZ ~= 0 then math.abs(1 / dz) else INF
	local tMaxX = if stepX > 0 then (x + 1 - ox) * tDeltaX elseif stepX < 0 then (ox - x) * tDeltaX else INF
	local tMaxY = if stepY > 0 then (y + 1 - oy) * tDeltaY elseif stepY < 0 then (oy - y) * tDeltaY else INF
	local tMaxZ = if stepZ > 0 then (z + 1 - oz) * tDeltaZ elseif stepZ < 0 then (oz - z) * tDeltaZ else INF

	local nx, ny, nz = 0, 0, 0
	local t = 0
	while t <= maxDist do
		local id = getBlock(x, y, z)
		if id == nil then
			return nil
		end
		if stopsAt(id) then
			return { x = x, y = y, z = z, nx = nx, ny = ny, nz = nz, distance = t, id = id }
		end
		if tMaxX < tMaxY and tMaxX < tMaxZ then
			x += stepX
			t = tMaxX
			tMaxX += tDeltaX
			nx, ny, nz = -stepX, 0, 0
		elseif tMaxY < tMaxZ then
			y += stepY
			t = tMaxY
			tMaxY += tDeltaY
			nx, ny, nz = 0, -stepY, 0
		else
			z += stepZ
			t = tMaxZ
			tMaxZ += tDeltaZ
			nx, ny, nz = 0, 0, -stepZ
		end
	end
	return nil
end

return VoxelRaycast
