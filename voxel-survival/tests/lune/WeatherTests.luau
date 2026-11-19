--!nocheck
-- Phase 9d: weather (World/Weather, World/SkyLight) and the REAL WeatherService in a fake Roblox.
-- Expected values follow the Minecraft Wiki ("Weather", "Rain", "Thunderstorm") and Java's
-- ServerLevel.advanceWeatherCycle / Level.updateSkyBrightness.
--
-- Usage (from run.luau):  require("./WeatherTests")(test, eq)

local Loader = require("./Loader")
local Fake = require("./FakeRoblox")

return function(test: (string, () -> ()) -> (), eq: (any, any, string?) -> ())
	print("Weather (Phase 9d)")
	local Weather = Loader.require("src/shared/World/Weather")
	local SkyLight = Loader.require("src/shared/World/SkyLight")

	local function near(a: number, b: number, eps: number, what: string?)
		assert(math.abs(a - b) <= eps, `{what or "value"}: expected {b}, got {a}`)
	end

	test("weather cycle: Java timers, flags flip at 0, levels fade 0.01 a tick, clear timer", function()
		local s = Weather.new()
		local draws = {}
		local function rand(lo, hi)
			table.insert(draws, { lo, hi })
			return lo
		end
		Weather.tick(s, rand)
		-- a new world: both timers drawn from the "off" ranges
		eq(draws[1][1], 12000); eq(draws[1][2], 180000) -- thunder delay
		eq(draws[2][1], 12000); eq(draws[2][2], 180000) -- rain delay
		eq(s.rainTime, 12000)
		for _ = 1, 11999 do
			Weather.tick(s, rand)
		end
		eq(s.raining, false)
		Weather.tick(s, rand)
		eq(s.raining, true, "the rain flag flips when its timer reaches 0")
		-- the next tick draws the rain duration 12000..24000
		table.clear(draws)
		Weather.tick(s, rand)
		local sawDuration = false
		for _, d in draws do
			if d[1] == 12000 and d[2] == 24000 then
				sawDuration = true
			end
		end
		assert(sawDuration, "rain duration drawn")
		-- levels: 100 ticks from 0 to 1
		local r = Weather.new()
		r.raining = true
		r.rainTime = 50000
		r.thunderTime = 50000
		for i = 1, 100 do
			Weather.tick(r, rand)
			if i == 19 then
				eq(Weather.isRaining(r), false, "below 0.2 isn't raining yet") -- (0.2 itself: float rounding)
			end
			if i == 21 then
				eq(Weather.isRaining(r), true)
			end
		end
		near(r.rainLevel, 1, 1e-9, "full rain after 5 s")
		-- thunder needs rain
		local t = Weather.new()
		t.thundering, t.thunderLevel, t.rainLevel = true, 1, 0
		eq(Weather.isThundering(t), false)
		t.rainLevel = 1
		eq(Weather.isThundering(t), true)
		-- /weather clear: both flags held off; timers locked at 1
		Weather.set(t, "clear", 100)
		Weather.tick(t, rand)
		eq(t.raining, false); eq(t.thundering, false); eq(t.rainTime, 1); eq(t.thunderTime, 1); eq(t.clearTime, 99)
		-- sleeping: flags off, timers 0
		Weather.set(t, "thunder", 5000)
		Weather.resetCycle(t)
		eq(t.raining, false); eq(t.rainTime, 0); eq(t.thunderTime, 0)
	end)

	test("over a long time it rains about 16 % of the time (Java ranges: on 18000, off 96000 on average)", function()
		local s = Weather.new()
		local seed = 42
		local function rand(lo, hi) -- a small LCG (deterministic)
			seed = (seed * 1103515245 + 12345) % 2147483648
			return lo + seed % (hi - lo + 1)
		end
		local rainy, n = 0, 4000000
		for _ = 1, n do
			Weather.tick(s, rand)
			if s.raining then
				rainy += 1
			end
		end
		local share = rainy / n
		-- expected 18000 / (18000 + 96000) = 0.158 (a long sample still varies a few percent)
		assert(share > 0.09 and share < 0.24, `share of rainy ticks {share}`)
	end)

	test("rain, snow or nothing by biome and height (temperature below 0.15 snows)", function()
		eq(Weather.precipitation("plains", 140), "rain")
		eq(Weather.precipitation("desert", 140), "none")
		eq(Weather.precipitation("snowy_tundra", 140), "snow")
		eq(Weather.precipitation("frozen_ocean", 126), "snow")
		eq(Weather.precipitation("taiga", 140), "rain")
		-- mountains (0.2): Java y 120 still rains, above it snows
		eq(Weather.precipitation("mountains", 64 + 120), "rain")
		eq(Weather.precipitation("mountains", 64 + 121), "snow")
		near(Weather.temperature("plains", 64 + 120), 0.8 - 40 * 0.05 / 40, 1e-9)
	end)

	test("sky light at noon: clear 15, rain 12, thunderstorm 10 (wiki); monsters spawn in daylight storms", function()
		local noon = 6000
		SkyLight.rainLevel, SkyLight.thunderLevel = 0, 0
		eq(SkyLight.rawBrightness(true, noon), 15)
		SkyLight.rainLevel = 1
		eq(SkyLight.rawBrightness(true, noon), 12)
		eq(SkyLight.isDay(noon), true, "rain: still day")
		SkyLight.thunderLevel = 1
		eq(SkyLight.rawBrightness(true, noon), 10)
		eq(SkyLight.isDay(noon), false, "thunderstorm: dark enough to sleep, undead don't burn")
		-- spawning in a thunderstorm counts the sky as 10 darker (raw 5): passes with r8 >= 5
		eq(SkyLight.monsterCanSpawn(true, noon, 31, 5), true)
		SkyLight.rainLevel, SkyLight.thunderLevel = 0, 0
		eq(SkyLight.monsterCanSpawn(true, noon, 31, 7), false, "clear noon: never")
		eq(SkyLight.isDay(noon), true)
		-- the same numbers from the pure formula
		eq(Weather.skyDarken(1, 0, 0), 0)
		eq(Weather.skyDarken(1, 1, 0), 3)
		eq(Weather.skyDarken(1, 1, 1), 5)
	end)

	test("sky, fog and clouds turn grey with rain and dark with thunder (Java colour formulas)", function()
		local r, g, b = Weather.skyColor(0.5, 0.7, 1, 0, 0)
		eq(r, 0.5); eq(b, 1)
		r, g, b = Weather.skyColor(0.5, 0.7, 1, 1, 0)
		local grey = (0.5 * 0.3 + 0.7 * 0.59 + 1 * 0.11) * 0.6
		near(r, 0.5 * 0.25 + grey * 0.75, 1e-9)
		near(b, 1 * 0.25 + grey * 0.75, 1e-9)
		local r2 = Weather.skyColor(0.5, 0.7, 1, 1, 1)
		assert(r2 < r, "thunder darker than rain")
		local fr, fg, fb = Weather.fogColor(1, 1, 1, 1, 0)
		eq(fr, 0.5); eq(fb, 0.6)
		local cr = Weather.cloudColor(1, 1, 1, 1, 1)
		assert(cr < 0.5, "storm clouds dark")
		-- save round trip
		local s = Weather.new()
		Weather.set(s, "thunder", 777)
		local back = Weather.decode(Weather.encode(s))
		eq(back.raining, true); eq(back.thundering, true); eq(back.rainTime, 777)
		eq(back.rainLevel, 1, "loaded mid-storm: no fade-in")
		eq(Weather.decode(nil).raining, false)
	end)

	test("server: rain falls only under the open sky where the biome rains; lightning hurts and lights fires", function()
		local G = Fake.newGame()
		for k, v in G.env do
			Loader.globals[k] = v
		end
		Loader.forget("src/server/")
		local BlockRegistry = Loader.require("src/shared/Blocks/BlockRegistry")
		local Biomes = Loader.require("src/shared/World/Biomes")
		local STONE = BlockRegistry.id("stone")
		local FLOOR = 140
		local cells = {}
		local function getb(x, y, z)
			return cells[`{x},{y},{z}`] or (if y < FLOOR then STONE else 0)
		end
		local biome = {}
		local remotes = {}
		Loader.stubs["src/shared/Net/Remotes.luau"] = {
			get = function(name)
				local r = remotes[name]
				if not r then
					r = Fake.Instance.new("RemoteEvent")
					remotes[name] = r
				end
				return r
			end,
		}
		Loader.stubs["src/server/World/WorldService.luau"] = {
			getBlock = getb, getBlockIfLoaded = getb,
			biomeAt = function(x, _z)
				return biome[x] or Biomes.id("plains")
			end,
			onBlockChanged = function() end, onChunkUnloaded = function() end,
		}
		Fake.mount(G.game:GetService("ReplicatedStorage"), "Shared", Loader.node("src/shared"))
		local WS = Loader.require("src/server/World/WeatherService")
		local hits = { players = 0, mobs = 0, fires = 0 }
		local diff = "normal"
		WS.init({
			nearChunks = function() return {} end,
			ignite = function() hits.fires += 1; return true end,
			difficulty = function() return diff end,
			hurtPlayers = function() hits.players += 1 end,
			hurtMobs = function() hits.mobs += 1 end,
			targets = function() return {} end,
		})
		eq(WS.rainingAt(0, FLOOR, 0), false, "clear weather")
		WS.set("rain", 10000)
		for _ = 1, 30 do
			WS.tick()
		end
		eq(G.game:GetService("ReplicatedStorage"):GetAttribute("WeatherRain"), true)
		eq(WS.rainingAt(0, FLOOR, 0), true, "on open ground")
		cells["1,150,0"] = STONE -- a roof over column 1
		eq(WS.rainingAt(1, FLOOR, 0), false, "under a roof")
		biome[5] = Biomes.id("desert")
		eq(WS.rainingAt(5, FLOOR, 0), false, "deserts stay dry")
		biome[6] = Biomes.id("snowy_tundra")
		eq(WS.rainingAt(6, FLOOR, 0), false, "it snows there")
		eq(WS.precipitationAt(6, FLOOR, 0), "snow")
		-- a strike: fire at the spot + 4 tries (Normal), everything in the box is hit
		WS.strike(2, FLOOR, 2)
		eq(hits.fires, 5); eq(hits.players, 1); eq(hits.mobs, 1)
		diff = "easy"
		WS.strike(2, FLOOR, 2)
		eq(hits.fires, 5, "no lightning fires on Easy")
		-- sleeping ends the rain
		WS.onSlept()
		eq(WS.state().raining, false)

		-- the Studio keys and "/weather" (through the real remotes), each with a reply
		local player = G.player
		local rs = G.game:GetService("ReplicatedStorage")
		local replies = setmetatable({}, {
			-- the "message" answers the server sent to clients so far (the fake remote logs them)
			__index = function(_, k)
				local out = {}
				for _, e in rawget(remotes.Weather, "__toClient") or {} do
					if typeof(e[2]) == "table" and e[2].type == "message" then
						table.insert(out, e[2].text)
					end
				end
				if k == "list" then
					return out
				end
				return out[k]
			end,
			__len = function(t)
				return #t.list
			end,
		})
		WS.set("clear", 100)
		WS.tick()
		remotes.DebugAction.OnServerEvent:Fire(player, { type = "weather" }) -- key Y
		eq(WS.current(), "rain", "Y: clear -> rain")
		eq(rs:GetAttribute("WeatherRain"), true)
		remotes.DebugAction.OnServerEvent:Fire(player, { type = "weather" })
		eq(WS.current(), "thunder", "Y: rain -> thunderstorm")
		remotes.DebugAction.OnServerEvent:Fire(player, { type = "weather" })
		eq(WS.current(), "clear", "Y: thunderstorm -> clear")
		assert(#replies.list == 3 and string.find(replies[1], "rain"), "each key press answers")
		remotes.WeatherCommand.OnServerEvent:Fire(player, { "thunder", "90" })
		eq(WS.current(), "thunder")
		eq(WS.state().rainTime, 1800, "/weather thunder 90 = 1800 ticks")
		eq(rs:GetAttribute("WeatherRainTime"), 1800, "timers for F3")
		remotes.WeatherCommand.OnServerEvent:Fire(player, { "clear", "60" })
		eq(WS.current(), "clear")
		eq(rs:GetAttribute("WeatherClearTime"), 1200)
		-- forced snow (key T / "/weather snow on"): it snows even in deserts
		remotes.DebugAction.OnServerEvent:Fire(player, { type = "weatherSnow" })
		eq(rs:GetAttribute("WeatherForceSnow"), true)
		eq(WS.precipitationAt(5, FLOOR, 0), "snow", "forced snow in the desert")
		remotes.WeatherCommand.OnServerEvent:Fire(player, { "snow", "off" })
		eq(WS.precipitationAt(5, FLOOR, 0), "none")
		eq(WS.precipitationAt(0, FLOOR, 0), "rain")
		-- old-chat fallback and bad input
		player.Chatted:Fire("/weather rain 30")
		eq(WS.current(), "rain")
		remotes.WeatherCommand.OnServerEvent:Fire(player, { "banana" })
		assert(string.find(replies[#replies.list], "Usage"), "unknown words get the usage line")
		remotes.WeatherCommand.OnServerEvent:Fire(player, "not a table")
		-- lightning near me (key B): no character here, so no ground to strike next to
		remotes.DebugAction.OnServerEvent:Fire(player, { type = "lightning" })
		local last = replies[#replies.list]
		assert(string.find(last, "No ground") or string.find(last, "Lightning"), "B answers")

		for _, path in { "src/shared/Net/Remotes.luau", "src/server/World/WorldService.luau" } do
			Loader.stubs[path] = nil
		end
		for _, k in { "game", "workspace", "Instance", "Enum", "CFrame", "Vector2", "Color3", "UDim2", "UDim", "task", "os", "time", "tick", "warn", "Random" } do
			Loader.globals[k] = nil
		end
		Loader.forget("src/server/")
		SkyLight.rainLevel, SkyLight.thunderLevel = 0, 0
	end)

	test("client (real WeatherClient): rain falls around you but not under a roof, fades in; lightning draws a bolt", function()
		local G = Fake.newGame()
		for k, v in G.env do
			Loader.globals[k] = v
		end
		Loader.forget("src/client/")
		local remotes = {}
		Loader.stubs["src/shared/Net/Remotes.luau"] = {
			get = function(name)
				local r = remotes[name]
				if not r then
					r = Fake.Instance.new("RemoteEvent")
					remotes[name] = r
				end
				return r
			end,
		}
		Loader.stubs["src/client/Audio/AudioClient.luau"] = { play = function() return false end }
		Fake.mount(G.game:GetService("ReplicatedStorage"), "Shared", Loader.node("src/shared"))
		local BlockRegistry = Loader.require("src/shared/Blocks/BlockRegistry")
		local Biomes = Loader.require("src/shared/World/Biomes")
		local Config = Loader.require("src/shared/Config")
		local BS = Config.BLOCK_SIZE
		local STONE = BlockRegistry.id("stone")
		local FLOOR = 140
		local roof = false
		local function getb(x, y, z)
			if roof and y == FLOOR + 6 and math.abs(x) <= 30 and math.abs(z) <= 30 then
				return STONE
			end
			return if y < FLOOR then STONE else 0
		end
		local W = Loader.require("src/client/World/WeatherClient")
		local cam = Fake.Instance.new("Camera")
		cam.CFrame = Fake.CFrame.new(0.5 * BS, (FLOOR + 1.6) * BS, 0.5 * BS)
		cam.Parent = G.workspace
		G.workspace.CurrentCamera = cam
		W.init(getb, function() return Biomes.id("plains") end)
		local rs = G.game:GetService("ReplicatedStorage")
		for _ = 1, 30 do
			G.frame(1 / 30)
		end
		eq(W.stats.drops, 0, "clear: no rain")
		rs:SetAttribute("WeatherRain", true)
		G.frame(1 / 30)
		assert(W.rain > 0 and W.rain < 0.05, "fades in")
		for _ = 1, 200 do
			G.frame(1 / 30)
		end
		near(W.rain, 1, 1e-9, "full rain after 5 s")
		assert(W.stats.drops > 100, `drops falling ({W.stats.drops})`)
		-- every drop is above the ground
		for _, p in G.workspace.Weather:GetChildren() do
			if p.Transparency < 1 then
				assert(p.CFrame.Position.Y / BS >= FLOOR - 0.5, "no rain below the ground")
			end
		end
		-- a roof over everything: drops stay above it
		roof = true
		for _ = 1, 90 do
			G.frame(1 / 30)
		end
		for _, p in G.workspace.Weather:GetChildren() do
			if p:IsA("BasePart") and p.Transparency < 1 then
				assert(p.CFrame.Position.Y / BS >= FLOOR + 6.5, "no rain under the roof")
			end
		end
		-- lightning
		local before = #G.workspace.Weather:GetChildren()
		remotes.Weather.OnClientEvent:Fire({ type = "lightning", x = 3, y = FLOOR, z = 3 })
		assert(#G.workspace.Weather:GetChildren() > before, "a bolt appears")
		eq(W.flash, 1)
		eq(W.stats.strikes, 1)

		for _, path in { "src/shared/Net/Remotes.luau", "src/client/Audio/AudioClient.luau" } do
			Loader.stubs[path] = nil
		end
		for _, k in { "game", "workspace", "Instance", "Enum", "CFrame", "Vector2", "Color3", "UDim2", "UDim", "task", "os", "time", "tick", "warn", "Random" } do
			Loader.globals[k] = nil
		end
		Loader.forget("src/client/")
		SkyLight.rainLevel, SkyLight.thunderLevel = 0, 0
	end)
end
