--!strict
-- Block units, seconds, feet-centred collision box. Gravity is constant in free flight.
local Physics = require(script.Parent.Parent.Mobs.MobPhysics)
local ItemMotion = {}
ItemMotion.SIZE = 0.25
ItemMotion.TICK = 1 / 30
local GRAVITY = 16
export type State = { x: number, y: number, z: number, vx: number, vy: number, vz: number, resting: boolean }

function ItemMotion.launch(look: Vector3): Vector3
	return look * 6 + Vector3.new(0, 2, 0)
end

function ItemMotion.step(s: State, solid: Physics.SolidFn)
	local dt = ItemMotion.TICK
	local averageY = s.vy - GRAVITY * dt / 2
	local x, y, z, vx, vy, vz, grounded = Physics.move(solid, s.x, s.y, s.z,
		s.vx, averageY, s.vz, ItemMotion.SIZE, ItemMotion.SIZE, dt)
	s.x, s.y, s.z = x, y, z
	s.vx, s.vz = vx, vz
	s.vy = if vy == averageY then s.vy - GRAVITY * dt else 0
	if grounded and averageY < 0 and vy == 0 then
		s.vy = if averageY < -2 then -averageY * 0.22 else 0
		s.vx *= 0.70
		s.vz *= 0.70
		s.resting = s.vy == 0 and math.abs(s.vx) + math.abs(s.vz) < 0.12
		if s.resting then
			s.vx, s.vz = 0, 0
		end
	else
		s.resting = false
	end
end
return ItemMotion
