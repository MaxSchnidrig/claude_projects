--!strict
-- Java Edition player physics, one 20 Hz tick (pure: no Roblox instances; tested headless).
-- MovementController runs it for the local player and places the body where the box is.
--
-- Units: blocks and ticks. (x, y, z) is the centre of the feet; the box is 0.6 wide and 1.8
-- tall (1.5 while sneaking). Position and velocity are plain Lua numbers (doubles) on purpose:
-- a Roblox Vector3 holds 32-bit floats, and a position rounded to one no longer touches a wall
-- exactly but sits a hair inside it, where the wall stops counting (see MobPhysics).
--
-- One tick, in Java's order (Entity.baseTick, LivingEntity.aiStep / travel, Entity.move):
--   fluids    how high water / lava reaches above the feet; a current pushes 0.014 (lava
--             0.00233); water resets the fall distance, lava halves it
--   velocity  components under 0.003 are dropped
--   jump      held, on the ground and noJumpDelay 0: vy = 0.42, sprinting adds 0.2 along the
--             facing, noJumpDelay = 10 (released: 0). In fluid deeper than 0.4 (or off the
--             ground): vy += 0.04 instead.
--   input     forward / strafe x 0.98, sneaking x 0.3, using an item x 0.2, cut to length 1,
--             turned to the facing. Acceleration 0.1 (sprint 0.13) on the ground, scaled by
--             the block's slipperiness (ice); 0.02 (0.026) in the air; 0.02 in fluids.
--   climbing  feet in a ladder / vine: sideways speed at most 0.15, falling at most 0.15,
--             sneaking holds; after moving, pushing into something or holding jump: vy = 0.2
--   sneaking  on the ground the move is cut back so the box keeps support within 0.6 below
--   move      Java Entity.collide against block shapes with a 0.6 step-up; a blocked axis
--             loses its speed; landing on a bed bounces 66 % (not while sneaking)
--   after     land: vy = (vy - 0.08) x 0.98, sideways x 0.546 on the ground (slipperiness
--             x 0.91), x 0.91 in the air.  water: x 0.8 (0.9 sprinting), vy - 0.005.
--             lava: x 0.5, vy - 0.02.  Swimming into a ledge with free air 0.6 up: vy = 0.3.
--   falls     the fall distance adds up the downward movement while in the air; it is
--             reported on landing (damage = distance - 3, rounded up, by the server)

local BlockRegistry = require(script.Parent.Parent.Blocks.BlockRegistry)
local Shapes = require(script.Parent.Parent.Blocks.Shapes)
local MobPhysics = require(script.Parent.Parent.Mobs.MobPhysics)
local PlayerPhysics = require(script.Parent.PlayerPhysics)
local Fluids = require(script.Parent.Parent.World.Fluids)

local PlayerMotor = {}

local HALF = 0.3
local STEP = 0.6
PlayerMotor.HALF = HALF
PlayerMotor.STEP = STEP
PlayerMotor.TICK = 0.05
PlayerMotor.HEIGHT = 1.8
PlayerMotor.SNEAK_HEIGHT = 1.5

local isLiquid = BlockRegistry.isLiquid
local byId = BlockRegistry.byId

-- Java Block.getFriction: 0.6 for everything but these.
local SLIPPERINESS: { [number]: number } = {}
do
	local ice = BlockRegistry.byKey["ice"]
	if ice then
		SLIPPERINESS[ice.id] = 0.98
	end
end

export type State = {
	x: number,
	y: number,
	z: number,
	vx: number, -- blocks/tick (Java deltaMovement)
	vy: number,
	vz: number,
	onGround: boolean,
	noJumpDelay: number,
	fallDistance: number,
}

export type Input = {
	forward: number, -- -1..1, forward positive (W)
	strafe: number, -- -1..1, right positive (D)
	lookX: number, -- horizontal facing (any length)
	lookZ: number,
	jump: boolean,
	sneak: boolean,
	sprint: boolean,
	usingItem: boolean,
}

export type Result = {
	fall: number?, -- landed this tick after falling this far (blocks)
	stepUp: number, -- rose this much by stepping onto something (the camera smooths it)
	hitWall: boolean, -- Java horizontalCollision
	minorWall: boolean, -- ... and it was a glancing one (sprinting survives it)
	onLadder: boolean,
	fluid: string?, -- "water" | "lava" when in it
	jumped: boolean,
	bounced: boolean,
}

export type World = {
	getBlock: (number, number, number) -> number?,
	solid: (number, number, number) -> any, -- Shapes.physicsFn
}

function PlayerMotor.new(x: number, y: number, z: number): State
	return { x = x, y = y, z = z, vx = 0, vy = 0, vz = 0, onGround = false, noJumpDelay = 0, fallDistance = 0 }
end

function PlayerMotor.world(getBlock: (number, number, number) -> number?): World
	return { getBlock = getBlock, solid = Shapes.physicsFn(getBlock) }
end

-- Any collision box inside this box (block units)? Unloaded counts as solid.
function PlayerMotor.solidIn(w: World, x0: number, y0: number, z0: number, x1: number, y1: number, z1: number): boolean
	return #MobPhysics.gather(w.solid, x0, y0, z0, x1, y1, z1) > 0
end
local solidIn = PlayerMotor.solidIn

-- Room for the standing box at this state's position?
function PlayerMotor.roomToStand(w: World, st: State): boolean
	return not solidIn(w, st.x - HALF + 1e-3, st.y + 0.01, st.z - HALF + 1e-3, st.x + HALF - 1e-3, st.y + 1.8, st.z + HALF - 1e-3)
end

-- Is the chunk the box stands in loaded? (Unloaded blocks count as solid; the caller should
-- hold the player still rather than simulate inside them.)
function PlayerMotor.loaded(w: World, st: State): boolean
	return w.getBlock(math.floor(st.x), math.floor(st.y), math.floor(st.z)) ~= nil
end

-- How far the surface of water and of lava reaches above the feet (0 = not touching), in the
-- column at the centre of the box (Java updateFluidHeightAndDoFluidPushing), and the lowest
-- cell of each in that column (for the current).
local function fluids(w: World, st: State, h: number): (number, number, number?, number?)
	local bx, bz = math.floor(st.x), math.floor(st.z)
	local lo, hi = st.y + 0.001, st.y + h - 0.001
	local water, lava = 0, 0
	local waterCell: number?, lavaCell: number? = nil, nil
	for cy = math.floor(lo), math.ceil(hi) - 1 do
		local id = w.getBlock(bx, cy, bz)
		if id and isLiquid[id + 1] then
			local kind, level = Fluids.info(id)
			local above = w.getBlock(bx, cy + 1, bz)
			local sameAbove = above ~= nil and isLiquid[above + 1] and (Fluids.info(above)) == kind
			local surface = cy + (if sameAbove then 1 else Fluids.height(level))
			if surface >= lo then
				if kind == "water" then
					water = math.max(water, surface - lo)
					waterCell = waterCell or cy
				elseif kind == "lava" then
					lava = math.max(lava, surface - lo)
					lavaCell = lavaCell or cy
				end
			end
		end
	end
	return water, lava, waterCell, lavaCell
end

-- Java Entity.isFree: the box moved by (dx, dy, dz) touches no block and no liquid.
local function isFree(w: World, st: State, h: number, dx: number, dy: number, dz: number): boolean
	local x0, y0, z0 = st.x - HALF + dx, st.y + dy, st.z - HALF + dz
	local x1, y1, z1 = st.x + HALF + dx, st.y + h + dy, st.z + HALF + dz
	if solidIn(w, x0, y0, z0, x1, y1, z1) then
		return false
	end
	for cx = math.floor(x0), math.ceil(x1) - 1 do
		for cy = math.floor(y0), math.ceil(y1) - 1 do
			for cz = math.floor(z0), math.ceil(z1) - 1 do
				local id = w.getBlock(cx, cy, cz)
				if id == nil or isLiquid[id + 1] then
					return false
				end
			end
		end
	end
	return true
end

-- Java Player.maybeBackOffFromEdge: shrink a sneaking move in 0.05 steps until the box, moved
-- by it, still has something within 0.6 below.
local function backOffFromEdge(w: World, st: State, dx: number, dz: number, h: number): (number, number)
	-- (a hair narrower than the box: a wall the box merely touches is not something to stand on)
	local function supported(ox: number, oz: number): boolean
		return solidIn(w, st.x + ox - HALF + 1e-3, st.y - STEP, st.z + oz - HALF + 1e-3,
			st.x + ox + HALF - 1e-3, st.y + h - STEP, st.z + oz + HALF - 1e-3)
	end
	local function shrink(v: number): number
		return if v < 0.05 and v >= -0.05 then 0 elseif v > 0 then v - 0.05 else v + 0.05
	end
	while dx ~= 0 and not supported(dx, 0) do
		dx = shrink(dx)
	end
	while dz ~= 0 and not supported(0, dz) do
		dz = shrink(dz)
	end
	while dx ~= 0 and dz ~= 0 and not supported(dx, dz) do
		dx, dz = shrink(dx), shrink(dz)
	end
	return dx, dz
end

-- Java LivingEntity.onClimbable: the block the feet are in.
local function onClimbable(w: World, st: State): boolean
	local bx, by, bz = math.floor(st.x), math.floor(st.y), math.floor(st.z)
	return Shapes.climbable(w.getBlock(bx, by, bz), w.getBlock(bx, by - 1, bz))
end

function PlayerMotor.tick(st: State, input: Input, w: World): Result
	local res: Result = {
		fall = nil, stepUp = 0, hitWall = false, minorWall = false, onLadder = false, fluid = nil, jumped = false, bounced = false,
	}
	local sneak = input.sneak
	local h = if sneak then 1.5 else 1.8
	-- facing (unit) and the direction to its right
	local lx, lz = input.lookX, input.lookZ
	local ll = math.sqrt(lx * lx + lz * lz)
	if ll < 1e-6 then
		lx, lz = 0, -1
	else
		lx, lz = lx / ll, lz / ll
	end
	local rx, rz = -lz, lx

	-- fluids (Entity.baseTick)
	local waterH, lavaH, waterCell, lavaCell = fluids(w, st, h)
	local inWater, inLava = waterH > 0, lavaH > 0
	if inWater then
		st.fallDistance = 0
		local fx, fz = Fluids.flow(w.getBlock, math.floor(st.x), waterCell :: number, math.floor(st.z))
		st.vx += fx * 0.014
		st.vz += fz * 0.014
	end
	if inLava then
		st.fallDistance *= 0.5
		local fx, fz = Fluids.flow(w.getBlock, math.floor(st.x), lavaCell :: number, math.floor(st.z))
		st.vx += fx * 0.0023333333333333335
		st.vz += fz * 0.0023333333333333335
	end
	res.fluid = if inWater then "water" elseif inLava then "lava" else nil

	-- LivingEntity.aiStep
	if st.noJumpDelay > 0 then
		st.noJumpDelay -= 1
	end
	local vx, vy, vz = st.vx, st.vy, st.vz
	if math.abs(vx) < 0.003 then
		vx = 0
	end
	if math.abs(vy) < 0.003 then
		vy = 0
	end
	if math.abs(vz) < 0.003 then
		vz = 0
	end
	if input.jump then
		local depth = if inLava then lavaH else waterH
		local swimming = inWater and depth > 0
		local shallow = st.onGround and not (depth > 0.4)
		if not swimming or shallow then
			if not inLava or shallow then
				if (st.onGround or (swimming and depth <= 0.4)) and st.noJumpDelay == 0 then
					-- jumpFromGround
					vy = PlayerPhysics.JUMP_VELOCITY
					if input.sprint then
						vx += lx * PlayerPhysics.SPRINT_JUMP_BOOST
						vz += lz * PlayerPhysics.SPRINT_JUMP_BOOST
					end
					st.noJumpDelay = PlayerPhysics.JUMP_DELAY_TICKS
					res.jumped = true
				end
			else
				vy += 0.04
			end
		else
			vy += 0.04
		end
	else
		st.noJumpDelay = 0
	end

	-- the input, in world space (Input.tick, aiStep damping, Entity.getInputVector)
	local scale = PlayerPhysics.INPUT_DAMPING
	if sneak then
		scale *= 0.3
	end
	if input.usingItem then
		scale *= 0.2
	end
	local f, s = input.forward * scale, input.strafe * scale
	local len2 = f * f + s * s
	local wx, wz = 0, 0
	if len2 >= 1e-7 then
		if len2 > 1 then
			local l = math.sqrt(len2)
			f, s = f / l, s / l
		end
		wx, wz = lx * f + rx * s, lz * f + rz * s
	end

	-- Entity.move for our own movement: returns the velocity left after collisions
	local function move(mvx: number, mvy: number, mvz: number): (number, number, number)
		local dx, dz = mvx, mvz
		if sneak and mvy <= 0 and st.onGround then
			dx, dz = backOffFromEdge(w, st, dx, dz, h)
		end
		local e = { st.x - HALF, st.y, st.z - HALF, st.x + HALF, st.y + h, st.z + HALF }
		local ax, ay, az = MobPhysics.collide(w.solid, e, dx, mvy, dz, STEP, st.onGround)
		if ax * ax + ay * ay + az * az > 1e-7 then
			st.x += ax
			st.y += ay
			st.z += az
		end
		local hitX, hitZ = math.abs(dx - ax) >= 1e-5, math.abs(dz - az) >= 1e-5
		local hitY = mvy ~= ay
		res.hitWall = hitX or hitZ
		if res.hitWall then
			-- Java isHorizontalCollisionMinor: the actual move is within 8 degrees of the input
			local d4, d5 = wx * wx + wz * wz, ax * ax + az * az
			if d4 >= 1e-5 and d5 >= 1e-5 then
				local c = math.clamp((wx * ax + wz * az) / math.sqrt(d4 * d5), -1, 1)
				res.minorWall = math.acos(c) < 0.13962634
			end
		end
		if st.onGround and ay > 0 and mvy <= 0 then
			res.stepUp = ay
		end
		st.onGround = hitY and mvy < 0
		-- checkFallDamage. Java looks for water again at the new position first: falling into
		-- water, even one block deep, breaks the fall on the tick you touch the bottom.
		if not inWater and st.fallDistance > 0 and (fluids(w, st, h)) > 0 then
			st.fallDistance = 0
		end
		if st.onGround then
			if st.fallDistance > 0 then
				res.fall = st.fallDistance
			end
			st.fallDistance = 0
		elseif ay < 0 then
			st.fallDistance -= ay
		end
		local nvx = if hitX then 0 else mvx
		local nvz = if hitZ then 0 else mvz
		local nvy = mvy
		if hitY then
			-- Block.updateEntityAfterFallOn of the block under the feet: beds bounce, the rest stop you
			local on = w.getBlock(math.floor(st.x), math.floor(st.y - 0.2), math.floor(st.z))
			local def = on and byId[on]
			if def and def.shape == "bed" and not sneak then
				if nvy < 0 then
					nvy = -nvy * 0.66
					res.bounced = true
				end
			else
				nvy = 0
			end
		end
		return nvx, nvy, nvz
	end

	if inWater then
		local y0 = st.y
		vx += wx * 0.02
		vz += wz * 0.02
		vx, vy, vz = move(vx, vy, vz)
		if res.hitWall and onClimbable(w, st) then
			vy = 0.2
		end
		local drag = if input.sprint then 0.9 else 0.8
		vx, vy, vz = vx * drag, vy * 0.8, vz * drag
		if not input.sprint then
			vy -= 0.005 -- gravity / 16
		end
		if res.hitWall and isFree(w, st, h, vx, vy + 0.6 - st.y + y0, vz) then
			vy = 0.3 -- swim up out onto the ledge
		end
	elseif inLava then
		local y0 = st.y
		vx += wx * 0.02
		vz += wz * 0.02
		vx, vy, vz = move(vx, vy, vz)
		if lavaH <= 0.4 then
			vx, vy, vz = vx * 0.5, vy * 0.8, vz * 0.5
			if not input.sprint then
				vy -= 0.005
			end
		else
			vx, vy, vz = vx * 0.5, vy * 0.5, vz * 0.5
		end
		vy -= 0.02 -- gravity / 4
		if res.hitWall and isFree(w, st, h, vx, vy + 0.6 - st.y + y0, vz) then
			vy = 0.3
		end
	else
		-- the block 0.5 below the feet decides how slippery the ground is
		local under = w.getBlock(math.floor(st.x), math.floor(st.y - 0.5000001), math.floor(st.z))
		local slip = (under and SLIPPERINESS[under]) or 0.6
		local friction = if st.onGround then slip * 0.91 else 0.91
		local accel
		if st.onGround then
			accel = (if input.sprint then PlayerPhysics.SPRINT else PlayerPhysics.WALK) * (0.21600002 / (slip * slip * slip))
		else
			accel = if input.sprint then PlayerPhysics.AIR_SPRINT else PlayerPhysics.AIR
		end
		vx += wx * accel
		vz += wz * accel
		if onClimbable(w, st) then
			st.fallDistance = 0
			vx = math.clamp(vx, -0.15, 0.15)
			vz = math.clamp(vz, -0.15, 0.15)
			vy = math.max(vy, -0.15)
			if vy < 0 and sneak then
				vy = 0 -- sneaking holds you on the ladder
			end
		end
		vx, vy, vz = move(vx, vy, vz)
		if (res.hitWall or input.jump) and onClimbable(w, st) then
			vy = 0.2
		end
		vy = (vy - 0.08) * 0.98
		vx *= friction
		vz *= friction
	end
	res.onLadder = onClimbable(w, st)
	st.vx, st.vy, st.vz = vx, vy, vz
	return res
end

-- After taking a position from outside (a spawn, a teleport: 32-bit floats, a few millimetres
-- off): if the box overlaps something by a little, push it out the short way, so it rests
-- against it instead of sitting inside it.
function PlayerMotor.settle(st: State, w: World, sneak: boolean?)
	local h = if sneak then 1.5 else 1.8
	local LIMIT = 0.25
	for _ = 1, 6 do
		local boxes = MobPhysics.gather(w.solid, st.x - HALF, st.y, st.z - HALF, st.x + HALF, st.y + h, st.z + HALF)
		if #boxes == 0 then
			return
		end
		-- the overlap that is cheapest to leave
		local best, bx, by, bz = math.huge, 0, 0, 0
		for i = 1, #boxes, 6 do
			local up = boxes[i + 4] - st.y
			local down = (st.y + h) - boxes[i + 1]
			local east = boxes[i + 3] - (st.x - HALF)
			local west = (st.x + HALF) - boxes[i]
			local south = boxes[i + 5] - (st.z - HALF)
			local north = (st.z + HALF) - boxes[i + 2]
			local m = math.min(up, down, east, west, south, north)
			if m < best then
				best = m
				bx, by, bz = 0, 0, 0
				if m == up then
					by = up
				elseif m == east then
					bx = east
				elseif m == west then
					bx = -west
				elseif m == south then
					bz = south
				elseif m == north then
					bz = -north
				else
					by = -down
				end
			end
		end
		if best > LIMIT then
			return -- really inside a block: leave it (you can walk out, like Java)
		end
		st.x += bx
		st.y += by
		st.z += bz
	end
end

return PlayerMotor
