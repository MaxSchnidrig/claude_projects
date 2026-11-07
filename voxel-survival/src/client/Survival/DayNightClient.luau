--!strict
-- Applies the world time locally every frame: sun/moon position (Lighting.ClockTime), and
-- brightness, ambient light and fog colour following a daylight curve. Nothing is replicated per
-- frame; time comes from the server's reference attributes + workspace:GetServerTimeNow().
--
-- Ticks -> clock: 0 = 06:00 sunrise, 6000 = noon, 12000 = 18:00, 18000 = midnight.
-- Daylight: full 0..12000, fades 12000..13800 (dusk), dark 13800..22200, rises 22200..24000.

local Lighting = game:GetService("Lighting")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local DayNightClient = {}
DayNightClient.timeOfDay = 0

local DAY = {
	brightness = 2.4,
	outdoor = Color3.fromRGB(128, 128, 134),
	ambient = Color3.fromRGB(70, 70, 76),
	fog = Color3.fromRGB(170, 200, 235),
}
-- Java nights: sky light drops from 15 to 4 (not 0), so the surface stays readable in moonlight.
local NIGHT = {
	brightness = 0.75,
	outdoor = Color3.fromRGB(66, 70, 98),
	ambient = Color3.fromRGB(38, 40, 54),
	fog = Color3.fromRGB(22, 26, 44),
}

local function daylight(t: number): number
	if t < 12000 then
		return 1
	elseif t < 13800 then
		return 1 - (t - 12000) / 1800
	elseif t < 22200 then
		return 0
	else
		return (t - 22200) / 1800
	end
end

function DayNightClient.ticks(): number?
	local ref = ReplicatedStorage:GetAttribute("DayTicksRef")
	local t0 = ReplicatedStorage:GetAttribute("DayTimeRef")
	local rate = ReplicatedStorage:GetAttribute("DayTicksPerSecond")
	if typeof(ref) ~= "number" or typeof(t0) ~= "number" or typeof(rate) ~= "number" then
		return nil
	end
	return ref + (workspace:GetServerTimeNow() - t0) * rate
end

function DayNightClient.init()
	Lighting.GlobalShadows = true
	RunService.RenderStepped:Connect(function()
		local ticks = DayNightClient.ticks()
		if not ticks then
			return
		end
		local t = ticks % 24000
		DayNightClient.timeOfDay = t
		Lighting.ClockTime = (6 + t / 1000) % 24
		local d = daylight(t)
		Lighting.Brightness = NIGHT.brightness + (DAY.brightness - NIGHT.brightness) * d
		Lighting.OutdoorAmbient = NIGHT.outdoor:Lerp(DAY.outdoor, d)
		Lighting.Ambient = NIGHT.ambient:Lerp(DAY.ambient, d)
		Lighting.FogColor = NIGHT.fog:Lerp(DAY.fog, d)
	end)
end

-- "06:30" style clock for the overlay.
function DayNightClient.clockText(): string
	local h = (6 + DayNightClient.timeOfDay / 1000) % 24
	return string.format("%02d:%02d", math.floor(h), math.floor((h % 1) * 60))
end

return DayNightClient
