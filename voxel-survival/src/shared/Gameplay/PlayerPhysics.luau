--!strict
-- Java Edition player movement, horizontal part, per 20 Hz tick (pure; tested headless).
-- Units: blocks and ticks. `stored` is Java's deltaMovement after the previous tick.
--
--   input       world direction, length <= 1, times 0.98 (Java input damping), x 0.3 sneaking,
--               x 0.2 using an item
--   accel       on the ground: movement speed (0.1 walking, 0.13 sprinting) x input
--               in the air: 0.02 (0.026 sprinting) x input
--   tick        disp = stored + accel;  move by disp;  stored = disp x friction
--               friction: 0.546 on the ground (block 0.6 x 0.91), 0.91 in the air
--   jump        vy = 0.42; sprinting adds 0.2 to stored along the facing direction. The jump
--               tick still counts as on the ground (ground accel and friction)
--   held jump   after a jump, holding jump can't jump again for 10 ticks (released = no delay)
--   collision   a blocked axis loses its velocity
--
-- Results: walking 4.317 b/s, sprinting 5.612 b/s, held sprint-jumping ~7.11 b/s on flat ground.

local PlayerPhysics = {}

PlayerPhysics.WALK = 0.1
PlayerPhysics.SPRINT = 0.13
PlayerPhysics.AIR = 0.02
PlayerPhysics.AIR_SPRINT = 0.026
PlayerPhysics.GROUND_FRICTION = 0.6 * 0.91
PlayerPhysics.AIR_FRICTION = 0.91
PlayerPhysics.INPUT_DAMPING = 0.98
PlayerPhysics.SPRINT_JUMP_BOOST = 0.2
PlayerPhysics.JUMP_VELOCITY = 0.42
PlayerPhysics.JUMP_DELAY_TICKS = 10

-- One horizontal tick. (ix, iz): input already scaled (see header). Returns the displacement
-- this tick and the new stored velocity.
function PlayerPhysics.tick(sx: number, sz: number, ix: number, iz: number, onGround: boolean, sprinting: boolean): (number, number, number, number)
	local speed
	if onGround then
		speed = if sprinting then PlayerPhysics.SPRINT else PlayerPhysics.WALK
	else
		speed = if sprinting then PlayerPhysics.AIR_SPRINT else PlayerPhysics.AIR
	end
	local dx, dz = sx + ix * speed, sz + iz * speed
	local f = if onGround then PlayerPhysics.GROUND_FRICTION else PlayerPhysics.AIR_FRICTION
	return dx, dz, dx * f, dz * f
end

-- Sprint-jump impulse along the facing direction (unit look vector x, z).
function PlayerPhysics.jumpBoost(lookX: number, lookZ: number): (number, number)
	local l = math.sqrt(lookX * lookX + lookZ * lookZ)
	if l < 1e-6 then
		return 0, 0
	end
	return lookX / l * PlayerPhysics.SPRINT_JUMP_BOOST, lookZ / l * PlayerPhysics.SPRINT_JUMP_BOOST
end

-- Steady ground displacement per tick for an input (used to know when a landing has settled).
function PlayerPhysics.steadyGround(ix: number, iz: number, sprinting: boolean): (number, number)
	local speed = if sprinting then PlayerPhysics.SPRINT else PlayerPhysics.WALK
	local k = speed / (1 - PlayerPhysics.GROUND_FRICTION)
	return ix * k, iz * k
end

-- Vertical tick (tests and reference): move by vy, then vy = (vy - 0.08) * 0.98.
function PlayerPhysics.verticalAfter(vy: number): number
	return (vy - 0.08) * 0.98
end

return PlayerPhysics
