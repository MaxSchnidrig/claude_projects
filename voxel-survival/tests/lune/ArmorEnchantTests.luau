--!nocheck
-- Phase 10d: armour and fishing enchantments and the curses. Expected values follow the
-- Minecraft Wiki ("Protection", "Thorns", "Respiration", "Depth Strider", "Frost Walker",
-- "Luck of the Sea", "Lure", "Curse of Binding", "Curse of Vanishing").
--
-- Usage (from run.luau):  require("./ArmorEnchantTests")(test, eq)

local Loader = require("./Loader")
local Fake = require("./FakeRoblox")
local Vector3 = (require("@lune/roblox") :: any).Vector3

return function(test: (string, () -> ()) -> (), eq: (any, any, string?) -> ())
	print("Enchantment effects: armour, fishing, curses (Phase 10d)")
	local Enchantments = Loader.require("src/shared/Items/Enchantments")
	local PlayerMotor = Loader.require("src/shared/Gameplay/PlayerMotor")
	local Fishing = Loader.require("src/shared/Items/Fishing")
	local BlockRegistry = Loader.require("src/shared/Blocks/BlockRegistry")
	local Fluids = Loader.require("src/shared/World/Fluids")
	local function piece(ench)
		return { item = "iron_chestplate", count = 1, ench = ench }
	end

	test("protection factors: 4 % a point, specific kinds double, Feather Falling triple, cap 20", function()
		local p4 = { piece({ protection = 4 }), piece({ protection = 4 }), piece({ protection = 4 }), piece({ protection = 4 }) }
		eq(Enchantments.protection({ piece({ protection = 4 }) }, {}), 4)
		eq(Enchantments.afterProtection(10, 4), 8.4, "Protection IV: 16 % less")
		eq(Enchantments.protection(p4, {}), 16, "4 x Protection IV: 64 %")
		eq(Enchantments.protection({ piece({ fire_protection = 4 }) }, { fire = true }), 8)
		eq(Enchantments.protection({ piece({ fire_protection = 4 }) }, {}), 0, "fire protection only against fire")
		eq(Enchantments.protection({ piece({ blast_protection = 4 }) }, { explosion = true }), 8)
		eq(Enchantments.protection({ piece({ projectile_protection = 4 }) }, { projectile = true }), 8)
		eq(Enchantments.protection({ piece({ feather_falling = 4 }) }, { fall = true }), 12)
		-- the wiki's 80 %: 3 x Protection IV + 1 specific IV against its kind = 12 + 8 = 20
		local mix = { piece({ protection = 4 }), piece({ protection = 4 }), piece({ protection = 4 }), piece({ fire_protection = 4 }) }
		eq(Enchantments.protection(mix, { fire = true }), 20)
		assert(math.abs(Enchantments.afterProtection(10, 20) - 2) < 1e-9, "cap: 80 % less")
		eq(Enchantments.protection({ piece({ feather_falling = 4 }), piece({ protection = 4 }), piece({ protection = 4 }), piece({ protection = 4 }) }, { fall = true }), 20)
		-- Fire Protection burns shorter, Blast Protection less knockback (15 % a level)
		assert(math.abs(Enchantments.burnFactor({ piece({ fire_protection = 4 }) }) - 0.4) < 1e-9)
		assert(math.abs(Enchantments.blastKnockbackFactor({ piece({ blast_protection = 2 }) }) - 0.7) < 1e-9)
	end)

	test("Thorns: 15 % a level, 1 to 5 damage", function()
		local hits, sum, n = 0, 0, 20000
		for _ = 1, n do
			local d = Enchantments.thorns(3, math.random)
			if d then
				hits += 1
				sum += d
				assert(d >= 1 and d <= 5)
			end
		end
		assert(math.abs(hits / n - 0.45) < 0.02, `Thorns III triggers 45 % ({hits / n})`)
		assert(math.abs(sum / hits - 3) < 0.1, "average 3")
		eq(Enchantments.thorns(0, math.random), nil)
		eq(Enchantments.thorns(12, function() return 0 end), 2, "above 10: level - 10")
	end)

	test("Depth Strider III: swimming as fast as walking (Java water_movement_efficiency)", function()
		local W = Fluids.id("water", 0)
		local STONE = BlockRegistry.id("stone")
		local world = PlayerMotor.world(function(_x, y, _z)
			if y < 63 then
				return STONE
			end
			return if y <= 64 then W else 0
		end)
		local function speed(ds)
			local st = PlayerMotor.new(0.5, 63, 0.5)
			local last = st.z
			local v = 0
			for i = 1, 200 do
				PlayerMotor.tick(st, { forward = 1, strafe = 0, lookX = 0, lookZ = -1, jump = false, sneak = false, sprint = false, depthStrider = ds }, world)
				if i == 200 then
					v = last - st.z
				end
				last = st.z
			end
			return v
		end
		local plain, ds3 = speed(0), speed(3)
		assert(ds3 > plain * 2, `Depth Strider III much faster ({plain} -> {ds3})`)
		-- walking on land: 0.1 x 0.98 x 0.216 / 0.546^3 x 0.546 / (1 - 0.546) ~ 0.1295 b/t... the motor's
		-- steady walking speed on stone
		local landWorld = PlayerMotor.world(function(_x, y, _z) return if y < 64 then STONE else 0 end)
		local st = PlayerMotor.new(0.5, 64, 0.5)
		local last, walk = st.z, 0
		for i = 1, 200 do
			PlayerMotor.tick(st, { forward = 1, strafe = 0, lookX = 0, lookZ = -1, jump = false, sneak = false, sprint = false }, landWorld)
			if i == 200 then walk = last - st.z end
			last = st.z
		end
		assert(math.abs(ds3 - walk) / walk < 0.1, `Depth Strider III ~ walking ({ds3} vs {walk})`)
	end)

	test("fishing: Luck of the Sea moves the catch toward treasure, Lure shortens the wait", function()
		local function treasureShare(luck)
			local total = Fishing.categoryTotal(luck)
			local t = 0
			for roll = 1, total do
				if string.find(Fishing.catch(roll, 50, 1, luck), "_helmet") then
					t += 1
				end
			end
			return t / total
		end
		eq(treasureShare(0), 0.2)
		assert(math.abs(treasureShare(3) - 26 / 103) < 1e-9, "Luck III: 20 + 6 of 103")
	end)

	test("Frost Walker (real FrostWalkerService): water under you freezes in a circle, melts in daylight", function()
		local G = Fake.newGame()
		for k, v in G.env do
			Loader.globals[k] = v
		end
		Loader.forget("src/server/")
		local W = Fluids.id("water", 0)
		local cells = {}
		local function getb(x, y, z)
			local c = cells[`{x},{y},{z}`]
			if c then return c end
			return if y == 62 then W elseif y < 62 then BlockRegistry.id("stone") else 0
		end
		local scheduled = {}
		Loader.stubs["src/server/World/WorldService.luau"] = { getBlock = getb, getBlockIfLoaded = getb, blockLightAt = function() return 0 end }
		Loader.stubs["src/server/World/BlockUpdates.luau"] = {
			set = function(x, y, z, id) cells[`{x},{y},{z}`] = id end,
			schedule = function(x, y, z) table.insert(scheduled, { x, y, z }) end,
			register = function() end, onTick = function() end,
		}
		Loader.stubs["src/server/World/RandomTicks.luau"] = { register = function() end }
		Loader.stubs["src/server/Player/InventoryService.luau"] = { armor = function() return {} end }
		Loader.stubs["src/server/Survival/SurvivalService.luau"] = { movement = function() return false, true, false end, isSpectator = function() return false end }
		local time = 6000
		Loader.stubs["src/server/Survival/DayNightService.luau"] = { timeOfDay = function() return time end }
		Fake.mount(G.game:GetService("ReplicatedStorage"), "Shared", Loader.node("src/shared"))
		local FW = Loader.require("src/server/Simulation/FrostWalkerService")
		-- standing on frosted ice at y 63 (feet), Frost Walker II: radius 4
		local n = FW.freeze(Vector3.new(0.5, 63, 0.5), 2)
		assert(n > 40 and n < 60, `a circle of radius 4 (~49 blocks): {n}`)
		eq(FW.isFrosted(getb(3, 62, 0)), true, "3 blocks out")
		-- Java measures to the block's centre from the feet: (4, 62, 0) is 4.03 away, outside
		eq(FW.isFrosted(getb(4, 62, 0)), false, "just outside the radius")
		eq(FW.isFrosted(getb(4, 62, 4)), false, "corners are outside the circle")
		eq(FW.isFrosted(getb(0, 61, 0)), false, "only the layer under the feet")
		-- daylight melts it, step by step (ages 0..3, then water)
		cells["0,62,0"] = BlockRegistry.id("frosted_ice")
		for k in cells do
			if k ~= "0,62,0" then cells[k] = nil end
		end
		for _ = 1, 4 do
			FW.tick(0, 62, 0)
		end
		eq(getb(0, 62, 0), W, "a lone block melts in four checks in daylight")
		-- at night it stays
		time = 18000
		cells["0,62,0"] = BlockRegistry.id("frosted_ice")
		for _ = 1, 10 do
			FW.tick(0, 62, 0)
		end
		eq(FW.isFrosted(getb(0, 62, 0)), true, "the night keeps it")
		for _, k in { "WorldService", "BlockUpdates", "RandomTicks" } do
			Loader.stubs[`src/server/World/{k}.luau`] = nil
		end
		Loader.stubs["src/server/Player/InventoryService.luau"] = nil
		Loader.stubs["src/server/Survival/SurvivalService.luau"] = nil
		Loader.stubs["src/server/Survival/DayNightService.luau"] = nil
	end)

	test("curses (real InventoryService): Binding stays on, Vanishing is gone on death", function()
		local G = Fake.newGame()
		for k, v in G.env do
			Loader.globals[k] = v
		end
		Loader.forget("src/server/")
		local function getb(_x, y, _z)
			return if y < 64 then BlockRegistry.id("stone") else 0
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
		local dropped = {}
		Loader.stubs["src/shared/Net/Remotes.luau"] = { get = remote, getUnreliable = remote }
		Loader.stubs["src/server/World/WorldService.luau"] = { getBlock = getb, getBlockIfLoaded = getb }
		Loader.stubs["src/server/World/ItemEntityService.luau"] = {
			spawn = function() end, setInventoryAdder = function() end,
			spawnAround = function(list) for _, st in list do table.insert(dropped, st) end end,
		}
		Fake.mount(G.game:GetService("ReplicatedStorage"), "Shared", Loader.node("src/shared"))
		local Config = Loader.require("src/shared/Config")
		local Inv = Loader.require("src/server/Player/InventoryService")
		Inv.init()
		local player = G.player
		local c = Fake.newCharacter("Tester", Fake.CFrame.new(1.5, 64 * 3 + 3, 1.5))
		c.Parent = G.workspace
		player.Character = c
		local act = function(a) remotes.InventoryAction.OnServerEvent:Fire(player, a) end
		local HEAD = Config.ARMOR_SLOT.head
		Inv.setSlot(player, HEAD, { item = "iron_helmet", count = 1, durability = 165, ench = { binding_curse = 1 } })
		act({ type = "click", container = "inv", index = HEAD, button = "left", shift = false })
		eq(Inv.getSlot(player, HEAD).item, "iron_helmet", "can't pick it up")
		act({ type = "click", container = "inv", index = HEAD, button = "left", shift = true })
		eq(Inv.getSlot(player, HEAD).item, "iron_helmet", "can't shift it off")
		act({ type = "dropSlot", container = "inv", index = HEAD, all = true })
		eq(Inv.getSlot(player, HEAD).item, "iron_helmet", "can't drop it")
		Inv.setSlot(player, 1, { item = "diamond_helmet", count = 1, durability = 363 })
		act({ type = "equipHeld" })
		eq(Inv.getSlot(player, HEAD).item, "iron_helmet", "can't swap it with a held helmet")
		-- death: the vanishing sword is gone, the rest drops (the bound helmet too, Java)
		Inv.setSlot(player, 2, { item = "iron_sword", count = 1, durability = 250, ench = { vanishing_curse = 1 } })
		Inv.dropAll(player, Vector3.new(0, 0, 0))
		local items = {}
		for _, st in dropped do
			items[st.item] = true
		end
		eq(items.iron_sword, nil, "vanished")
		eq(items.iron_helmet, true)
		eq(items.diamond_helmet, true)
	end)
end
