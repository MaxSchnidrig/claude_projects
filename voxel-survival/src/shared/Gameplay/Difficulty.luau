--!strict
-- Difficulty (Java Edition rules; pure, tested headless). The server's DifficultyService holds
-- the world's current difficulty; this module is the rules.
--
--   peaceful  no hostile mobs (none spawn, existing ones vanish); health comes back 1 per second
--             and food 1 point per half second; hunger never drops (exhaustion only eats
--             saturation); mob damage is 0
--   easy      mob damage: min(amount / 2 + 1, amount); starving stops at 10 health (5 hearts)
--   normal    mob damage as is; starving stops at 1 health (half a heart)
--   hard      mob damage x 1.5; starving can kill
--   Hardcore  (a world option, not a difficulty): always Hard, one life
--
-- "Mob damage" is everything a living mob causes (Java's scalesWithDifficulty for damage
-- caused by a living non-player): bites and hits, its arrows, a Sneaker's explosion. TNT, falls,
-- fire, lava, drowning and starving are the same on every difficulty.
-- The difficulty id (0..3) also feeds Java formulas elsewhere (fire spread, skeleton arrows).

local Difficulty = {}

export type Name = "peaceful" | "easy" | "normal" | "hard"

Difficulty.ORDER = { "peaceful", "easy", "normal", "hard" } :: { Name }
Difficulty.DEFAULT = "normal" :: Name
Difficulty.LABEL = { peaceful = "Peaceful", easy = "Easy", normal = "Normal", hard = "Hard" } :: { [string]: string }
local ID = { peaceful = 0, easy = 1, normal = 2, hard = 3 } :: { [string]: number }

function Difficulty.valid(name: any): boolean
	return typeof(name) == "string" and ID[name] ~= nil
end

-- A saved / received value made safe: unknown -> the default.
function Difficulty.sanitize(name: any): Name
	return if Difficulty.valid(name) then name :: Name else Difficulty.DEFAULT
end

function Difficulty.id(name: Name): number
	return ID[name] or 2
end

-- The next one in the list (the settings button cycles like Java's).
function Difficulty.next(name: Name): Name
	local i = ID[name] or 2
	return Difficulty.ORDER[(i + 1) % 4 + 1]
end

-- Java Player.hurt for damage that scales with difficulty. 0 = no damage at all.
function Difficulty.scaleMobDamage(name: Name, amount: number): number
	if name == "peaceful" then
		return 0
	elseif name == "easy" then
		return math.min(amount / 2 + 1, amount)
	elseif name == "hard" then
		return amount * 3 / 2
	end
	return amount
end

-- (Starvation per difficulty: Gameplay/SurvivalRules.starves, a copy of Java's FoodData.)

function Difficulty.hostileMobs(name: Name): boolean
	return name ~= "peaceful"
end

-- (Peaceful extras, Java Player.aiStep - every 20th tick +1 health, every 10th +1 hunger - are in
-- server/Survival/SurvivalService.)

return Difficulty
