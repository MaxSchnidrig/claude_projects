--!strict
-- Java Edition player physics, one 20 Hz tick (pure: no Roblox instances; tested headless).
-- MovementController runs it for the local player and places the body where the box is.
-- Units: blocks and ticks. `pos` is the centre of the feet; the box is 0.6 wide and 1.8 tall
-- (1.5 while sneaking).
--
-- Per tick (LivingEntity.aiStep / travel):
--   jump      held + on the ground + noJumpDelay 0: vy = 0.42, sprinting adds 0.2 along the
--             facing; noJumpDelay = 10 (released: 0). In a fluid: vy += 0.04 instead.
--   input     length <= 1, x 0.98, sneaking x 0.3, using an item x 0.2; acceleration 0.1 / 0.13
--             (sprint) on the ground (also on the jump tick), 0.02 / 0.026 in the air
--   climbing  ladders / vines: horizontal clamp 0.15, falling at most 0.15, sneaking holds; after
--             moving, pushing into something or holding jump sets vy = 0.2
--   sneaking  on the ground: the move is cut back so the box keeps support within 0.6 below
--   move      against block shapes (MobPhysics), step up 0.6 when on the ground or landing
--   after     vy = (vy - 0.08) x 0.98; horizontal x 0.546 on the ground, x 0.91 in the air
--   water     accel 0.02, current 0.014, then x 0.8 (0.9 sprinting), vy - 0.005;
--   lava      accel 0.02, then x 0.5, vy - 0.02; in both, swimming into a ledge with room
--             0.6 higher sets vy = 0.3

local BlockRegistry = require(script.Parent.Parent.Blocks.BlockRegistry)
local Shapes = require(script.Parent.Parent.Blocks.Shapes)
local MobPhysics = require(script.Parent.Parent.Mobs.MobPhysics)
local PlayerPhysics = require(script.Parent.PlayerPhysics)
local Fluids = require(script.Parent.Parent.World.Fluids)

local PlayerMotor = {}

local HALF = 0.3
local WIDTH = 0.6
local STEP = 0.6
local TICK = 0.05
PlayerMotor.HALF = HALF
PlayerMotor.STEP = STEP

local isLiquid = BlockRegistry.isLiquid

export type State = {
	pos: Vector3,
	vel: Vector3, -- blocks/tick
	onGround: boolean,
	noJumpDelay: number,
	peak: number?, -- highest feet height since leaving the ground
}

export type Input = {
	moveX: number, -- world-space movement input (length <= 1)
	moveZ: number,
	jump: boolean,
	sneak: boolean,
	sprint: boolean,
	usingItem: boolean,
	lookX: number, -- facing (sprint-jump boost)
	lookZ: number,
}

export type Result = {
	fall: number?, -- landed after falling this far (blocks, > 3 = damage)
	stepUp: number, -- risen by a step this tick
	hitWall: boolean,
	onLadder: boolean,
	fluid: string?,
	jumped: boolean,
	bounced: boolean,
}

export type World = {
	getBlock: (number, number, number) -> number?,
	solid: (number, number, number) -> any, -- Shapes.physicsFn
}

function PlayerMotor.new(pos: Vector3): State
	return { pos = pos, vel = Vector3.zero, onGround = false, noJumpDelay = 0, peak = nil }
end

function PlayerMotor.world(getBlock: (number, number, number) -> number?): World
	return { getBlock = getBlock, solid = Shapes.physicsFn(getBlock) }
end

-- Any collision box inside this box (block units)? Unloaded counts as solid.
function PlayerMotor.solidIn(w: World, x0: number, y0: number, z0: number, x1: number, y1: number, z1: number): boolean
	for x = math.floor(x0), math.ceil(x1) - 1 do
		for y = math.floor(y0) - 1, math.ceil(y1) - 1 do
			for z = math.floor(z0), math.ceil(z1) - 1 do
				local s = w.solid(x, y, z)
				if s == true then
					if y >= math.floor(y0) then
						return true
					end
				elseif s then
					for _, b in s do
						if x + b[4] > x0 and x + b[1] < x1 and y + b[5] > y0 and y + b[2] < y1 and z + b[6] > z0 and z + b[3] < z1 then
							return true
						end
					end
				end
			end
		end
	end
	return false
end
local solidIn = PlayerMotor.solidIn

function PlayerMotor.roomToStand(w: World, p: Vector3): boolean
	return not solidIn(w, p.X - HALF + 1e-3, p.Y + 0.01, p.Z - HALF + 1e-3, p.X + HALF - 1e-3, p.Y + 1.8, p.Z + HALF - 1e-3)
end

local function fluidAt(w: World, p: Vector3, h: number): string?
	local bx, bz = math.floor(p.X), math.floor(p.Z)
	local fid = w.getBlock(bx, math.floor(p.Y + 0.1), bz)
	local bid = w.getBlock(bx, math.floor(p.Y + h * 0.6), bz)
	if fid and isLiquid[fid + 1] then
		return (Fluids.info(fid))
	elseif bid and isLiquid[bid + 1] then
		return (Fluids.info(bid))
	end
	return nil
end

-- Java maybeBackOffFromEdge.
local function backOffFromEdge(w: World, p: Vector3, dx: number, dz: number, h: number): (number, number)
	local function supportedAt(ox: number, oz: number): boolean
		return solidIn(w, p.X + ox - HALF + 1e-3, p.Y - STEP, p.Z + oz - HALF + 1e-3, p.X + ox + HALF - 1e-3, p.Y + h - STEP, p.Z + oz + HALF - 1e-3)
	end
	local s = 0.05
	local function shrink(v: number): number
		return if math.abs(v) < s then 0 elseif v > 0 then v - s else v + s
	end
	while dx ~= 0 and not supportedAt(dx, 0) do
		dx = shrink(dx)
	end
	while dz ~= 0 and not supportedAt(0, dz) do
		dz = shrink(dz)
	end
	while dx ~= 0 and dz ~= 0 and not supportedAt(dx, dz) do
		dx, dz = shrink(dx), shrink(dz)
	end
	return dx, dz
end

function PlayerMotor.tick(st: State, input: Input, w: World): Result
	local res: Result = { fall = nil, stepUp = 0, hitWall = false, onLadder = false, fluid = nil, jumped = false, bounced = false }
	local crouch = input.sneak
	local h = if crouch then 1.5 else 1.8
	local p = st.pos
	local vx, vy, vz = st.vel.X, st.vel.Y, st.vel.Z
	local fluid = fluidAt(w, p, h)
	res.fluid = fluid

	local bx, bz = math.floor(p.X), math.floor(p.Z)
	local fy, by = math.floor(p.Y + 0.05), math.floor(p.Y + 1)
	local onLadder = Shapes.climbable(w.getBlock(bx, fy, bz), w.getBlock(bx, fy - 1, bz))
		or Shapes.climbable(w.getBlock(bx, by, bz), w.getBlock(bx, by - 1, bz))
	res.onLadder = onLadder

	-- jumping
	if st.noJumpDelay > 0 then
		st.noJumpDelay -= 1
	end
	local jumped = false
	if input.jump then
		if fluid then
			vy += 0.04
		elseif st.onGround and st.noJumpDelay == 0 then
			vy = PlayerPhysics.JUMP_VELOCITY
			if input.sprint then
				local bxv, bzv = PlayerPhysics.jumpBoost(input.lookX, input.lookZ)
				vx += bxv
				vz += bzv
			end
			st.noJumpDelay = PlayerPhysics.JUMP_DELAY_TICKS
			jumped = true
		end
	else
		st.noJumpDelay = 0
	end
	res.jumped = jumped

	-- input
	local ix, iz = input.moveX, input.moveZ
	local len = math.sqrt(ix * ix + iz * iz)
	if len > 1 then
		ix, iz = ix / len, iz / len
	end
	local scale = PlayerPhysics.INPUT_DAMPING
	if crouch then
		scale *= 0.3
	end
	if input.usingItem then
		scale *= 0.2
	end
	ix, iz = ix * scale, iz * scale

	local landedNow = false
	if fluid then
		vx += ix * 0.02
		vz += iz * 0.02
		local cx, cz = Fluids.flow(w.getBlock, math.floor(p.X), math.floor(p.Y + 0.1), math.floor(p.Z))
		vx += cx * 0.014
		vz += cz * 0.014
		local nx, ny, nz, rvx, rvy, rvz, onGround, wall = MobPhysics.move(w.solid, p.X, p.Y, p.Z, vx * 20, vy * 20, vz * 20, WIDTH, h, TICK, nil)
		st.pos = Vector3.new(nx, ny, nz)
		st.onGround = onGround
		res.hitWall = wall
		vx, vy, vz = rvx / 20, rvy / 20, rvz / 20
		if fluid == "lava" then
			vx, vy, vz = vx * 0.5, vy * 0.5 - 0.02, vz * 0.5
		else
			local f = if input.sprint then 0.9 else 0.8
			vx, vy, vz = vx * f, vy * 0.8 - 0.005, vz * f
		end
		if wall and not solidIn(w, nx - HALF, ny + 0.6, nz - HALF, nx + HALF, ny + 0.6 + h, nz + HALF) then
			vy = 0.3 -- swim up out onto the ledge
		end
	else
		local groundish = st.onGround or jumped
		local accel = if groundish then (if input.sprint then PlayerPhysics.SPRINT else PlayerPhysics.WALK)
			else (if input.sprint then PlayerPhysics.AIR_SPRINT else PlayerPhysics.AIR)
		vx += ix * accel
		vz += iz * accel
		if onLadder then
			vx = math.clamp(vx, -0.15, 0.15)
			vz = math.clamp(vz, -0.15, 0.15)
			vy = math.max(vy, -0.15)
			if crouch and vy < 0 then
				vy = 0
			end
		end
		if crouch and st.onGround and vy <= 0 then
			vx, vz = backOffFromEdge(w, p, vx, vz, h)
		end
		local nx, ny, nz, rvx, rvy, rvz, onGround, wall = MobPhysics.move(w.solid, p.X, p.Y, p.Z, vx * 20, vy * 20, vz * 20, WIDTH, h, TICK,
			if groundish or vy < 0 then STEP else nil)
		landedNow = onGround and not st.onGround
		st.pos = Vector3.new(nx, ny, nz)
		if groundish and onGround and ny - p.Y > 0.05 then
			res.stepUp = ny - p.Y
		end
		st.onGround = onGround
		res.hitWall = wall
		vx, vy, vz = rvx / 20, rvy / 20, rvz / 20
		local mlen = math.sqrt(input.moveX * input.moveX + input.moveZ * input.moveZ)
		local pushing = wall or (mlen > 0.1 and solidIn(w, nx + input.moveX / mlen * 0.05 - HALF, ny + 0.05,
			nz + input.moveZ / mlen * 0.05 - HALF, nx + input.moveX / mlen * 0.05 + HALF, ny + h - 0.05,
			nz + input.moveZ / mlen * 0.05 + HALF))
		if onLadder and (pushing or input.jump) then
			vy = 0.2
		end
		-- Java decides friction (like acceleration) from the ground state before the move
		local friction = if groundish then PlayerPhysics.GROUND_FRICTION else PlayerPhysics.AIR_FRICTION
		vy = (vy - 0.08) * 0.98
		vx *= friction
		vz *= friction
	end

	-- falls
	if fluid or onLadder then
		st.peak = nil
	elseif st.onGround then
		local peak = st.peak
		if peak and peak - st.pos.Y > 0 then
			res.fall = peak - st.pos.Y
		end
		st.peak = nil
		if landedNow and peak then
			local under = w.getBlock(math.floor(st.pos.X), math.floor(st.pos.Y - 0.1), math.floor(st.pos.Z))
			local ud = under and BlockRegistry.byId[under]
			if ud and ud.shape == "bed" and not crouch and peak - st.pos.Y > 0.3 then
				vy = math.sqrt(2 * 0.08 * (peak - st.pos.Y)) * 0.66 -- beds bounce at 66 %
				st.onGround = false
				res.bounced = true
			end
		end
	else
		st.peak = math.max(st.peak or st.pos.Y, st.pos.Y)
	end
	st.vel = Vector3.new(vx, vy, vz)
	return res
end

return PlayerMotor
