--!strict
-- Java Edition sky-light rules that depend on the time of day (pure, shared).
--
-- There is no light engine yet (no torches), so a block's sky light is approximated as 15 when it
-- is open to the sky and 0 otherwise (caves). Everything below follows the Java formulas:
--
--   celestialAngle(t)  d = frac(t/24000 - 0.25); e = 0.5 - cos(d*pi)/2; angle = (2d + e) / 3
--   skyDarken(t)       k = clamp(1 - (cos(angle*2pi)*2 + 0.5), 0, 1); floor(k * 11)   (0 day, 11 night)
--   rawBrightness      max(skyLight - skyDarken, blockLight)
--   magicBrightness(l) f = l/15; f / (4 - 3f)        ("light level dependent magic value", 0..1)
--
-- Mobs use these for: spider neutrality (magic >= 0.5), undead burning and voidling daylight
-- teleports (magic > 0.5 plus a random check), and hostile spawning (see monsterCanSpawn).

local SkyLight = {}

function SkyLight.celestialAngle(timeOfDay: number): number
	local d = (timeOfDay / 24000 - 0.25) % 1
	local e = 0.5 - math.cos(d * math.pi) / 2
	return (d * 2 + e) / 3
end

function SkyLight.skyDarken(timeOfDay: number): number
	local a = SkyLight.celestialAngle(timeOfDay)
	local k = math.clamp(1 - (math.cos(a * math.pi * 2) * 2 + 0.5), 0, 1)
	return math.floor(k * 11)
end

-- Raw light level 0..15 of a block (block light is always 0 until torches exist).
function SkyLight.rawBrightness(skyExposed: boolean, timeOfDay: number, blockLight: number?): number
	local sky = if skyExposed then 15 - SkyLight.skyDarken(timeOfDay) else 0
	return math.max(sky, blockLight or 0)
end

function SkyLight.magicBrightness(level: number): number
	local f = level / 15
	return f / (4 - 3 * f)
end

-- Java Monster.isDarkEnoughToSpawn with block light 0:
--   fail if skyLight > random(0..31); then pass if rawBrightness <= random(0..7).
-- `r32` and `r8` are the two random integers (injected so tests are deterministic).
function SkyLight.monsterCanSpawn(skyExposed: boolean, timeOfDay: number, r32: number, r8: number): boolean
	local sky = if skyExposed then 15 else 0
	if sky > r32 then
		return false
	end
	return SkyLight.rawBrightness(skyExposed, timeOfDay) <= r8
end

-- Is it "day" for the sun-burning / daylight-teleport checks (Java Level.isDay: skyDarken < 4)?
function SkyLight.isDay(timeOfDay: number): boolean
	return SkyLight.skyDarken(timeOfDay) < 4
end

return SkyLight
