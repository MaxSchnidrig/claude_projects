--!strict
-- Animal rules (Java Edition Animal / AgeableMob / Sheep, checked against the Minecraft Wiki
-- "Breeding", "Baby", "Sheep" pages). Pure, shared: the server runs them, tests check them, the
-- client asks `wants` before sending a right-click on a mob.
--
--   food       cows and sheep: wheat; pigs: carrot, potato, beetroot; chickens: wheat, pumpkin,
--              melon and beetroot seeds. Animals follow a player holding it within 10 blocks.
--   love       feeding an adult that may breed: 600 ticks of love mode (hearts). Two animals of a
--              kind in love within 8 blocks walk to each other; after 60 ticks together (within
--              3 blocks) a baby appears, both parents can't breed for 6000 ticks (5 minutes).
--   babies     start at age -24000 (20 minutes) and grow up by 1 a tick; feeding one takes 10 % off
--              the time left (whole seconds); a baby sheep eating grass grows 60 s at once.
--              Babies follow an adult of their kind. Naturally spawned animals: 5 % are babies.
--   sheep      natural colours: white 81.836 %, black / gray / light gray 5 % each, brown 3 %,
--              pink 0.164 %. Shears: 1-3 wool of its colour, then sheared until it eats grass
--              (1 in 500 every other tick for adults, 1 in 25... see GRAZE_CHANCE). A dye colours
--              an unsheared adult or baby. A lamb takes the dye mix of its parents' colours if the
--              two dyes craft into one (red + yellow -> orange...), else a random parent's colour.

local Animals = {}

Animals.COLORS = { "white", "orange", "magenta", "light_blue", "yellow", "lime", "pink", "gray", "light_gray",
	"cyan", "purple", "blue", "brown", "green", "red", "black" }
local colorIndex: { [string]: number } = {}
for i, c in Animals.COLORS do
	colorIndex[c] = i
end
Animals.colorIndex = colorIndex

Animals.FOOD = {
	cow = { wheat = true },
	sheep = { wheat = true },
	pig = { carrot = true, potato = true, beetroot = true },
	chicken = { wheat_seeds = true, pumpkin_seeds = true, melon_seeds = true, beetroot_seeds = true },
} :: { [string]: { [string]: boolean } }

Animals.BABY_AGE = -24000
Animals.PARENT_COOLDOWN = 6000
Animals.LOVE_TICKS = 600
Animals.BREED_TICKS = 60
Animals.BREED_RANGE = 8 -- blocks: how far a partner is searched for
Animals.BREED_DISTANCE = 3 -- blocks: close enough to make a baby
Animals.TEMPT_RANGE = 10
Animals.BABY_CHANCE = 0.05 -- natural spawns
-- Sheep EatBlockGoal: a 1 in 1000 chance a tick for adults (1 in 500 every other tick), 1 in 50
-- for lambs; eating takes 40 ticks
Animals.GRAZE_CHANCE_ADULT = 1000
Animals.GRAZE_CHANCE_BABY = 50
Animals.GRAZE_TICKS = 40
Animals.GRAZE_GROW_SECONDS = 60
-- Java goal speed modifiers (TemptGoal / FollowParentGoal per animal; BreedGoal 1.0 for all)
Animals.TEMPT_SPEED = { cow = 1.25, pig = 1.2, sheep = 1.1, chicken = 1.0 } :: { [string]: number }
Animals.FOLLOW_SPEED = { cow = 1.25, pig = 1.1, sheep = 1.1, chicken = 1.1 } :: { [string]: number }
Animals.BREED_SPEED = 1.0
Animals.TEMPT_STOP = 2.5 -- blocks: close enough to the player (TemptGoal: distance^2 < 6.25)
Animals.FOLLOW_MIN = 3 -- blocks: a baby stays this close to an adult (FollowParentGoal: 9)
Animals.FOLLOW_MAX = 16

function Animals.isAnimal(key: string): boolean
	return Animals.FOOD[key] ~= nil
end

function Animals.isFood(key: string, item: string?): boolean
	local f = Animals.FOOD[key]
	return f ~= nil and item ~= nil and f[item] == true
end

-- Would right-clicking this animal with this item do something? (The client checks this before
-- sending; the server decides for real.) `baby`, `sheared`: the mob's state as the client sees it.
function Animals.wants(key: string, item: string?, baby: boolean, sheared: boolean): boolean
	if not item then
		return false
	end
	if Animals.isFood(key, item) then
		return true
	end
	if key == "cow" and item == "bucket" and not baby then
		return true
	end
	if key == "sheep" then
		if item == "shears" then
			return not baby and not sheared
		end
		local dye = string.match(item, "^(.+)_dye$")
		if dye and colorIndex[dye] and not sheared then
			return true
		end
	end
	return false
end

-- AgeableMob.getSpeedUpSecondsWhenFeeding: 10 % of the time left, in whole seconds.
function Animals.feedSpeedUpTicks(age: number): number
	if age >= 0 then
		return 0
	end
	return math.floor(-age / 20 * 0.1) * 20
end

-- Sheep.getRandomSheepColor (natural spawns). `r100` 0..99, `r500` 0..499.
function Animals.naturalSheepColor(r100: number, r500: number): string
	if r100 < 5 then
		return "black"
	elseif r100 < 10 then
		return "gray"
	elseif r100 < 15 then
		return "light_gray"
	elseif r100 < 18 then
		return "brown"
	end
	return if r500 == 0 then "pink" else "white"
end

-- Sheep.getOffspringColor: the dye the two parents' dyes craft into, or a random parent's.
-- `mix(a, b)` returns the crafted colour or nil (Items/Crafting); `coin` 0 or 1.
function Animals.offspringColor(a: string, b: string, mix: (string, string) -> string?, coin: number): string
	local m = mix(a, b)
	if m then
		return m
	end
	return if coin == 0 then a else b
end

return Animals
