--!nocheck
-- Phase 9c: status effects (Gameplay/Effects) and the REAL SurvivalService using them: eating
-- golden apples / spider eyes / milk, poison, regeneration, absorption, resistance, fire resistance.
--
-- Usage (from run.luau):  require("./EffectsTests")(test, eq)

local Loader = require("./Loader")
local Fake = require("./FakeRoblox")

local CFrame = Fake.CFrame

return function(test: (string, () -> ()) -> (), eq: (any, any, string?) -> ())
	print("Status effects and foods (Phase 9c)")
	local Effects = Loader.require("src/shared/Gameplay/Effects")

	test("effects: Java tick intervals, poison never kills, adding rules, hidden effects, save round trip", function()
		-- intervals: poison I every 25 ticks, II every 12; regeneration II every 25
		local function count(id: string, amp: number, ticks: number): (number, number)
			local list = {}
			Effects.add(list, id, amp, ticks)
			local hp, hurts, heals = 10, 0, 0
			for _ = 1, ticks + 5 do
				Effects.tick(list, {
					health = function() return hp end,
					maxHealth = function() return 100 end,
					hurt = function(n) hurts += 1; hp -= n end,
					heal = function(n) heals += 1; hp += n end,
					exhaust = function() end,
					absorption = function() return 0 end,
				})
			end
			eq(list[id], nil, `{id} ran out`)
			return hurts, heals
		end
		eq((count("poison", 0, 100)), 4, "spider eye: 5 s of poison = 4 hits")
		eq((count("poison", 1, 100)), 8)
		local _, heals = count("regeneration", 1, 100)
		eq(heals, 4, "golden apple regeneration II: 4 health")
		local _, heals2 = count("regeneration", 1, 400)
		eq(heals2, 16, "enchanted: 16 health")
		-- poison stops at 1 health
		local list = {}
		Effects.add(list, "poison", 3, 600)
		local hp = 3
		for _ = 1, 600 do
			Effects.tick(list, {
				health = function() return hp end, maxHealth = function() return 20 end,
				hurt = function(n) hp -= n end, heal = function() end, exhaust = function() end,
				absorption = function() return 0 end,
			})
		end
		eq(hp, 1, "poison can't kill")
		-- hunger: 0.005 exhaustion per tick per level (30 s of Hunger I = 3.0)
		list = {}
		Effects.add(list, "hunger", 0, 600)
		local ex = 0
		for _ = 1, 600 do
			Effects.tick(list, {
				health = function() return 20 end, maxHealth = function() return 20 end, hurt = function() end,
				heal = function() end, exhaust = function(n) ex += n end, absorption = function() return 0 end,
			})
		end
		assert(math.abs(ex - 3) < 1e-6, `hunger exhaustion {ex}`)

		-- adding: same level only extends; higher replaces, the longer lower one waits underneath
		list = {}
		Effects.add(list, "regeneration", 0, 400)
		eq(Effects.add(list, "regeneration", 0, 100), false, "shorter same level: no change")
		eq(list.regeneration.ticks, 400)
		eq(Effects.add(list, "regeneration", 1, 100), true, "a higher level replaces")
		eq(list.regeneration.amp, 1)
		eq(list.regeneration.hidden.amp, 0, "the old one waits underneath")
		local function plain(n)
			for _ = 1, n do
				Effects.tick(list, {
					health = function() return 20 end, maxHealth = function() return 20 end, hurt = function() end,
					heal = function() end, exhaust = function() end, absorption = function() return 0 end,
				})
			end
		end
		plain(100)
		eq(list.regeneration.amp, 0, "level I comes back")
		eq(list.regeneration.ticks, 300, "and it kept running underneath")
		-- absorption ends early when its hearts are gone
		list = {}
		Effects.add(list, "absorption", 0, 2400)
		Effects.tick(list, {
			health = function() return 20 end, maxHealth = function() return 20 end, hurt = function() end,
			heal = function() end, exhaust = function() end, absorption = function() return 0 end,
		})
		eq(list.absorption, nil)
		-- resistance: 20 % per level; absorption max 4 per level
		list = {}
		Effects.add(list, "resistance", 0, 100)
		eq(Effects.resist(list, 10), 8)
		Effects.add(list, "absorption", 3, 100)
		eq(Effects.absorptionMax(list), 16)
		eq(Effects.label("absorption", 3), "Absorption IV")
		eq(Effects.timeText(2400), "2:00")
		-- save round trip (with a hidden level), junk ignored
		Effects.add(list, "absorption", 0, 2400)
		local back = Effects.decode(Effects.encode(list))
		eq(back.absorption.amp, 3)
		eq(back.absorption.hidden.amp, 0)
		eq(back.resistance.ticks, 100)
		eq(next(Effects.decode({ flying = { 1, 100 }, poison = "x" })), nil)
	end)

	test("server: golden apple (full bar), spider eye poison, milk clears, absorption, resistance, fire resistance", function()
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
		local slots = {}
		Loader.stubs["src/server/Player/InventoryService.luau"] = {
			armor = function() return {} end,
			dropAll = function() end,
			add = function() return 0 end,
			selectedSlot = function() return 1 end,
			getSlot = function(_p, i) return slots[i] end,
			setSlot = function(_p, i, s) slots[i] = s end,
		}
		local player = G.player
		Loader.stubs["src/server/Player/SpawnService.luau"] = { respawn = function() end }
		Loader.stubs["src/server/Interaction/BlockActionService.luau"] = { onBlockBroken = function() end }
		Loader.stubs["src/server/Survival/DayNightService.luau"] = { addTicks = function() end }
		Loader.stubs["src/server/Player/BedService.luau"] = { onHurt = function() end }
		Fake.mount(G.game:GetService("ReplicatedStorage"), "Shared", Loader.node("src/shared"))

		local WorldSettings = Loader.require("src/server/World/WorldSettingsService")
		local Survival = Loader.require("src/server/Survival/SurvivalService")
		WorldSettings.load({ difficulty = "normal" }, player.UserId)
		WorldSettings.init()
		Survival.init()
		local c = Fake.newCharacter("Tester", CFrame.new(1.5 * 3, FLOOR * 3 + 3, 1.5 * 3))
		c.HumanoidRootPart.Anchored = true
		c.Parent = G.workspace
		player.Character = c
		player.CharacterAdded:Fire(c)
		local h = c.Humanoid
		G.frame(0.1)
		local function eat(item: string)
			slots[1] = { item = item, count = 1 }
			remotes.SurvivalAction.OnServerEvent:Fire(player, { type = "eatStart" })
			G.frame(1.7)
			remotes.SurvivalAction.OnServerEvent:Fire(player, { type = "eatFinish" })
		end

		-- full hunger: bread can't be eaten, a golden apple can
		eat("bread")
		eq(slots[1].item, "bread", "not hungry: bread stays")
		eat("golden_apple")
		eq(slots[1], nil, "golden apple eaten with a full bar")
		local fx = Survival.effects(player)
		eq(fx.regeneration.amp, 1)
		eq(fx.absorption.amp, 0)
		-- absorption takes the damage first
		G.frame(1)
		Survival.damage(player, 3, "test")
		eq(h.Health, 20, "4 gold health took the hit")
		G.frame(1)
		Survival.damage(player, 3, "test")
		eq(h.Health, 18, "1 left in absorption, 2 through")
		G.frame(0.2)
		eq(fx.absorption, nil, "absorption ended with its hearts")

		-- milk clears everything and leaves the bucket
		eat("milk_bucket")
		eq(slots[1].item, "bucket")
		eq(next(Survival.effects(player)), nil, "milk cleared the effects")

		-- spider eye: poisoned, health drops but poison never kills
		h.Health = 3
		for _ = 1, 400 do -- hungry enough that nothing heals (one point used per tick, like Java)
			if Survival.snapshot(player).food <= 14 then
				break
			end
			Survival.addExhaustion(player, 4.1)
			G.frame(0.05)
		end
		eat("spider_eye")
		fx = Survival.effects(player)
		eq(fx.poison.amp, 0)
		for _ = 1, 60 do
			G.frame(0.1)
		end
		-- Java: poison only hits above 1 health, so it stops at 1 or just below (1.6 -> 0.6)
		assert(h.Health > 0 and h.Health <= 1, `poison stopped above 0 ({h.Health})`)
		assert(h.Health < 3, `poison hurt ({h.Health})`)

		-- enchanted golden apple: resistance and fire resistance
		h.Health = 20
		eat("enchanted_golden_apple")
		fx = Survival.effects(player)
		eq(fx.resistance.amp, 0)
		eq(fx.fire_resistance.amp, 0)
		eq(fx.absorption.amp, 3)
		G.frame(1)
		eq((Survival.damage(player, 5, "lava", nil, { fire = true })), 0, "fire resistance")
		G.frame(1)
		Survival.damage(player, 20, "hit") -- resistance: 16, all into the 16 gold health
		eq(h.Health, 20)
		eq(fx.poison, nil, "milk earlier, poison ran out")

		-- Java: damage armour protects against adds 0.1 exhaustion; a fall adds none
		G.frame(1)
		local e0 = Survival.snapshot(player).exhaustion
		Survival.damage(player, 1, "fell from a high place")
		eq(Survival.snapshot(player).exhaustion, e0, "falls cost no exhaustion")
		G.frame(1)
		local e1 = Survival.snapshot(player).exhaustion
		Survival.damage(player, 1, "zombie", nil, { armor = true })
		assert(math.abs(Survival.snapshot(player).exhaustion - e1 - 0.1) < 1e-9, "a hit costs 0.1")

		-- effects are saved and come back
		local snap = Survival.snapshot(player)
		local back = Effects.decode(snap.effects)
		eq(back.resistance.amp, 0)

		for _, path in {
			"src/shared/Net/Remotes.luau", "src/server/World/WorldService.luau", "src/server/Player/InventoryService.luau",
			"src/server/Player/SpawnService.luau", "src/server/Interaction/BlockActionService.luau",
			"src/server/Survival/DayNightService.luau", "src/server/Player/BedService.luau",
		} do
			Loader.stubs[path] = nil
		end
		for _, k in { "game", "workspace", "Instance", "Enum", "CFrame", "Vector2", "Color3", "UDim2", "UDim", "task", "os", "time", "tick", "warn", "Random" } do
			Loader.globals[k] = nil
		end
		Loader.forget("src/server/")
	end)
end
