--!nocheck
-- Phase 10a: experience (Gameplay/Experience, the REAL ExperienceService in a fake Roblox).
-- Expected values follow the Minecraft Wiki "Experience" page and Java's Player / ExperienceOrb.
--
-- Usage (from run.luau):  require("./ExperienceTests")(test, eq)

local Loader = require("./Loader")
local Fake = require("./FakeRoblox")
local Vector3 = (require("@lune/roblox") :: any).Vector3

return function(test: (string, () -> ()) -> (), eq: (any, any, string?) -> ())
	print("Experience (Phase 10a)")
	local Experience = Loader.require("src/shared/Gameplay/Experience")
	local FurnaceLogic = Loader.require("src/shared/Items/FurnaceLogic")
	local Crafting = Loader.require("src/shared/Items/Crafting")
	local Recipes = Loader.require("src/shared/Items/Recipes")
	local SaveFormat = Loader.require("src/shared/Persistence/SaveFormat")

	test("level curve: Java points per level and the wiki's totals", function()
		eq(Experience.needed(0), 7)
		eq(Experience.needed(15), 37)
		eq(Experience.needed(16), 42)
		eq(Experience.needed(29), 107)
		eq(Experience.needed(30), 112)
		eq(Experience.needed(31), 121)
		-- wiki: total experience to reach a level
		eq(Experience.totalFor(16), 352) -- 16 levels (L^2 + 6L)
		eq(Experience.totalFor(30), 1395) -- 2.5 L^2 - 40.5 L + 360
		eq(Experience.totalFor(31), 1507)
		eq(Experience.totalFor(40), 2920) -- 4.5 L^2 - 162.5 L + 2220
		for _, l in { 5, 10, 15 } do
			eq(Experience.totalFor(l), l * l + 6 * l)
		end
		for _, l in { 17, 22, 31 } do
			eq(Experience.totalFor(l), 2.5 * l * l - 40.5 * l + 360)
		end
	end)

	test("giving points: levels roll over like Java, total and score count every point", function()
		local s = Experience.new()
		eq(Experience.addPoints(s, 7), 1, "7 points: level 1")
		eq(s.level, 1); eq(s.progress, 0)
		Experience.addPoints(s, 4) -- 4 of 9
		eq(s.level, 1)
		assert(math.abs(s.progress - 4 / 9) < 1e-6, `progress {s.progress}`)
		-- one big gift crosses several levels at once
		local t = Experience.new()
		local gained = Experience.addPoints(t, 1395)
		eq(gained, 30); eq(t.level, 30)
		assert(t.progress < 1e-4, `progress {t.progress}`)
		eq(t.total, 1395); eq(t.score, 1395)
		-- small orbs one at a time reach the same level
		local u = Experience.new()
		for _ = 1, 1395 do
			Experience.addPoints(u, 1)
		end
		eq(u.level, 30, "1395 single points: level 30")
		-- levels can be taken (enchanting, 10b): below 0 everything resets
		Experience.addLevels(u, -3)
		eq(u.level, 27)
		Experience.addLevels(u, -100)
		eq(u.level, 0); eq(u.progress, 0); eq(u.total, 0)
		-- progress is a 32-bit float like Java's
		eq(Experience.f32(0.1) ~= 0.1, true)
	end)

	test("orbs: Java's split values and icon sizes; death drop 7 x level up to 100", function()
		local function sum(t)
			local n = 0
			for _, v in t do
				n += v
			end
			return n
		end
		local s = Experience.split(5)
		-- a monster's 5 = orbs of 3, 1 and 1
		eq(#s, 3); eq(s[1], 3); eq(s[2], 1); eq(s[3], 1)
		local s100 = Experience.split(100)
		eq(s100[1], 73); eq(s100[2], 17); eq(s100[3], 7); eq(s100[4], 3)
		eq(sum(s100), 100)
		eq(Experience.orbValue(2500), 2477)
		eq(Experience.orbIcon(1), 0); eq(Experience.orbIcon(3), 1); eq(Experience.orbIcon(17), 3)
		eq(Experience.orbIcon(2477), 10)
		eq(Experience.deathDrop(0), 0)
		eq(Experience.deathDrop(5), 35)
		eq(Experience.deathDrop(14), 98)
		eq(Experience.deathDrop(15), 100)
		eq(Experience.deathDrop(300), 100)
	end)

	test("sources: mobs, ores, breeding, fishing, smelting values", function()
		local function fixed(a, _b)
			return a
		end
		eq(Experience.mobReward("zombie", fixed), 5)
		eq(Experience.mobReward("sneaker", fixed), 5)
		eq(Experience.mobReward("voidling", fixed), 5)
		eq(Experience.mobReward("cow", function(a, b) return b end), 3, "animals 1-3")
		eq(Experience.mobReward("chicken", fixed), 1)
		eq(Experience.ORE.coal_ore[1], 0); eq(Experience.ORE.coal_ore[2], 2)
		eq(Experience.ORE.diamond_ore[1], 3); eq(Experience.ORE.diamond_ore[2], 7)
		eq(Experience.ORE.lapis_ore[1], 2); eq(Experience.ORE.lapis_ore[2], 5)
		eq(Experience.ORE.volt_ore[1], 1); eq(Experience.ORE.volt_ore[2], 5)
		eq(Experience.ORE.iron_ore, nil, "iron, copper, gold ores give none (their smelting does)")
		eq(Experience.BREED[1], 1); eq(Experience.BREED[2], 7)
		eq(Experience.FISH[1], 1); eq(Experience.FISH[2], 6)
		-- every smelting recipe has its Java value
		for input, result in Recipes.smelting do
			assert(Experience.smeltValue(input, result) > 0, `no experience for smelting {input}`)
		end
		eq(Experience.smeltValue("raw_iron", "iron_ingot"), 0.7)
		eq(Experience.smeltValue("raw_gold", "gold_ingot"), 1.0)
		eq(Experience.smeltValue("cactus", "green_dye"), 1.0)
		eq(Experience.smeltValue("raw_beef", "steak"), 0.35)
		-- payout: 10 iron = 7 exactly; 3 sand = 0.3 -> 1 with a 30 % chance
		eq(Experience.furnacePayout({ raw_iron = 10 }, Crafting.smeltResult, function() return 0.99 end), 7)
		eq(Experience.furnacePayout({ sand = 3 }, Crafting.smeltResult, function() return 0.1 end), 1)
		eq(Experience.furnacePayout({ sand = 3 }, Crafting.smeltResult, function() return 0.5 end), 0)
		eq(Experience.furnacePayout({ raw_iron = 1, raw_gold = 1 }, Crafting.smeltResult, function() return 0.99 end), 1, "0.7 -> 0, 1.0 -> 1")
	end)

	test("furnace remembers what it smelted (and it saves)", function()
		local st = FurnaceLogic.new()
		st.slots[1] = { item = "raw_iron", count = 3 }
		st.slots[2] = { item = "coal", count = 1 }
		for _ = 1, (Recipes.SMELT_SECONDS * 3 + 1) * 4 do
			FurnaceLogic.step(st, 0.25)
		end
		eq(st.used.raw_iron, 3)
		eq(st.slots[3].count, 3)
		-- the save keeps it
		local region = SaveFormat.decodeRegion(SaveFormat.encodeRegion({ chunks = {}, entities = {
			{ kind = "furnace", x = 1, y = 2, z = 3, slots = st.slots, burn = st.burn, burnMax = st.burnMax, progress = st.progress, data = { used = st.used } },
		} }))
		eq(region.entities[1].data.used.raw_iron, 3)
		-- player save
		local rec = SaveFormat.encodePlayer({ slots = {}, selected = 1, health = 20, food = 20, saturation = 5, exhaustion = 0, air = 15,
			yaw = 0, xp = { level = 12, progress = 0.25, total = 200, score = 210 } })
		local back = SaveFormat.decodePlayer(rec, 41)
		eq(back.xp.level, 12); eq(back.xp.progress, 0.25); eq(back.xp.total, 200); eq(back.xp.score, 210)
		local none = SaveFormat.decodePlayer(SaveFormat.encodePlayer({ slots = {}, selected = 1, health = 20, food = 20, saturation = 5,
			exhaustion = 0, air = 15, yaw = 0 }), 41)
		eq(none.xp, nil, "old saves have no experience")
	end)

	test("orb motion: falls and settles, rises in water, chases a player within 8 blocks, despawns at 6000 ticks", function()
		local FLOOR = 10
		local function move(o, dx, dy, dz)
			local ny = o.y + dy
			local ground = false
			if ny <= FLOOR then
				ny = FLOOR
				ground = true
			end
			local mx, my, mz = dx, ny - o.y, dz
			o.x += dx; o.y = ny; o.z += dz
			return mx, my, mz, ground
		end
		local dry = function() return nil end
		local r = function() return 0.5 end
		local o = Experience.newOrb(1, 3, 0, 15, 0, r)
		for _ = 1, 100 do
			Experience.stepOrb(o, move, dry, nil, 1.62, r)
		end
		eq(o.y, FLOOR, "on the floor")
		assert(math.abs(o.vy) < 1e-9, `resting vy {o.vy}`)
		-- in water it floats up
		local w = Experience.newOrb(2, 3, 0, 12, 0, r)
		w.vy = 0
		local wet = function() return "water" end
		for _ = 1, 40 do
			Experience.stepOrb(w, move, wet, nil, 1.62, r)
		end
		assert(w.y > 12, `rises in water ({w.y})`)
		-- lava: gone after 2 ticks
		local l = Experience.newOrb(3, 3, 0, 12, 0, r)
		local lava = function() return "lava" end
		eq(Experience.stepOrb(l, move, lava, nil, 1.62, r), true)
		eq(Experience.stepOrb(l, move, lava, nil, 1.62, r), false)
		-- a player 6 blocks away pulls it in
		local c = Experience.newOrb(4, 3, 0, FLOOR, 0, r)
		local target = Vector3.new(6, FLOOR, 0)
		local reached = nil
		for t = 1, 400 do
			Experience.stepOrb(c, move, dry, target, 1.62, r)
			if Experience.touches(c, target) then
				reached = t
				break
			end
		end
		assert(reached, `never reached the player ({c.x})`)
		-- 9 blocks away: out of range, it stays
		local far = Experience.newOrb(6, 3, 0, FLOOR, 0, r)
		far.vx, far.vz = 0, 0
		for _ = 1, 100 do
			Experience.stepOrb(far, move, dry, Vector3.new(9, FLOOR, 0), 1.62, r)
		end
		assert(math.abs(far.x) < 0.01, `far orb moved ({far.x})`)
		eq(Experience.touches(c, target), true)
		-- age
		local d = Experience.newOrb(5, 1, 0, FLOOR, 0, r)
		d.age = 5998
		eq(Experience.stepOrb(d, move, dry, nil, 1.62, r), true)
		eq(Experience.stepOrb(d, move, dry, nil, 1.62, r), false)
		-- merging: same value and ids 40 apart
		local a1, a2, a3 = Experience.newOrb(1, 3, 0, 0, 0, r), Experience.newOrb(41, 3, 0, 0, 0, r), Experience.newOrb(2, 3, 0, 0, 0, r)
		eq(Experience.canMerge(a1, a2), true)
		eq(Experience.canMerge(a1, a3), false)
	end)

	test("server (real ExperienceService): a kill's orbs fly to the player, one every 2 ticks; death drops 7 x level", function()
		local G = Fake.newGame()
		for k, v in G.env do
			Loader.globals[k] = v
		end
		Loader.forget("src/server/")
		local FLOOR = 64
		local STONE = Loader.require("src/shared/Blocks/BlockRegistry").id("stone")
		local function getb(_x, y, _z)
			return if y < FLOOR then STONE else 0
		end
		local remotes = {}
		local function remote(name)
			local r = remotes[name]
			if not r then
				r = Fake.Instance.new("RemoteEvent")
				remotes[name] = r
			end
			return r
		end
		local function sentOf(kind)
			local n = 0
			for _, e in rawget(remote("Experience"), "__toClient") or {} do
				if e[2].type == kind then
					n += 1
				end
			end
			return n
		end
		Loader.stubs["src/shared/Net/Remotes.luau"] = { get = remote, getUnreliable = remote }
		Loader.stubs["src/server/World/WorldService.luau"] = { getBlock = getb, getBlockIfLoaded = getb }
		Fake.mount(G.game:GetService("ReplicatedStorage"), "Shared", Loader.node("src/shared"))
		local XS = Loader.require("src/server/Player/ExperienceService")
		XS.init()
		local BS = 3
		local player = G.player
		-- the player 4 blocks from where the orbs appear
		local c = Fake.newCharacter("Tester", Fake.CFrame.new(4.5 * BS, FLOOR * BS + 3, 0.5 * BS))
		c.HumanoidRootPart.Anchored = true
		c.Parent = G.workspace
		player.Character = c
		local function frames(n)
			for _ = 1, n do
				G.frame(0.05)
			end
		end
		XS.award(Vector3.new(0.5, FLOOR, 0.5), 100) -- 73 + 17 + 7 + 3
		eq(XS.stats.orbs, 0, "(counted on the next tick)")
		frames(1)
		eq(XS.stats.orbs, 4)
		frames(80)
		eq(XS.stats.orbs, 0, "all picked up")
		local x = XS.get(player)
		eq(x.total, 100)
		eq(x.level, 7, "100 points: level 7 (91 + 9 of 21)")
		eq(sentOf("pickup"), 4)
		-- one pickup per 2 ticks: ten 1-point orbs right on the player take 19-20 ticks
		for _ = 1, 10 do
			XS.orb(Vector3.new(4.5, FLOOR, 0.5), 1)
		end
		frames(17)
		assert(XS.stats.orbs > 0, "not all taken yet")
		frames(6)
		eq(XS.stats.orbs, 0)
		eq(XS.get(player).total, 110)
		-- death: level 7 drops 49 points, everything resets
		XS.onDeath(player, Vector3.new(0.5, FLOOR, 0.5))
		eq(XS.get(player).level, 0)
		eq(XS.get(player).total, 0)
		frames(1)
		local orbTotal = 0
		for _, part in G.workspace.XPOrbs:GetChildren() do
			orbTotal += part:GetAttribute("Value")
		end
		eq(orbTotal, 49)
		-- commands (Studio: allowed)
		remotes.XpCommand.OnServerEvent:Fire(player, { "add", "30", "levels" })
		eq(XS.get(player).level, 30)
		assert(sentOf("levelup") >= 1, "level 30: the level-up sound")
		-- snapshot / restore
		local snap = XS.snapshot(player)
		eq(snap.level, 30)
	end)
end
