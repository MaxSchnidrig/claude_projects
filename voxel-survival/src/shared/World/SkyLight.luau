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

-- The current weather (World/Weather levels, 0..1), set by the server's WeatherService (and the
-- client's WeatherClient): rain and thunder darken the sky (Java Level.updateSkyBrightness).
SkyLight.rainLevel = 0
SkyLight.thunderLevel = 0 -- the raw thunder level (Weather multiplies it by the rain level)

function SkyLight.celestialAngle(timeOfDay: number): number
	local d = (timeOfDay / 24000 - 0.25) % 1
	local e = 0.5 - math.cos(d * math.pi) / 2
	return (d * 2 + e) / 3
end

function SkyLight.skyDarken(timeOfDay: number): number
	-- Java: (int)((1 - d2 x d0 x d1) x 11), d2 the daylight part, d0 / d1 the rain / thunder parts
	local a = SkyLight.celestialAngle(timeOfDay)
	local rain = SkyLight.rainLevel
	local d0 = 1 - rain * 5 / 16
	local d1 = 1 - (SkyLight.thunderLevel * rain) * 5 / 16
	local d2 = 0.5 + 2 * math.clamp(math.cos(a * math.pi * 2), -0.25, 0.25)
	return math.floor((1 - d2 * d0 * d1) * 11 + 1e-9)
end

-- Level.isThundering (thunder level x rain level above 0.9).
function SkyLight.thundering(): boolean
	return SkyLight.thunderLevel * SkyLight.rainLevel > 0.9
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
-- During a thunderstorm the sky counts as 10 darker (Java getMaxLocalRawBrightness(pos, 10)),
-- so monsters can spawn in daylight.
function SkyLight.monsterCanSpawn(skyExposed: boolean, timeOfDay: number, r32: number, r8: number): boolean
	local sky = if skyExposed then 15 else 0
	if sky > r32 then
		return false
	end
	local raw = if SkyLight.thundering() then (if skyExposed then 15 - 10 else 0) else SkyLight.rawBrightness(skyExposed, timeOfDay)
	return raw <= r8
end

-- Is it "day" for the sun-burning / daylight-teleport checks (Java Level.isDay: skyDarken < 4)?
function SkyLight.isDay(timeOfDay: number): boolean
	return SkyLight.skyDarken(timeOfDay) < 4
end

return SkyLight
