--!strict
-- Weather, Java Edition rules (ServerLevel.advanceWeatherCycle, Biome precipitation, the sky
-- and fog colours), checked against the Minecraft Wiki "Weather", "Rain", "Thunderstorm" pages.
-- Pure: the server runs `tick` 20 times a second; clients use the colour helpers.
--
--   Two flags with their own timers: rain stays on 12000-24000 ticks and off 12000-180000;
--   thunder stays on 3600-15600 and off 12000-180000. When a timer reaches 0 the flag flips and
--   a new time is drawn. A "clear weather" timer (the /weather clear command; here the debug key)
--   keeps both off while it runs.
--   The visible levels follow the flags by 0.01 a tick (5 s from clear to full rain).
--   Raining = rain level > 0.2; thundering = thunder level x rain level > 0.9 (thunder needs rain).
--   Precipitation: none in dry biomes (desert); snow where the temperature is below 0.15 (cold
--   biomes, or high up: above Java y 80 the temperature drops 0.05 per 40 blocks); rain elsewhere.
--   Lightning: during a thunderstorm every loaded chunk has a 1 in 100000 chance per tick; it hits
--   only where rain (not snow) falls on a spot open to the sky.
--   Sleeping through a rainy night ends the rain (both flags off, both timers 0).

local Weather = {}

Weather.RAIN_DELAY = { 12000, 180000 }
Weather.RAIN_DURATION = { 12000, 24000 }
Weather.THUNDER_DELAY = { 12000, 180000 }
Weather.THUNDER_DURATION = { 3600, 15600 }
Weather.LEVEL_STEP = 0.01
Weather.LIGHTNING_CHANCE = 100000 -- 1 in this many per chunk per tick
Weather.SNOW_BELOW = 0.15
Weather.JAVA_Y_OFFSET = 64 -- internal y = Java y + 64 (Config.SEA_LEVEL 126 = Java 62)

export type State = {
	clearTime: number,
	rainTime: number,
	thunderTime: number,
	raining: boolean,
	thundering: boolean,
	rainLevel: number,
	thunderLevel: number,
}

function Weather.new(): State
	-- a new world starts clear with both timers at 0 (the first tick draws them)
	return { clearTime = 0, rainTime = 0, thunderTime = 0, raining = false, thundering = false, rainLevel = 0, thunderLevel = 0 }
end

-- `rand(lo, hi)`: an integer in lo..hi (inclusive), e.g. Random:NextInteger.
export type Rand = (number, number) -> number

-- One game tick (ServerLevel.advanceWeatherCycle, doWeatherCycle on).
function Weather.tick(s: State, rand: Rand)
	if s.clearTime > 0 then
		s.clearTime -= 1
		s.thunderTime = if s.thundering then 0 else 1
		s.rainTime = if s.raining then 0 else 1
		s.thundering = false
		s.raining = false
	else
		if s.thunderTime > 0 then
			s.thunderTime -= 1
			if s.thunderTime == 0 then
				s.thundering = not s.thundering
			end
		elseif s.thundering then
			s.thunderTime = rand(Weather.THUNDER_DURATION[1], Weather.THUNDER_DURATION[2])
		else
			s.thunderTime = rand(Weather.THUNDER_DELAY[1], Weather.THUNDER_DELAY[2])
		end
		if s.rainTime > 0 then
			s.rainTime -= 1
			if s.rainTime == 0 then
				s.raining = not s.raining
			end
		elseif s.raining then
			s.rainTime = rand(Weather.RAIN_DURATION[1], Weather.RAIN_DURATION[2])
		else
			s.rainTime = rand(Weather.RAIN_DELAY[1], Weather.RAIN_DELAY[2])
		end
	end
	s.thunderLevel = math.clamp(s.thunderLevel + (if s.thundering then Weather.LEVEL_STEP else -Weather.LEVEL_STEP), 0, 1)
	s.rainLevel = math.clamp(s.rainLevel + (if s.raining then Weather.LEVEL_STEP else -Weather.LEVEL_STEP), 0, 1)
end

-- Level.isRaining / isThundering (what rain effects, lightning and sleeping check).
function Weather.isRaining(s: State): boolean
	return s.rainLevel > 0.2
end
function Weather.thunderLevel(s: State): number
	return s.thunderLevel * s.rainLevel -- Level.getThunderLevel
end
function Weather.isThundering(s: State): boolean
	return Weather.thunderLevel(s) > 0.9
end

-- The /weather command (and the Studio key): "clear" | "rain" | "thunder" for `ticks`.
function Weather.set(s: State, kind: string, ticks: number)
	if kind == "clear" then
		s.clearTime, s.rainTime, s.thunderTime = ticks, 0, 0
		s.raining, s.thundering = false, false
	else
		s.clearTime, s.rainTime, s.thunderTime = 0, ticks, ticks
		s.raining, s.thundering = true, kind == "thunder"
	end
end

-- Sleeping through the night while it rains (ServerLevel.resetWeatherCycle).
function Weather.resetCycle(s: State)
	s.rainTime, s.thunderTime = 0, 0
	s.raining, s.thundering = false, false
end

-- Biome climate (Java base temperatures; desert has no precipitation).
Weather.CLIMATE = {
	ocean = { temperature = 0.5, precipitation = true },
	frozen_ocean = { temperature = 0.0, precipitation = true },
	beach = { temperature = 0.8, precipitation = true },
	plains = { temperature = 0.8, precipitation = true },
	forest = { temperature = 0.7, precipitation = true },
	birch_forest = { temperature = 0.6, precipitation = true },
	taiga = { temperature = 0.25, precipitation = true },
	snowy_tundra = { temperature = 0.0, precipitation = true },
	desert = { temperature = 2.0, precipitation = false },
	mountains = { temperature = 0.2, precipitation = true },
} :: { [string]: { temperature: number, precipitation: boolean } }

-- Biome.getHeightAdjustedTemperature (without Java's small temperature noise above y 80).
function Weather.temperature(biomeKey: string, y: number): number
	local c = Weather.CLIMATE[biomeKey]
	local t = if c then c.temperature else 0.8
	local javaY = y - Weather.JAVA_Y_OFFSET
	if javaY > 80 then
		t -= (javaY - 80) * 0.05 / 40
	end
	return t
end

-- "none" | "rain" | "snow" at a block (Biome.getPrecipitationAt).
function Weather.precipitation(biomeKey: string, y: number): string
	local c = Weather.CLIMATE[biomeKey]
	if c and not c.precipitation then
		return "none"
	end
	return if Weather.temperature(biomeKey, y) < Weather.SNOW_BELOW then "snow" else "rain"
end

-- Java Level.updateSkyBrightness: sky darkness 0..11 from the time of day and the weather.
-- `cosAngle` = cos(celestial angle x 2 pi).
function Weather.skyDarken(cosAngle: number, rainLevel: number, thunderLevel: number): number
	local d0 = 1 - rainLevel * 5 / 16
	local d1 = 1 - (thunderLevel * rainLevel) * 5 / 16
	local d2 = 0.5 + 2 * math.clamp(cosAngle, -0.25, 0.25)
	return math.floor((1 - d2 * d0 * d1) * 11)
end

-- Java ClientLevel.getSkyColor's weather part: the sky turns grey with rain, dark with thunder.
function Weather.skyColor(r: number, g: number, b: number, rainLevel: number, thunderLevel: number): (number, number, number)
	if rainLevel > 0 then
		local grey = (r * 0.3 + g * 0.59 + b * 0.11) * 0.6
		local f = 1 - rainLevel * 0.75
		r, g, b = r * f + grey * (1 - f), g * f + grey * (1 - f), b * f + grey * (1 - f)
	end
	local thunder = thunderLevel * rainLevel
	if thunder > 0 then
		local grey = (r * 0.3 + g * 0.59 + b * 0.11) * 0.2
		local f = 1 - thunder * 0.75
		r, g, b = r * f + grey * (1 - f), g * f + grey * (1 - f), b * f + grey * (1 - f)
	end
	return r, g, b
end

-- Java FogRenderer: fog darkens with rain (blue a little less) and with thunder.
function Weather.fogColor(r: number, g: number, b: number, rainLevel: number, thunderLevel: number): (number, number, number)
	if rainLevel > 0 then
		local f, fb = 1 - rainLevel * 0.5, 1 - rainLevel * 0.4
		r, g, b = r * f, g * f, b * fb
	end
	local thunder = thunderLevel * rainLevel
	if thunder > 0 then
		local f = 1 - thunder * 0.5
		r, g, b = r * f, g * f, b * f
	end
	return r, g, b
end

-- Java ClientLevel.getCloudColor's weather part.
function Weather.cloudColor(r: number, g: number, b: number, rainLevel: number, thunderLevel: number): (number, number, number)
	if rainLevel > 0 then
		local grey = (r * 0.3 + g * 0.59 + b * 0.11) * 0.6
		local f = 1 - rainLevel * 0.95
		r, g, b = r * f + grey * (1 - f), g * f + grey * (1 - f), b * f + grey * (1 - f)
	end
	local thunder = thunderLevel * rainLevel
	if thunder > 0 then
		local grey = (r * 0.3 + g * 0.59 + b * 0.11) * 0.2
		local f = 1 - thunder * 0.95
		r, g, b = r * f + grey * (1 - f), g * f + grey * (1 - f), b * f + grey * (1 - f)
	end
	return r, g, b
end

-- Save format (world meta).
function Weather.encode(s: State): { number }
	return { s.clearTime, s.rainTime, s.thunderTime, if s.raining then 1 else 0, if s.thundering then 1 else 0 }
end
function Weather.decode(t: any): State
	local s = Weather.new()
	if typeof(t) == "table" then
		local function n(i: number, hi: number): number
			local v = t[i]
			return if typeof(v) == "number" and v == v then math.clamp(math.floor(v), 0, hi) else 0
		end
		s.clearTime, s.rainTime, s.thunderTime = n(1, 1e9), n(2, 1e9), n(3, 1e9)
		s.raining, s.thundering = t[4] == 1, t[5] == 1
		-- already raining when the world loads: no fade-in (Java saves the flags, levels follow)
		s.rainLevel = if s.raining then 1 else 0
		s.thunderLevel = if s.thundering then 1 else 0
	end
	return s
end

return Weather
