--!strict
--!native
-- Kinematic box-vs-voxel movement for mobs (pure; the server has no terrain physics).
-- A mob is an axis-aligned box: feet centre (x, y, z), `w` wide (x and z), `h` tall, all in block
-- units. Movement is resolved one axis at a time (Y, X, Z) in sub-steps of at most 0.4 blocks so
-- nothing tunnels through a block.

local MobPhysics = {}

local EPS = 1e-3

export type SolidFn = (x: number, y: number, z: number) -> boolean

function MobPhysics.collides(solid: SolidFn, x: number, y: number, z: number, w: number, h: number): boolean
	local hw = w / 2 - EPS
	for by = math.floor(y + EPS), math.floor(y + h - EPS) do
		for bz = math.floor(z - hw), math.floor(z + hw) do
			for bx = math.floor(x - hw), math.floor(x + hw) do
				if solid(bx, by, bz) then
					return true
				end
			end
		end
	end
	return false
end

-- Move by velocity * dt. Returns new position, new velocity, onGround, hitWall.
function MobPhysics.move(
	solid: SolidFn,
	x: number, y: number, z: number,
	vx: number, vy: number, vz: number,
	w: number, h: number, dt: number
): (number, number, number, number, number, number, boolean, boolean)
	local onGround, hitWall = false, false
	local maxStep = math.max(math.abs(vx), math.abs(vy), math.abs(vz)) * dt
	local steps = math.max(1, math.ceil(maxStep / 0.4))
	local sdt = dt / steps
	for _ = 1, steps do
		-- Y
		if vy ~= 0 then
			local ny = y + vy * sdt
			if MobPhysics.collides(solid, x, ny, z, w, h) then
				if vy < 0 then
					ny = math.floor(ny) + 1 -- land on the block top
					onGround = true
				else
					ny = math.floor(ny + h) - h - EPS -- bump the head
				end
				if MobPhysics.collides(solid, x, ny, z, w, h) then
					ny = y -- couldn't resolve; stay
				end
				vy = 0
			end
			y = ny
		end
		-- X
		if vx ~= 0 then
			local nx = x + vx * sdt
			if MobPhysics.collides(solid, nx, y, z, w, h) then
				nx = if vx > 0 then math.floor(nx + w / 2) - w / 2 - EPS else math.floor(nx - w / 2) + 1 + w / 2 + EPS
				if MobPhysics.collides(solid, nx, y, z, w, h) then
					nx = x
				end
				vx = 0
				hitWall = true
			end
			x = nx
		end
		-- Z
		if vz ~= 0 then
			local nz = z + vz * sdt
			if MobPhysics.collides(solid, x, y, nz, w, h) then
				nz = if vz > 0 then math.floor(nz + w / 2) - w / 2 - EPS else math.floor(nz - w / 2) + 1 + w / 2 + EPS
				if MobPhysics.collides(solid, x, y, nz, w, h) then
					nz = z
				end
				vz = 0
				hitWall = true
			end
			z = nz
		end
	end
	-- standing on something? (also true when not moving vertically)
	if not onGround then
		onGround = MobPhysics.collides(solid, x, y - 0.02, z, w, h)
	end
	return x, y, z, vx, vy, vz, onGround, hitWall
end

return MobPhysics
