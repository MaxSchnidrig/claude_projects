--!strict
--!native
-- Kinematic box movement for mobs, falling blocks and TNT (pure; the server has no terrain
-- physics). An entity is an axis-aligned box: feet centre (x, y, z), `w` wide (x and z), `h`
-- tall, all in block units.
--
-- Java-style collision: the movement is clipped against every block box near the path, one axis
-- at a time (Y, then X, then Z), so entities land on slab tops and stop against fences. With a
-- step height (mobs: 0.6), walking into something low (a slab, a stair step) steps up onto it.
--
-- `solid(x, y, z)` returns true (full cube), false / nil (nothing), or a list of boxes
-- { x0, y0, z0, x1, y1, z1 } in 0..1 cell units (Blocks/Shapes; fences reach up to 1.5).

local MobPhysics = {}

local EPS = 1e-7

export type SolidFn = (x: number, y: number, z: number) -> any

local FULL = { 0, 0, 0, 1, 1, 1 }

-- World boxes (flat list of 6 numbers each) of every block overlapping the region.
local function gather(solid: SolidFn, x0: number, y0: number, z0: number, x1: number, y1: number, z1: number): { number }
	local out = {}
	-- one extra cell below for boxes taller than their cell (fences)
	for by = math.floor(y0) - 1, math.floor(y1) do
		for bz = math.floor(z0), math.floor(z1) do
			for bx = math.floor(x0), math.floor(x1) do
				local s = solid(bx, by, bz)
				if s then
					local list = if s == true then { FULL } else s
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

-- Clip `d` (movement along `axis` 1/2/3) of box e = {x0, y0, z0, x1, y1, z1} against boxes.
local function clip(boxes: { number }, e: { number }, axis: number, d: number): number
	if d == 0 then
		return 0
	end
	local a, b = if axis == 1 then 2 else 1, if axis == 3 then 2 else 3
	for i = 1, #boxes, 6 do
		-- overlap on the two other axes?
		if boxes[i + a + 2] > e[a] + EPS and boxes[i + a - 1] < e[a + 3] - EPS
			and boxes[i + b + 2] > e[b] + EPS and boxes[i + b - 1] < e[b + 3] - EPS
		then
			local lo, hi = boxes[i + axis - 1], boxes[i + axis + 2]
			if d > 0 and lo >= e[axis + 3] - EPS then
				d = math.min(d, lo - e[axis + 3])
			elseif d < 0 and hi <= e[axis] + EPS then
				d = math.max(d, hi - e[axis])
			end
		end
	end
	return d
end

local function shift(e: { number }, axis: number, d: number)
	e[axis] += d
	e[axis + 3] += d
end

function MobPhysics.collides(solid: SolidFn, x: number, y: number, z: number, w: number, h: number): boolean
	local hw = w / 2
	local boxes = gather(solid, x - hw + 1e-3, y + 1e-3, z - hw + 1e-3, x + hw - 1e-3, y + h - 1e-3, z + hw - 1e-3)
	return #boxes > 0
end

-- Clipped movement (dx, dy, dz) of box e; returns the moved distances.
local function moveBox(solid: SolidFn, e: { number }, dx: number, dy: number, dz: number): (number, number, number)
	local boxes = gather(solid,
		math.min(e[1], e[1] + dx), math.min(e[2], e[2] + dy), math.min(e[3], e[3] + dz),
		math.max(e[4], e[4] + dx), math.max(e[5], e[5] + dy), math.max(e[6], e[6] + dz))
	local my = clip(boxes, e, 2, dy)
	shift(e, 2, my)
	local mx = clip(boxes, e, 1, dx)
	shift(e, 1, mx)
	local mz = clip(boxes, e, 3, dz)
	shift(e, 3, mz)
	return mx, my, mz
end

-- Move by velocity * dt. Returns new position, new velocity, onGround, hitWall.
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
	local wasOnGround = MobPhysics.collides(solid, x, y - 0.02, z, w, 0.02)
	local e = { x - hw, y, z - hw, x + hw, y + h, z + hw }
	local mx, my, mz = moveBox(solid, e, dx, dy, dz)
	local hitWall = math.abs(mx - dx) > 1e-6 or math.abs(mz - dz) > 1e-6
	local landed = dy < 0 and my > dy + 1e-9
	-- step up (Java Entity.collide with maxUpStep)
	local step = stepHeight or 0
	if step > 0 and hitWall and (wasOnGround or landed) then
		local e2 = { x - hw, y, z - hw, x + hw, y + h, z + hw }
		local _, up = moveBox(solid, e2, 0, step, 0)
		local sx, _, sz = moveBox(solid, e2, dx, 0, dz)
		local _, down = moveBox(solid, e2, 0, -(up + math.max(0, -dy)), 0)
		if sx * sx + sz * sz > mx * mx + mz * mz + 1e-9 then
			e = e2
			mx, mz = sx, sz
			my = up + down
			landed = true
			hitWall = math.abs(mx - dx) > 1e-6 or math.abs(mz - dz) > 1e-6
		end
	end
	if math.abs(mx - dx) > 1e-6 then
		vx = 0
	end
	if math.abs(mz - dz) > 1e-6 then
		vz = 0
	end
	if math.abs(my - dy) > 1e-6 then
		vy = 0
	end
	local nx, ny, nz = (e[1] + e[4]) / 2, e[2], (e[3] + e[6]) / 2
	local onGround = landed or MobPhysics.collides(solid, nx, ny - 0.02, nz, w, 0.02)
	return nx, ny, nz, vx, vy, vz, onGround, hitWall
end

return MobPhysics
