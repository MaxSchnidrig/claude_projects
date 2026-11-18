--!strict
-- Hunger, saturation, exhaustion and regeneration: a tick-by-tick copy of Java Edition's
-- FoodData (checked against the Minecraft Wiki "Food" page: Hunger, Saturation, Exhaustion,
-- Internal variables). Pure, so it's tested headless. One call of `tickFood` = one game tick
-- (20 per second); the server runs it exactly 20 times a second.
--
-- FoodData.tick, in this order:
--   1. exhaustion above 4.0: minus 4.0, and 1 saturation point is used up, or (no saturation
--      left, not Peaceful) 1 hunger point. At most one point per tick.
--   2. one shared timer (foodTickTimer):
--        saturation > 0, hurt and hunger 20: +1 a tick; at 10: heal min(saturation, 6) / 6
--          and add that min(...) as exhaustion (saturation boost)
--        else hunger >= 18 and hurt: +1 a tick; at 80: heal 1 and add 6.0 exhaustion
--        else hunger 0: +1 a tick; at 80: 1 starvation damage if health > 10, or on Hard, or
--          health > 1 on Normal
--        else: the timer goes back to 0
--   Exhaustion never goes above 40 (FoodData.addExhaustion).
-- Eating (FoodData.add): hunger = min(hunger + food, 20); saturation = clamp(saturation + sat,
-- 0, hunger). A new life starts at hunger 20, saturation 5, exhaustion 0.
-- Sprinting needs hunger above 6.
-- Fall damage: ceil(fall - 3), none when landing in water.

local SurvivalRules = {}

SurvivalRules.MAX_HEALTH = 20
SurvivalRules.MAX_FOOD = 20
SurvivalRules.START_SATURATION = 5
SurvivalRules.EXHAUSTION_PER_POINT = 4
SurvivalRules.MAX_EXHAUSTION = 40
SurvivalRules.SPRINT_MIN_FOOD = 7 -- hunger must be above 6
SurvivalRules.TICK = 0.05 -- seconds per game tick
SurvivalRules.SATURATION_REGEN_TICKS = 10
SurvivalRules.REGEN_TICKS = 80
SurvivalRules.STARVE_TICKS = 80

-- Exhaustion per action (wiki "Energy-intensive actions"; Java Player / FoodConstants).
SurvivalRules.EXHAUSTION = {
	sprintPerMeter = 0.1, -- on the ground only (Player.checkMovementStatistics)
	swimPerMeter = 0.01, -- in water (3D distance with the eyes under, else horizontal)
	jump = 0.05,
	sprintJump = 0.2,
	attack = 0.1, -- an attack that lands
	damage = 0.1, -- damage armour protects against (falls, drowning, starving, magic: 0)
	breakBlock = 0.005,
	heal = 6.0, -- per health point of natural regeneration
	hungerEffect = 0.005, -- per tick per level of the Hunger effect
}

SurvivalRules.MAX_AIR = 15 -- seconds underwater before drowning
SurvivalRules.DROWN_DAMAGE = 2 -- per second without air
SurvivalRules.LAVA_DAMAGE = 4 -- per 0.5 s in lava

export type Hunger = {
	food: number,
	saturation: number,
	exhaustion: number,
	tickTimer: number,
	-- Peaceful: exhaustion only ever uses up saturation, never hunger (FoodData.tick)
	peaceful: boolean?,
}

function SurvivalRules.newHunger(): Hunger
	return {
		food = SurvivalRules.MAX_FOOD,
		saturation = SurvivalRules.START_SATURATION,
		exhaustion = 0,
		tickTimer = 0,
	}
end

-- FoodData.addExhaustion: added now, turned into lost saturation / hunger by the next ticks.
function SurvivalRules.addExhaustion(h: Hunger, amount: number)
	h.exhaustion = math.min(h.exhaustion + amount, SurvivalRules.MAX_EXHAUSTION)
end

-- FoodData.add (eating): hunger capped at 20, saturation capped at the new hunger.
function SurvivalRules.eat(h: Hunger, hunger: number, saturation: number)
	h.food = math.clamp(h.food + hunger, 0, SurvivalRules.MAX_FOOD)
	h.saturation = math.clamp(h.saturation + saturation, 0, h.food)
end

-- Does starvation hurt at this health on this difficulty? (FoodData.tick)
function SurvivalRules.starves(health: number, difficulty: string): boolean
	return health > 10 or difficulty == "hard" or (health > 1 and difficulty == "normal")
end

-- One game tick of FoodData. Returns (heal, starveDamage) to apply to the player right now.
-- `naturalRegen`: the naturalRegeneration rule (always on for now).
function SurvivalRules.tickFood(h: Hunger, health: number, maxHealth: number, difficulty: string, naturalRegen: boolean?): (number, number)
	if h.exhaustion > SurvivalRules.EXHAUSTION_PER_POINT then
		h.exhaustion -= SurvivalRules.EXHAUSTION_PER_POINT
		if h.saturation > 0 then
			h.saturation = math.max(h.saturation - 1, 0)
		elseif difficulty ~= "peaceful" and not h.peaceful then
			h.food = math.max(h.food - 1, 0)
		end
	end
	local regen = naturalRegen ~= false
	local hurt = health > 0 and health < maxHealth
	if regen and h.saturation > 0 and hurt and h.food >= 20 then
		h.tickTimer += 1
		if h.tickTimer >= SurvivalRules.SATURATION_REGEN_TICKS then
			local f = math.min(h.saturation, 6)
			SurvivalRules.addExhaustion(h, f)
			h.tickTimer = 0
			return f / 6, 0
		end
	elseif regen and h.food >= 18 and hurt then
		h.tickTimer += 1
		if h.tickTimer >= SurvivalRules.REGEN_TICKS then
			SurvivalRules.addExhaustion(h, SurvivalRules.EXHAUSTION.heal)
			h.tickTimer = 0
			return 1, 0
		end
	elseif h.food <= 0 then
		h.tickTimer += 1
		if h.tickTimer >= SurvivalRules.STARVE_TICKS then
			h.tickTimer = 0
			if SurvivalRules.starves(health, difficulty) then
				return 0, 1
			end
		end
	else
		h.tickTimer = 0
	end
	return 0, 0
end

function SurvivalRules.canSprint(h: Hunger): boolean
	return h.food >= SurvivalRules.SPRINT_MIN_FOOD
end

-- Exhaustion from one tick of movement (Java Player.checkMovementStatistics). dx, dy, dz: the
-- distance actually moved this tick (blocks). Distances are counted in whole centimetres per
-- tick, like Java's statistics.
export type MoveState = { eyeInWater: boolean, inWater: boolean, onClimbable: boolean, onGround: boolean, sprinting: boolean }
local function cm(d: number): number
	return math.floor(d * 100 + 0.5) -- Math.round
end
function SurvivalRules.movementExhaustion(dx: number, dy: number, dz: number, m: MoveState): number
	local E = SurvivalRules.EXHAUSTION
	if m.eyeInWater then
		local i = cm(math.sqrt(dx * dx + dy * dy + dz * dz))
		return if i > 0 then E.swimPerMeter * i * 0.01 else 0
	elseif m.inWater then
		local i = cm(math.sqrt(dx * dx + dz * dz))
		return if i > 0 then E.swimPerMeter * i * 0.01 else 0
	elseif m.onClimbable then
		return 0
	elseif m.onGround then
		local i = cm(math.sqrt(dx * dx + dz * dz))
		return if i > 0 and m.sprinting then E.sprintPerMeter * i * 0.01 else 0
	end
	return 0
end

-- Exhaustion of a jump (Player.jumpFromGround).
function SurvivalRules.jumpExhaustion(sprinting: boolean): number
	return if sprinting then SurvivalRules.EXHAUSTION.sprintJump else SurvivalRules.EXHAUSTION.jump
end

-- Fall damage for a fall of `blocks` blocks (0 if it ended in liquid).
function SurvivalRules.fallDamage(blocks: number, landedInLiquid: boolean): number
	if landedInLiquid then
		return 0
	end
	return math.max(0, math.ceil(blocks - 3 - 1e-6))
end

return SurvivalRules
