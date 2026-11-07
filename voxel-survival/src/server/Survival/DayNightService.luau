--!strict
-- World time. 24000 ticks per day at 20 ticks/s (Config.DAY_LENGTH_SECONDS = 20 min):
--   0 sunrise, 6000 noon, 12000 sunset, 13800 night, 18000 midnight, 22200 dawn.
-- Nothing is replicated per frame: the server publishes a reference point (ticks at a server
-- time) as attributes, and everyone computes the current time from workspace:GetServerTimeNow().

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared.Config)

local DayNightService = {}
local TICKS_PER_DAY = 24000

local function rate(): number
	return TICKS_PER_DAY / Config.DAY_LENGTH_SECONDS
end

local function publish(ticks: number)
	ReplicatedStorage:SetAttribute("DayTicksRef", ticks)
	ReplicatedStorage:SetAttribute("DayTimeRef", workspace:GetServerTimeNow())
	ReplicatedStorage:SetAttribute("DayTicksPerSecond", rate())
end

-- Current tick count since the world started (not wrapped).
function DayNightService.ticks(): number
	local ref = ReplicatedStorage:GetAttribute("DayTicksRef") :: number
	local t0 = ReplicatedStorage:GetAttribute("DayTimeRef") :: number
	return ref + (workspace:GetServerTimeNow() - t0) * rate()
end

-- Time of day 0..23999.
function DayNightService.timeOfDay(): number
	return DayNightService.ticks() % TICKS_PER_DAY
end

-- True between dusk and dawn (hostile mobs spawn at night in phase 5).
function DayNightService.isNight(): boolean
	local t = DayNightService.timeOfDay()
	return t >= 13000 and t < 23000
end

function DayNightService.addTicks(n: number)
	publish(DayNightService.ticks() + n)
end

function DayNightService.init()
	publish(Config.START_TIME_TICKS) -- phase 6: restore the saved world time
end

return DayNightService
