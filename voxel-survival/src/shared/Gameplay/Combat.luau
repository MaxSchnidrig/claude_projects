--!strict
-- Pure combat rules, Java Edition values (minecraft.wiki: Damage, Attack cooldown, Knockback).
--
--   attack cooldown  T = 20 / attackSpeed ticks; charge = clamp((ticksSinceSwing + 0.5) / T, 0, 1)
--                    damage = base * (0.2 + charge^2 * 0.8)
--   critical hit     charge > 0.9, falling (fall distance > 0), not on ground, not sprinting,
--                    not in water/lava, not climbing  ->  damage * 1.5
--   knockback        strength 0.4 blocks/tick from any attack (+0.5 for a full-strength sprint hit):
--                    v = (vx/2 + dx*s, onGround and min(0.4, vy/2 + s) or vy, vz/2 + dz*s)
--                    where (dx, dz) is the unit direction from the attacker to the target
--   invulnerability  0.5 s (10 ticks) after a hit. A stronger hit during it deals only the
--                    difference and gives no knockback; a weaker or equal one does nothing.
--   armor            damage * (1 - clamp(max(armor/5, armor - damage/2), 0, 20) / 25)  (toughness 0)
--   explosions       impact = 1 - distance / (2 * power)
--                    damage = floor((impact^2 + impact) / 2 * 7 * 2 * power + 1)
--
-- Velocities here are blocks/tick (Java units); multiply by 20 for blocks/s.

local ItemRegistry = require(script.Parent.Parent.Items.ItemRegistry)

local Combat = {}

Combat.TICKS_PER_SECOND = 20
Combat.HAND_DAMAGE = 1
Combat.HAND_ATTACK_SPEED = 4 -- attacks/s at full charge (0.25 s)
Combat.MELEE_REACH = 3 -- blocks from the eye (Java survival entity reach)
Combat.CRIT_MIN_CHARGE = 0.9
Combat.CRIT_MULTIPLIER = 1.5
Combat.KNOCKBACK = 0.4 -- blocks/tick
Combat.SPRINT_KNOCKBACK = 0.5
Combat.INVULNERABLE_SECONDS = 0.5
-- Mob melee: the attacker's box grown horizontally by sqrt(2.04) - 0.6 must touch the target's box.
Combat.MOB_ATTACK_REACH = math.sqrt(2.04) - 0.6

-- (base damage, attack speed) of the held item.
function Combat.attackStats(itemKey: string?): (number, number)
	local def = ItemRegistry.get(itemKey)
	local tool = def and def.tool
	if tool and tool.attack then
		return tool.attack, tool.attackSpeed or Combat.HAND_ATTACK_SPEED
	end
	return Combat.HAND_DAMAGE, Combat.HAND_ATTACK_SPEED
end

-- Seconds until a full-strength hit.
function Combat.cooldownSeconds(attackSpeed: number): number
	return 1 / attackSpeed
end

-- Attack strength 0..1 after `sinceSwing` seconds.
function Combat.charge(sinceSwing: number, attackSpeed: number): number
	local ticks = math.floor(sinceSwing * Combat.TICKS_PER_SECOND + 1e-6)
	return math.clamp((ticks + 0.5) / (Combat.TICKS_PER_SECOND / attackSpeed), 0, 1)
end

function Combat.scaledDamage(base: number, charge: number): number
	return base * (0.2 + charge * charge * 0.8)
end

export type CritState = {
	charge: number,
	falling: boolean, -- moving down since leaving the ground (fall distance > 0)
	onGround: boolean,
	sprinting: boolean,
	inLiquid: boolean,
	climbing: boolean?,
}
function Combat.isCrit(s: CritState): boolean
	return s.charge > Combat.CRIT_MIN_CHARGE and s.falling and not s.onGround and not s.sprinting
		and not s.inLiquid and not s.climbing
end

-- Durability used by hitting a mob with this item: weapons (swords) 1, tools 2, others 0.
function Combat.hitDurabilityCost(itemKey: string?): number
	local def = ItemRegistry.get(itemKey)
	local tool = def and def.tool
	if not tool then
		return 0
	end
	if tool.kind == "sword" then
		return 1
	elseif tool.kind == "pickaxe" or tool.kind == "axe" or tool.kind == "shovel" or tool.kind == "hoe" then
		return 2
	end
	return 0
end

-- Java LivingEntity.knockback. (dx, dz): direction from the attacker to the target (any length).
function Combat.knockback(vx: number, vy: number, vz: number, dx: number, dz: number, strength: number, onGround: boolean): (number, number, number)
	local len = math.sqrt(dx * dx + dz * dz)
	if strength <= 0 then
		return vx, vy, vz
	end
	if len < 1e-5 then
		dx, dz, len = 1, 0, 1
	end
	dx, dz = dx / len * strength, dz / len * strength
	local ny = if onGround then math.min(0.4, vy / 2 + strength) else vy
	return vx / 2 + dx, ny, vz / 2 + dz
end

-- Invulnerability bookkeeping shared by players and mobs.
export type HurtState = { invulnUntil: number, lastHurt: number }
-- Returns the damage actually dealt and whether it was a fresh hit (knockback + hurt effects).
function Combat.applyInvulnerability(s: HurtState, amount: number, now: number): (number, boolean)
	if amount <= 0 then
		return 0, false
	end
	if now < s.invulnUntil then
		if amount <= s.lastHurt then
			return 0, false
		end
		local dealt = amount - s.lastHurt
		s.lastHurt = amount
		return dealt, false
	end
	s.lastHurt = amount
	s.invulnUntil = now + Combat.INVULNERABLE_SECONDS
	return amount, true
end

-- Java CombatRules.getDamageAfterAbsorb: armour points cut damage by up to 80 %, less against
-- big hits; toughness (diamond) makes big hits count less.
function Combat.armorReduce(damage: number, armor: number, toughness: number?): number
	if armor <= 0 then
		return damage
	end
	local f = 2 + (toughness or 0) / 4
	local points = math.clamp(armor - damage / f, armor * 0.2, 20)
	return damage * (1 - points / 25)
end

-- Java ShieldItem / LivingEntity.isDamageSourceBlocked: blocked when the damage comes from in
-- front (the direction from the source to the player points against the view direction).
function Combat.shieldBlocks(lookX: number, lookZ: number, playerX: number, playerZ: number, srcX: number, srcZ: number): boolean
	local dx, dz = playerX - srcX, playerZ - srcZ
	local len = math.sqrt(dx * dx + dz * dz)
	if len < 1e-6 then
		return false
	end
	return (dx / len) * lookX + (dz / len) * lookZ < 0
end

-- Java BowItem.getPowerForTime: draw time (ticks) -> 0..1. Under 0.1 the bow doesn't shoot.
function Combat.bowPower(ticks: number): number
	local f = ticks / 20
	f = (f * f + f * 2) / 3
	return math.min(f, 1)
end
Combat.CROSSBOW_CHARGE_TICKS = 25 -- Java: 1.25 s without Quick Charge
Combat.CROSSBOW_SPEED = 3.15 -- blocks/tick
Combat.BOW_SPEED = 3.0 -- blocks/tick at full power
Combat.ARROW_DAMAGE = 2.0

function Combat.explosionDamage(power: number, distance: number): number
	local impact = 1 - distance / (2 * power)
	if impact <= 0 then
		return 0
	end
	return math.floor((impact * impact + impact) / 2 * 7 * 2 * power + 1)
end

return Combat
