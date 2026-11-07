--!strict
-- Pure combat rules (classic values).
--   melee: damage of the held item (hand 1), scaled by how charged the attack is:
--          damage * (0.2 + charge^2 * 0.8), charge = time since last swing / cooldown (max 1)
--   explosions: impact = 1 - distance / (2 * power)
--               damage = floor((impact^2 + impact) / 2 * 7 * 2 * power + 1)

local ItemRegistry = require(script.Parent.Parent.Items.ItemRegistry)

local Combat = {}

Combat.HAND_DAMAGE = 1
Combat.HAND_COOLDOWN = 0.25
Combat.MELEE_REACH = 3 -- blocks from the eye (classic survival)
Combat.KNOCKBACK_HORIZONTAL = 7 -- blocks/s given to a hit target
Combat.KNOCKBACK_UP = 5

function Combat.attackStats(itemKey: string?): (number, number)
	local def = ItemRegistry.get(itemKey)
	local tool = def and def.tool
	if tool and tool.attack then
		return tool.attack, tool.attackCooldown or 1
	end
	return Combat.HAND_DAMAGE, Combat.HAND_COOLDOWN
end

function Combat.scaledDamage(base: number, sinceLastSwing: number, cooldown: number): number
	local charge = math.clamp(sinceLastSwing / cooldown, 0, 1)
	return base * (0.2 + charge * charge * 0.8)
end

function Combat.explosionDamage(power: number, distance: number): number
	local impact = 1 - distance / (2 * power)
	if impact <= 0 then
		return 0
	end
	return math.floor((impact * impact + impact) / 2 * 7 * 2 * power + 1)
end

return Combat
