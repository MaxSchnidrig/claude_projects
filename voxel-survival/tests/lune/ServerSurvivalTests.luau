--!nocheck
-- Runs the REAL server/Survival/SurvivalService and World/WorldSettingsService in a fake Roblox:
-- difficulty damage scaling, Peaceful healing and food, Hardcore death -> spectator.
--
-- Usage (from run.luau):  require("./ServerSurvivalTests")(test, eq)

local Loader = require("./Loader")
local Fake = require("./FakeRoblox")

local CFrame = Fake.CFrame

return function(test: (string, () -> ()) -> (), eq: (any, any, string?) -> ())
	print("Server survival (real SurvivalService + WorldSettingsService in a fake Roblox)")

	local STUBS = {
		"src/shared/Net/Remotes.luau", "src/server/World/WorldService.luau", "src/server/Player/InventoryService.luau",
		"src/server/Player/SpawnService.luau", "src/server/Interaction/BlockActionService.luau",
		"src/server/Survival/DayNightService.luau", "src/server/Player/BedService.luau",
	}

	test("server: difficulty scales mob damage, Peaceful heals and feeds, Hardcore death makes a spectator", function()
		local G = Fake.newGame()
		for k, v in G.env do
			Loader.globals[k] = v
		end
		Loader.forget("src/server/")
		local BlockRegistry = Loader.require("src/shared/Blocks/BlockRegistry")
		local STONE = BlockRegistry.id("stone")
		local FLOOR = 64
		local remotes = {}
		Loader.stubs["src/shared/Net/Remotes.luau"] = {
			get = function(name: string)
				local r = remotes[name]
				if not r then
					r = Fake.Instance.new("RemoteEvent")
					r.Name = name
					remotes[name] = r
				end
				return r
			end,
		}
		Loader.stubs["src/server/World/WorldService.luau"] = {
			getBlock = function(_x, y, _z)
				return if y < FLOOR then STONE else 0
			end,
		}
		local dropped = 0
		Loader.stubs["src/server/Player/InventoryService.luau"] = {
			armor = function() return {} end,
			dropAll = function()
				dropped += 1
			end,
			add = function()
				return 0
			end,
		}
		local player = G.player
		local function newCharacter()
			local c = Fake.newCharacter("Tester", CFrame.new(1.5 * 3, FLOOR * 3 + 3, 1.5 * 3))
			-- the player's client holds its body on the ground (the server has no terrain to stand on)
			c.HumanoidRootPart.Anchored = true
			c.Parent = G.workspace
			player.Character = c
			player.CharacterAdded:Fire(c)
			return c
		end
		local respawns = 0
		Loader.stubs["src/server/Player/SpawnService.luau"] = {
			respawn = function()
				respawns += 1
				newCharacter()
			end,
		}
		Loader.stubs["src/server/Interaction/BlockActionService.luau"] = { onBlockBroken = function() end }
		Loader.stubs["src/server/Survival/DayNightService.luau"] = { addTicks = function() end }
		Loader.stubs["src/server/Player/BedService.luau"] = { onHurt = function() end }
		Fake.mount(G.game:GetService("ReplicatedStorage"), "Shared", Loader.node("src/shared"))

		local WorldSettings = Loader.require("src/server/World/WorldSettingsService")
		local Survival = Loader.require("src/server/Survival/SurvivalService")
		WorldSettings.load({ difficulty = "easy" }, player.UserId)
		WorldSettings.init()
		Survival.init()
		local c = newCharacter()
		local h = c.Humanoid
		G.frame(0.1)
		eq(h.Health, 20)
		local rs = G.game:GetService("ReplicatedStorage")
		eq(rs:GetAttribute("Difficulty"), "easy")

		-- a zombie's 3: Easy 2.5, Normal 3, Hard 4.5, Peaceful nothing; a fall is the same everywhere
		local function hit(amount: number, scales: boolean): number
			G.frame(1) -- past the 0.5 s hurt cooldown
			local before = h.Health
			Survival.damage(player, amount, "test", nil, { scales = scales })
			return before - h.Health
		end
		eq(hit(3, true), 2.5)
		WorldSettings.setDifficulty("normal")
		eq(hit(3, true), 3)
		WorldSettings.setDifficulty("hard")
		eq(hit(3, true), 4.5)
		WorldSettings.setDifficulty("peaceful")
		eq(hit(3, true), 0)
		eq(hit(3, false), 3) -- falls, lava...: not scaled
		-- Peaceful: +1 health a second, +1 food every half second
		h.Health = 5
		for _ = 1, 40 do
			G.frame(0.1)
		end
		assert(h.Health >= 8 and h.Health <= 10, `healed on Peaceful ({h.Health})`)
		-- the owner (or Studio) changes the difficulty over the remote; the bad value is ignored
		remotes.WorldSettings.OnServerEvent:Fire(player, { type = "difficulty", value = "nightmare" })
		eq(WorldSettings.difficulty(), "peaceful")
		remotes.WorldSettings.OnServerEvent:Fire(player, { type = "difficulty", value = "hard" })
		eq(WorldSettings.difficulty(), "hard")
		eq(rs:GetAttribute("Difficulty"), "hard")
		remotes.WorldSettings.OnServerEvent:Fire(player, { type = "friends", on = false })
		eq(rs:GetAttribute("FriendsCanJoin"), false)

		-- Hardcore: always Hard, can't be changed; dying makes you a spectator for good
		WorldSettings.load({ hardcore = true, difficulty = "easy" }, player.UserId)
		eq(WorldSettings.difficulty(), "hard")
		eq(WorldSettings.setDifficulty("easy"), false)
		eq(WorldSettings.difficulty(), "hard")
		G.frame(1)
		Survival.damage(player, 1000, "fell out of the world", true)
		eq(h.Health, 0)
		eq(dropped, 1, "items dropped on death")
		eq(Survival.isSpectator(player), true)
		remotes.SurvivalAction.OnServerEvent:Fire(player, { type = "respawn" })
		eq(respawns, 1)
		eq(player:GetAttribute("Spectator"), true)
		local c2 = player.Character
		assert(c2 ~= c, "a new body")
		eq(c2.Head.Transparency, 1, "others can't see a spectator")
		G.frame(1)
		local before = c2.Humanoid.Health
		eq(Survival.damage(player, 5, "zombie", nil, { scales = true }), 0)
		eq(c2.Humanoid.Health, before, "spectators take no damage")

		for _, path in STUBS do
			Loader.stubs[path] = nil
		end
	end)

	for _, k in { "game", "workspace", "Instance", "Enum", "CFrame", "Vector2", "Color3", "UDim2", "UDim", "task", "os", "time", "tick", "warn", "Random" } do
		Loader.globals[k] = nil
	end
	Loader.forget("src/server/")
end
