--!strict
-- Pure survival rules (classic values), shared so they can be unit-tested headless.
--
-- Hunger: 20 food points + hidden saturation (never above food). Actions add exhaustion; every
-- 4.0 exhaustion removes 1 saturation, or 1 food point when saturation is empty.
--   sprinting 0.1 / block, jumping 0.05, sprint-jump 0.2, breaking a block 0.005,
--   taking damage 0.1, healing 1 HP 6.0
-- Regeneration: food 20 with saturation -> min(saturation, 6)/6 HP every 0.5 s (costs
-- min(saturation, 6) exhaustion); food >= 18 -> 1 HP every 4 s (costs 6.0).
-- Starvation: food 0 -> 1 damage every 4 s (Normal difficulty: stops at 1 HP).
-- Sprinting needs food > 6.
-- Fall damage: ceil(fallBlocks - 3), none when landing in water.

local SurvivalRules = {}

SurvivalRules.MAX_HEALTH = 20
SurvivalRules.MAX_FOOD = 20
SurvivalRules.START_SATURATION = 5
SurvivalRules.EXHAUSTION_PER_POINT = 4
SurvivalRules.SPRINT_MIN_FOOD = 7 -- food must be above 6

SurvivalRules.EXHAUSTION = {
	sprintPerBlock = 0.1,
	jump = 0.05,
	sprintJump = 0.2,
	breakBlock = 0.005,
	damage = 0.1,
	heal = 6.0,
}

SurvivalRules.MAX_AIR = 15 -- seconds underwater before drowning
SurvivalRules.DROWN_DAMAGE = 2 -- per second without air
SurvivalRules.LAVA_DAMAGE = 4 -- per 0.5 s in lava
SurvivalRules.FAST_REGEN_INTERVAL = 0.5
SurvivalRules.SLOW_REGEN_INTERVAL = 4
SurvivalRules.STARVE_INTERVAL = 4

export type Hunger = {
	food: number,
	saturation: number,
	exhaustion: number,
	regenTimer: number,
	starveTimer: number,
}

function SurvivalRules.newHunger(): Hunger
	return {
		food = SurvivalRules.MAX_FOOD,
		saturation = SurvivalRules.START_SATURATION,
		exhaustion = 0,
		regenTimer = 0,
		starveTimer = 0,
	}
end

function SurvivalRules.addExhaustion(h: Hunger, amount: number)
	h.exhaustion += amount
	while h.exhaustion >= SurvivalRules.EXHAUSTION_PER_POINT do
		h.exhaustion -= SurvivalRules.EXHAUSTION_PER_POINT
		if h.saturation > 0 then
			h.saturation = math.max(0, h.saturation - 1)
		else
			h.food = math.max(0, h.food - 1)
		end
	end
end

-- Eat: food points capped at 20, saturation capped at the new food level.
function SurvivalRules.eat(h: Hunger, hunger: number, saturation: number)
	h.food = math.min(SurvivalRules.MAX_FOOD, h.food + hunger)
	h.saturation = math.min(h.food, h.saturation + saturation)
end

-- Advance regeneration/starvation by dt. Returns (heal, damage) in HP to apply now.
-- `minHealthAfterStarve`: starvation never takes health below this (Normal = 1).
function SurvivalRules.tick(h: Hunger, dt: number, health: number, maxHealth: number, minHealthAfterStarve: number): (number, number)
	local heal, damage = 0, 0
	if h.food >= SurvivalRules.MAX_FOOD and h.saturation > 0 and health < maxHealth then
		h.regenTimer += dt
		while h.regenTimer >= SurvivalRules.FAST_REGEN_INTERVAL and health + heal < maxHealth and h.saturation > 0 do
			h.regenTimer -= SurvivalRules.FAST_REGEN_INTERVAL
			local amount = math.min(h.saturation, 6)
			heal += amount / 6
			SurvivalRules.addExhaustion(h, amount)
		end
		heal = math.min(heal, maxHealth - health)
	elseif h.food >= 18 and health < maxHealth then
		h.regenTimer += dt
		while h.regenTimer >= SurvivalRules.SLOW_REGEN_INTERVAL and health + heal < maxHealth do
			h.regenTimer -= SurvivalRules.SLOW_REGEN_INTERVAL
			heal += 1
			SurvivalRules.addExhaustion(h, SurvivalRules.EXHAUSTION.heal)
		end
	else
		h.regenTimer = 0
	end
	if h.food <= 0 then
		h.starveTimer += dt
		while h.starveTimer >= SurvivalRules.STARVE_INTERVAL do
			h.starveTimer -= SurvivalRules.STARVE_INTERVAL
			if health - damage > minHealthAfterStarve then
				damage += 1
			end
		end
	else
		h.starveTimer = 0
	end
	return heal, damage
end

function SurvivalRules.canSprint(h: Hunger): boolean
	return h.food >= SurvivalRules.SPRINT_MIN_FOOD
end

-- Fall damage for a fall of `blocks` blocks (0 if it ended in liquid).
function SurvivalRules.fallDamage(blocks: number, landedInLiquid: boolean): number
	if landedInLiquid then
		return 0
	end
	return math.max(0, math.ceil(blocks - 3 - 1e-6))
end

return SurvivalRules
