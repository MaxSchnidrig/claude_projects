--!strict
-- World time on the client: lighting, fog and the sky.
--
-- Ticks -> clock: 0 = 06:00 sunrise, 6000 = noon, 12000 = 18:00, 18000 = midnight.
--
--   lighting   Brightness / ambient follow a daylight curve; no global shadows (terrain light and
--              ambient occlusion are baked into the meshes, Java style)
--   fog        linear fog ending at the render distance; its colour is the horizon colour
--   sky        a dome of our own: a closed box of panels around the camera just beyond the fog
--              end is fully fogged, so the horizon is exactly the fog colour everywhere (Roblox's
--              skybox, which fog doesn't touch, is never visible); a large glowing "zenith" plane
--              high above the camera shows the sky colour, and fog fades it into the horizon
--              colour with distance, giving a smooth gradient. The plane always reaches past the
--              fog end, so its edge can't show as a line
--   sun/moon   square, on a circle around the camera at the time-of-day angle; hidden when a block
--              is between the camera and them. Stars fade in at night.
--   clouds     see Clouds.luau
-- Colours: ROCRAFT's own palette, tuned to the familiar classic look (blue day sky, warm sunset
-- horizon, dark night).

local Lighting = game:GetService("Lighting")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared.Config)

local DayNightClient = {}
DayNightClient.timeOfDay = 0

local BS = Config.BLOCK_SIZE

local DAY = {
	brightness = 2.0,
	outdoor = Color3.fromRGB(150, 150, 156),
	ambient = Color3.fromRGB(120, 120, 126),
	sky = Color3.fromRGB(122, 168, 255),
	fog = Color3.fromRGB(190, 214, 255),
}
-- Night: dark, but surfaces stay readable (moonlight).
local NIGHT = {
	brightness = 0.75,
	outdoor = Color3.fromRGB(66, 70, 98),
	ambient = Color3.fromRGB(46, 48, 64),
	sky = Color3.fromRGB(4, 6, 16),
	fog = Color3.fromRGB(10, 12, 26),
}
local SUNSET_FOG = Color3.fromRGB(236, 132, 70)

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

-- 0..1 how much sunrise/sunset colour the horizon shows.
local function sunsetGlow(t: number): number
	local function bump(center: number, width: number): number
		local d = math.abs(t - center)
		d = math.min(d, 24000 - d)
		return math.max(0, 1 - d / width)
	end
	return math.max(bump(12900, 1100), bump(23100, 1100))
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

local function skyPart(name: string, size: Vector3, color: Color3): Part
	local p = Instance.new("Part")
	p.Name = name
	p.Anchored = true
	p.CanCollide = false
	p.CanQuery = false
	p.CanTouch = false
	p.CastShadow = false
	p.Material = Enum.Material.Neon
	p.Color = color
	p.Size = size
	return p
end

-- Is the straight line from the camera towards `dir` blocked by a block within `dist` studs?
local blockAt: ((number, number, number) -> number?)? = nil
local isOpaque: { boolean }? = nil
local function occluded(from: Vector3, dir: Vector3, dist: number): boolean
	local gb, op = blockAt, isOpaque
	if not gb or not op then
		return false
	end
	local step = BS * 0.5
	local n = math.floor(dist / step)
	for i = 1, n do
		local p = from + dir * (i * step)
		local id = gb(math.floor(p.X / BS), math.floor(p.Y / BS), math.floor(p.Z / BS))
		if id and op[id + 1] then
			return true
		end
	end
	return false
end

function DayNightClient.setBlockSource(fn: (number, number, number) -> number?, opaque: { boolean })
	blockAt = fn
	isOpaque = opaque
end

function DayNightClient.init()
	Lighting.GlobalShadows = false
	Lighting.EnvironmentDiffuseScale = 0
	Lighting.EnvironmentSpecularScale = 0
	-- hide Roblox's own sun, moon and stars: ours are drawn below
	local sky = Lighting:FindFirstChildOfClass("Sky")
	if not sky then
		sky = Instance.new("Sky")
		sky.Parent = Lighting
	end
	(sky :: Sky).CelestialBodiesShown = false;
	(sky :: Sky).StarCount = 0

	local folder = Instance.new("Folder")
	folder.Name = "SkyDome"
	folder.Parent = workspace
	local zenith = skyPart("Zenith", Vector3.new(2000, 1, 2000), DAY.sky)
	zenith.Parent = folder
	-- fog shell: 6 panels, plain material (fully fogged = exactly the fog colour)
	local shell: { { part: Part, normal: Vector3 } } = {}
	for _, n in { Vector3.xAxis, -Vector3.xAxis, Vector3.yAxis, -Vector3.yAxis, Vector3.zAxis, -Vector3.zAxis } do
		local p = skyPart("Shell", Vector3.new(1, 1, 1), Color3.new(0, 0, 0))
		p.Material = Enum.Material.SmoothPlastic
		p.Parent = folder
		table.insert(shell, { part = p, normal = n })
	end
	local sun = skyPart("Sun", Vector3.new(1, 1, 1), Color3.fromRGB(255, 244, 196))
	sun.Parent = folder
	local moon = skyPart("Moon", Vector3.new(1, 1, 1), Color3.fromRGB(214, 220, 236))
	moon.Parent = folder
	-- stars: small squares just under the zenith plane
	local stars: { { part: Part, offset: Vector3 } } = {}
	local rng = Random.new(1337)
	for _ = 1, 140 do
		local s = skyPart("Star", Vector3.new(1, 0.2, 1), Color3.fromRGB(255, 255, 255))
		s.Transparency = 1
		s.Parent = folder
		table.insert(stars, { part = s, offset = Vector3.new(rng:NextNumber(-1, 1), 0, rng:NextNumber(-1, 1)) })
	end

	local occAcc, sunHidden, moonHidden = 0, false, false
	RunService.RenderStepped:Connect(function(dt)
		local ticks = DayNightClient.ticks()
		if not ticks then
			return
		end
		local t = ticks % 24000
		DayNightClient.timeOfDay = t
		Lighting.ClockTime = (6 + t / 1000) % 24
		local d = daylight(t)
		local glow = sunsetGlow(t)
		Lighting.Brightness = NIGHT.brightness + (DAY.brightness - NIGHT.brightness) * d
		Lighting.OutdoorAmbient = NIGHT.outdoor:Lerp(DAY.outdoor, d)
		Lighting.Ambient = NIGHT.ambient:Lerp(DAY.ambient, d)
		local fog = NIGHT.fog:Lerp(DAY.fog, d):Lerp(SUNSET_FOG, glow * 0.75)
		Lighting.FogColor = fog
		local skyColor = NIGHT.sky:Lerp(DAY.sky, d)

		local cam = workspace.CurrentCamera
		if not cam then
			return
		end
		local camPos = cam.CFrame.Position
		local fogStart = math.max(Lighting.FogStart, 60)
		-- neon renders brighter than its colour; scale down to look like the plain sky colour
		zenith.Color = Color3.new(skyColor.R * 0.72, skyColor.G * 0.72, skyColor.B * 0.72)
		local fogEnd = math.max(Lighting.FogEnd, fogStart + 10)
		local zH = fogStart * 0.9
		-- reach past the fog end in every direction (Parts are at most 2048 studs)
		local half = math.min(1024, math.sqrt(math.max(fogEnd * fogEnd - zH * zH, 0)) * 1.25 + 20)
		zenith.Size = Vector3.new(half * 2, 1, half * 2)
		zenith.CFrame = CFrame.new(camPos + Vector3.new(0, zH, 0))
		local R = math.min(1000, fogEnd * 1.05 + 10)
		for _, sp in shell do
			local n = sp.normal
			sp.part.Size = Vector3.new(
				if n.X ~= 0 then 1 else R * 2 + 2,
				if n.Y ~= 0 then 1 else R * 2 + 2,
				if n.Z ~= 0 then 1 else R * 2 + 2
			)
			sp.part.CFrame = CFrame.new(camPos + n * R)
			sp.part.Color = fog
		end

		-- sun and moon: square, 20 blocks wide at the classic scale, on a circle (radius R) that
		-- turns with the time of day (sunrise in the east = +X)
		local orbit = fogStart * 0.5
		local angle = (t / 24000) * math.pi * 2 -- 0 = sunrise
		local sunDir = Vector3.new(math.cos(angle), math.sin(angle), 0)
		local size = orbit * 0.16
		sun.Size = Vector3.new(size, size, 0.2)
		moon.Size = Vector3.new(size * 0.8, size * 0.8, 0.2)
		sun.CFrame = CFrame.lookAt(camPos + sunDir * orbit, camPos)
		moon.CFrame = CFrame.lookAt(camPos - sunDir * orbit, camPos)
		occAcc += dt
		if occAcc > 0.15 then
			occAcc = 0
			local reach = (Config.RENDER_DISTANCE_MAX * Config.CHUNK_SIZE) * BS
			sunHidden = sunDir.Y < -0.1 or occluded(camPos, sunDir, reach)
			moonHidden = sunDir.Y > 0.1 or occluded(camPos, -sunDir, reach)
		end
		sun.Transparency = if sunHidden then 1 else 0
		moon.Transparency = if moonHidden then 1 else 0.05

		local starAlpha = math.clamp(1 - d * 1.4, 0, 1)
		for _, st in stars do
			st.part.Transparency = 1 - starAlpha * 0.85
			st.part.CFrame = CFrame.new(camPos + Vector3.new(st.offset.X * zH * 1.6, zH - 1, st.offset.Z * zH * 1.6))
		end
	end)
end

-- "06:30" style clock for the overlay.
function DayNightClient.clockText(): string
	local h = (6 + DayNightClient.timeOfDay / 1000) % 24
	return string.format("%02d:%02d", math.floor(h), math.floor((h % 1) * 60))
end

return DayNightClient
