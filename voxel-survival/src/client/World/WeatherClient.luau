--!strict
-- Weather on the client (rules: World/Weather; the server decides, WeatherService):
--   * levels   rain / thunder levels follow the server's flags (attributes WeatherRain,
--              WeatherThunder) by 0.01 a tick like Java, and snap to the server's levels if
--              they drift apart; World/SkyLight, DayNightClient and Clouds read them
--   * rain and snow  falling streaks / flakes in the columns around the camera, only where the
--              biome rains or snows (none in deserts, snow in cold biomes and high up), and only
--              down to the first block that stops them, so it never rains under a roof. A fixed
--              pool of thin parts moved with one BulkMoveTo per frame.
--   * lightning  a jagged bolt from high in the sky down to the strike (our own look), a short
--              bright flash of the sky and light, thunder (SoundConfig "weather.thunder")
--   * sound    "weather.rain" while it rains near you (quieter under a roof)
-- Rain and thunder sounds are placeholders until licensed sounds are chosen (SOUNDS.md).

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Lighting = game:GetService("Lighting")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared.Config)
local Weather = require(Shared.World.Weather)
local SkyLight = require(Shared.World.SkyLight)
local Biomes = require(Shared.World.Biomes)
local BlockRegistry = require(Shared.Blocks.BlockRegistry)
local Remotes = require(Shared.Net.Remotes)

local BS = Config.BLOCK_SIZE

local WeatherClient = {}
WeatherClient.rain = 0 -- 0..1
WeatherClient.thunder = 0 -- 0..1 (raw; times rain for the visible thunder level)
WeatherClient.flash = 0 -- 0..1 lightning flash, fades fast
WeatherClient.stats = { drops = 0, strikes = 0 }

local RADIUS = 12 -- blocks around the camera that get rain
local BAND = 16 -- blocks above / below the camera that drops fall through
local MAX_DROPS = 420
local RAIN_SPEED = 30 * BS -- studs a second (fast streaks)
local SNOW_SPEED = 3 * BS

type Drop = { part: BasePart, x: number, y: number, z: number, floor: number, snow: boolean, sway: number }

local getBlock: ((number, number, number) -> number?)? = nil
local biomeAt: ((number, number) -> number?)? = nil
local isSolid = BlockRegistry.isSolid
local isLiquid = BlockRegistry.isLiquid

-- Where rain stops in a column: the first block that blocks motion, scanning down from above
-- the camera. Cached briefly.
local floorCache: { [number]: { y: number, t: number } } = {}
local function floorAt(x: number, z: number, fromY: number, now: number): number
	local k = (x + 1048576) * 2097152 + (z + 1048576)
	local c = floorCache[k]
	if c and now - c.t < 1 then
		return c.y
	end
	local gb = getBlock
	local y = fromY
	local stop = fromY - BAND * 2
	local found = stop
	if gb then
		while y > stop do
			local id = gb(x, y, z)
			if id and id ~= 0 and (isSolid[id + 1] or isLiquid[id + 1]) then
				found = y + 1
				break
			end
			y -= 1
		end
	end
	floorCache[k] = { y = found, t = now }
	return found
end

local function precipitationAt(x: number, y: number, z: number): string
	local ba = biomeAt
	local b = ba and ba(x, z)
	local biome = b and Biomes.byId[b]
	return Weather.precipitation(if biome then biome.key else "plains", y)
end

-- Lightning: a bolt of a few jagged segments (neon parts), visible for a moment.
local function bolt(x: number, y: number, z: number, folder: Instance)
	WeatherClient.stats.strikes += 1
	WeatherClient.flash = 1
	local base = Vector3.new(x + 0.5, y, z + 0.5) * BS
	local top = base + Vector3.new(0, 128 * BS, 0)
	local parts: { BasePart } = {}
	local rng = Random.new()
	local pos = top
	local steps = 10
	for i = 1, steps do
		local nextPos = if i == steps then base
			else top:Lerp(base, i / steps) + Vector3.new(rng:NextNumber(-1, 1), 0, rng:NextNumber(-1, 1)) * 3 * BS
		local len = (nextPos - pos).Magnitude
		local p = Instance.new("Part")
		p.Anchored = true
		p.CanCollide = false
		p.CanQuery = false
		p.CanTouch = false
		p.CastShadow = false
		p.Material = Enum.Material.Neon
		p.Color = Color3.fromRGB(214, 226, 255)
		p.Size = Vector3.new(0.35 * BS, 0.35 * BS, len)
		p.CFrame = CFrame.lookAt((pos + nextPos) / 2, nextPos)
		p.Parent = folder
		table.insert(parts, p)
		pos = nextPos
	end
	local light = Instance.new("PointLight")
	light.Range = 60
	light.Brightness = 6
	light.Color = Color3.fromRGB(214, 226, 255)
	light.Parent = parts[#parts]
	-- Java: the bolt flickers for a few ticks, then disappears
	task.spawn(function()
		for i = 1, 4 do
			for _, p in parts do
				p.Transparency = if i % 2 == 0 then 0.6 else 0
			end
			task.wait(0.05)
		end
		task.wait(0.1)
		for _, p in parts do
			p:Destroy()
		end
	end)
	local audio = require(script.Parent.Parent.Audio.AudioClient) :: any
	audio.play("weather.thunder", nil)
end

function WeatherClient.init(blockSource: (number, number, number) -> number?, biomeSource: (number, number) -> number?)
	getBlock = blockSource
	biomeAt = biomeSource
	local folder = Instance.new("Folder")
	folder.Name = "Weather"
	folder.Parent = workspace

	-- the drop pool
	local drops: { Drop } = {}
	for _ = 1, MAX_DROPS do
		local p = Instance.new("Part")
		p.Anchored = true
		p.CanCollide = false
		p.CanQuery = false
		p.CanTouch = false
		p.CastShadow = false
		p.Material = Enum.Material.SmoothPlastic
		p.Transparency = 1
		p.Size = Vector3.new(0.04 * BS, 0.7 * BS, 0.04 * BS)
		p.Parent = folder
		table.insert(drops, { part = p, x = 0, y = -1e6, z = 0, floor = 0, snow = false, sway = 0 })
	end

	local function attr(name: string): any
		return ReplicatedStorage:GetAttribute(name)
	end
	-- start where the server is
	WeatherClient.rain = (attr("WeatherRainLevel") :: number?) or 0
	WeatherClient.thunder = (attr("WeatherThunderLevel") :: number?) or 0
	local function snap()
		local r, t = attr("WeatherRainLevel"), attr("WeatherThunderLevel")
		if typeof(r) == "number" and math.abs(r - WeatherClient.rain) > 0.05 then
			WeatherClient.rain = r
		end
		if typeof(t) == "number" and math.abs(t - WeatherClient.thunder) > 0.05 then
			WeatherClient.thunder = t
		end
	end
	ReplicatedStorage:GetAttributeChangedSignal("WeatherRainLevel"):Connect(snap)
	ReplicatedStorage:GetAttributeChangedSignal("WeatherThunderLevel"):Connect(snap)

	Remotes.get("Weather").OnClientEvent:Connect(function(e: any)
		if typeof(e) == "table" and e.type == "lightning" and typeof(e.x) == "number" and typeof(e.y) == "number"
			and typeof(e.z) == "number"
		then
			bolt(e.x, e.y, e.z, folder)
		end
	end)

	local rng = Random.new()
	local moveParts: { BasePart } = {}
	local moveCFrames: { CFrame } = {}
	local rainSoundAcc = 0
	local baseBrightness = Lighting.ExposureCompensation
	RunService.RenderStepped:Connect(function(dt)
		-- levels follow the flags by 0.01 a tick (Java)
		local step = Weather.LEVEL_STEP * dt * 20
		local rainOn, thunderOn = attr("WeatherRain") == true, attr("WeatherThunder") == true
		WeatherClient.rain = math.clamp(WeatherClient.rain + (if rainOn then step else -step), 0, 1)
		WeatherClient.thunder = math.clamp(WeatherClient.thunder + (if thunderOn then step else -step), 0, 1)
		SkyLight.rainLevel, SkyLight.thunderLevel = WeatherClient.rain, WeatherClient.thunder
		WeatherClient.flash = math.max(0, WeatherClient.flash - dt * 6)
		Lighting.ExposureCompensation = baseBrightness + WeatherClient.flash * 1.2

		local cam = workspace.CurrentCamera
		if not cam then
			return
		end
		local now = os.clock()
		local camPos = cam.CFrame.Position
		local cx, cy, cz = camPos.X / BS, camPos.Y / BS, camPos.Z / BS
		local rain = WeatherClient.rain
		-- how many drops are in use (more as the rain gets heavier)
		local active = math.floor(MAX_DROPS * math.clamp((rain - 0.2) / 0.8, 0, 1) + 0.5)
		table.clear(moveParts)
		table.clear(moveCFrames)
		local shown = 0
		local sheltered = true
		for i, d in drops do
			if i > active then
				if d.part.Transparency < 1 then
					d.part.Transparency = 1
				end
				continue
			end
			local speed = if d.snow then SNOW_SPEED else RAIN_SPEED
			d.y -= speed * dt / BS
			local far = math.abs(d.x - cx) > RADIUS + 2 or math.abs(d.z - cz) > RADIUS + 2
			if d.y < d.floor or d.y < cy - BAND or far then
				-- respawn in a random column around the camera, above its floor
				local x = math.floor(cx + rng:NextNumber(-RADIUS, RADIUS))
				local z = math.floor(cz + rng:NextNumber(-RADIUS, RADIUS))
				local fy = floorAt(x, z, math.floor(cy + BAND), now)
				local kind = precipitationAt(x, math.max(fy, math.floor(cy)), z)
				local topY = cy + BAND
				if kind == "none" or fy >= topY then
					d.y = -1e6
					d.part.Transparency = 1
					continue
				end
				d.x = x + rng:NextNumber(0.1, 0.9)
				d.z = z + rng:NextNumber(0.1, 0.9)
				d.floor = fy
				d.y = rng:NextNumber(math.max(fy, cy - BAND), topY)
				d.snow = kind == "snow"
				d.sway = rng:NextNumber(0, 6.28)
				if d.snow then
					d.part.Size = Vector3.new(0.12 * BS, 0.12 * BS, 0.12 * BS)
					d.part.Color = Color3.fromRGB(250, 252, 255)
					d.part.Transparency = 0.1
				else
					d.part.Size = Vector3.new(0.035 * BS, 0.75 * BS, 0.035 * BS)
					d.part.Color = Color3.fromRGB(150, 176, 230)
					d.part.Transparency = 0.45
				end
			end
			if d.y > -1e5 then
				shown += 1
				local sx = d.x
				local sz = d.z
				if d.snow then
					sx += math.sin(now * 1.3 + d.sway) * 0.3
					sz += math.cos(now * 1.1 + d.sway) * 0.3
				end
				table.insert(moveParts, d.part)
				table.insert(moveCFrames, CFrame.new(sx * BS, d.y * BS, sz * BS))
				if not d.snow and math.abs(d.x - cx) < 3 and math.abs(d.z - cz) < 3 and d.floor <= cy then
					sheltered = false
				end
			end
		end
		if #moveParts > 0 then
			workspace:BulkMoveTo(moveParts, moveCFrames, Enum.BulkMoveMode.FireCFrameChanged)
		end
		WeatherClient.stats.drops = shown
		-- rain sound now and then near the ground (quieter under a roof); placeholder until a
		-- licensed sound is chosen
		if rain > 0.2 and shown > 0 then
			rainSoundAcc += dt
			if rainSoundAcc > 1.5 then
				rainSoundAcc = 0
				local audio = require(script.Parent.Parent.Audio.AudioClient) :: any
				audio.play("weather.rain", nil, (if sheltered then 0.4 else 1) * rain)
			end
		end
	end)
end

return WeatherClient
