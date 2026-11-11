--!strict
--!native
-- Box-vs-block collision for everything that moves on the voxel grid: the player
-- (Gameplay/PlayerMotor), mobs, falling blocks and TNT. Pure; no Roblox instances.
--
-- An entity is an axis-aligned box in block units. Movement is resolved like Java's
-- Entity.collide: the move is clipped against every block box near the path, one axis at a
-- time (Y first, then the larger of X / Z first), and with a step height an entity on the
-- ground climbs onto ledges up to that high (slabs, stair steps).
--
-- `solid(x, y, z)` returns true (full cube), false / nil (nothing), or a list of boxes
-- { x0, y0, z0, x1, y1, z1 } in 0..1 cell units (Blocks/Shapes; fences reach up to 1.5).
--
-- All positions here must be Lua numbers (doubles). A Roblox Vector3 stores 32-bit floats: put
-- a position through one and the box no longer touches a wall exactly, it sits a hair inside
-- it, and a box that is already inside a block is not stopped by it (Java's rule too).

local MobPhysics = {}

-- Java's collision epsilon: overlaps and gaps below this count as touching.
local EPS = 1e-7
MobPhysics.EPS = EPS

export type SolidFn = (x: number, y: number, z: number) -> any

local FULL_LIST = { { 0, 0, 0, 1, 1, 1 } }

-- World boxes (flat list, 6 numbers each) of every block box overlapping the region.
function MobPhysics.gather(solid: SolidFn, x0: number, y0: number, z0: number, x1: number, y1: number, z1: number): { number }
	local out = {}
	-- one extra cell below for boxes taller than their cell (fences)
	for by = math.floor(y0) - 1, math.floor(y1) do
		for bz = math.floor(z0), math.floor(z1) do
			for bx = math.floor(x0), math.floor(x1) do
				local s = solid(bx, by, bz)
				if s then
					local list = if s == true then FULL_LIST else s
					for _, b in list do
						local bx0, by0, bz0 = bx + b[1], by + b[2], bz + b[3]
						local bx1, by1, bz1 = bx + b[4], by + b[5], bz + b[6]
						if bx1 > x0 and bx0 < x1 and by1 > y0 and by0 < y1 and bz1 > z0 and bz0 < z1 then
							local n = #out
							out[n + 1], out[n + 2], out[n + 3] = bx0, by0, bz0
							out[n + 4], out[n + 5], out[n + 6] = bx1, by1, bz1
						end
					end
				end
			end
		end
	end
	return out
end
local gather = MobPhysics.gather

-- Java VoxelShape.collide: how far box e = {x0, y0, z0, x1, y1, z1} can move by `d` along
-- `axis` (1 x, 2 y, 3 z). A block box only counts if it overlaps e on the two other axes by
-- more than EPS, and only stops e if e isn't already inside it (gap >= -EPS).
local function clip(boxes: { number }, e: { number }, axis: number, d: number): number
	if math.abs(d) < EPS then
		return 0
	end
	local a, b = if axis == 1 then 2 else 1, if axis == 3 then 2 else 3
	for i = 1, #boxes, 6 do
		if boxes[i + a + 2] > e[a] + EPS and boxes[i + a - 1] < e[a + 3] - EPS
			and boxes[i + b + 2] > e[b] + EPS and boxes[i + b - 1] < e[b + 3] - EPS
		then
			if d > 0 then
				local gap = boxes[i + axis - 1] - e[axis + 3]
				if gap >= -EPS and gap < d then
					d = gap
				end
			else
				local gap = boxes[i + axis + 2] - e[axis]
				if gap <= EPS and gap > d then
					d = gap
				end
			end
			if math.abs(d) < EPS then
				return 0
			end
		end
	end
	return d
end

-- Java Entity.collideWithShapes: clip a whole move. Y first; then Z before X if the Z move is
-- the larger one. `e` is not changed.
function MobPhysics.collideBoxes(boxes: { number }, e: { number }, dx: number, dy: number, dz: number): (number, number, number)
	if #boxes == 0 then
		return dx, dy, dz
	end
	local x0, y0, z0, x1, y1, z1 = e[1], e[2], e[3], e[4], e[5], e[6]
	local b = { x0, y0, z0, x1, y1, z1 }
	if dy ~= 0 then
		dy = clip(boxes, b, 2, dy)
		if dy ~= 0 then
			b[2], b[5] = y0 + dy, y1 + dy
		end
	end
	local zFirst = math.abs(dx) < math.abs(dz)
	if zFirst and dz ~= 0 then
		dz = clip(boxes, b, 3, dz)
		if dz ~= 0 then
			b[3], b[6] = z0 + dz, z1 + dz
		end
	end
	if dx ~= 0 then
		dx = clip(boxes, b, 1, dx)
		if not zFirst and dx ~= 0 then
			b[1], b[4] = x0 + dx, x1 + dx
		end
	end
	if not zFirst and dz ~= 0 then
		dz = clip(boxes, b, 3, dz)
	end
	return dx, dy, dz
end
local collideBoxes = MobPhysics.collideBoxes

-- Java Entity.collide: the move that is actually possible for box `e`, stepping up to
-- `stepHeight` when the entity is on the ground (or lands this move) and something low is in
-- the way.
function MobPhysics.collide(
	solid: SolidFn, e: { number }, dx: number, dy: number, dz: number, stepHeight: number?, onGround: boolean
): (number, number, number)
	local step = stepHeight or 0
	local boxes = gather(solid,
		e[1] + math.min(dx, 0), e[2] + math.min(dy, 0), e[3] + math.min(dz, 0),
		e[4] + math.max(dx, 0), e[5] + math.max(dy, step), e[6] + math.max(dz, 0))
	local mx, my, mz = collideBoxes(boxes, e, dx, dy, dz)
	local hitX, hitY, hitZ = mx ~= dx, my ~= dy, mz ~= dz
	if step > 0 and (onGround or (hitY and dy < 0)) and (hitX or hitZ) then
		-- 1: straight up by the step and across
		local ax, ay, az = collideBoxes(boxes, e, dx, step, dz)
		-- 2: as high as the whole path allows, then across
		local swept = { e[1] + math.min(dx, 0), e[2], e[3] + math.min(dz, 0), e[4] + math.max(dx, 0), e[5], e[6] + math.max(dz, 0) }
		local _, uy = collideBoxes(boxes, swept, 0, step, 0)
		if uy < step then
			local raised = { e[1], e[2] + uy, e[3], e[4], e[5] + uy, e[6] }
			local bx, _, bz = collideBoxes(boxes, raised, dx, 0, dz)
			if bx * bx + bz * bz > ax * ax + az * az then
				ax, ay, az = bx, uy, bz
			end
		end
		if ax * ax + az * az > mx * mx + mz * mz then
			-- got further: come back down onto whatever is under the new spot
			local moved = { e[1] + ax, e[2] + ay, e[3] + az, e[4] + ax, e[5] + ay, e[6] + az }
			local _, down = collideBoxes(boxes, moved, 0, dy - ay, 0)
			return ax, ay + down, az
		end
	end
	return mx, my, mz
end

-- Does the box at feet centre (x, y, z), `w` wide and `h` tall, overlap any block box?
function MobPhysics.collides(solid: SolidFn, x: number, y: number, z: number, w: number, h: number): boolean
	local hw = w / 2
	local boxes = gather(solid, x - hw + 1e-3, y + 1e-3, z - hw + 1e-3, x + hw - 1e-3, y + h - 1e-3, z + hw - 1e-3)
	return #boxes > 0
end

-- Move by velocity * dt (mobs, falling blocks, TNT). Returns the new position, the velocity
-- (zeroed on the axes that hit something), onGround and hitWall.
-- `stepHeight` (optional, blocks): climb onto ledges up to this high while on the ground.
function MobPhysics.move(
	solid: SolidFn,
	x: number, y: number, z: number,
	vx: number, vy: number, vz: number,
	w: number, h: number, dt: number,
	stepHeight: number?
): (number, number, number, number, number, number, boolean, boolean)
	local hw = w / 2
	local dx, dy, dz = vx * dt, vy * dt, vz * dt
	local wasOnGround = (stepHeight or 0) > 0 and MobPhysics.collides(solid, x, y - 0.02, z, w, 0.02)
	local e = { x - hw, y, z - hw, x + hw, y + h, z + hw }
	local mx, my, mz = MobPhysics.collide(solid, e, dx, dy, dz, stepHeight, wasOnGround)
	local hitX, hitZ = math.abs(mx - dx) > 1e-9, math.abs(mz - dz) > 1e-9
	local hitY = math.abs(my - dy) > 1e-9
	if hitX then
		vx = 0
	end
	if hitZ then
		vz = 0
	end
	if hitY then
		vy = 0
	end
	local nx, ny, nz = x + mx, y + my, z + mz
	local onGround = (hitY and dy < 0) or MobPhysics.collides(solid, nx, ny - 0.02, nz, w, 0.02)
	return nx, ny, nz, vx, vy, vz, onGround, hitX or hitZ
end

return MobPhysics
