--!nocheck
local Loader = require("./Loader")
local Fake = require("./FakeRoblox")
return function(test, eq)
	local Fishing = Loader.require("src/shared/Items/Fishing")
	local Items = Loader.require("src/shared/Items/ItemRegistry")
	test("fishing: exhaustively verifies the catch table and every equippable armor piece", function()
		local counts = {}
		for category = 1, 100 do
			for variety = 1, 100 do
				for slot = 1, 4 do
					local key = Fishing.catch(category, variety, slot)
					counts[key] = (counts[key] or 0) + 1
				end
			end
		end
		local craft = Loader.require("src/shared/Items/Crafting")
		local rodGrid = {}
		for _, slot in { 3, 5, 7 } do rodGrid[slot] = { item = "stick", count = 1 } end
		for _, slot in { 6, 9 } do rodGrid[slot] = { item = "string", count = 1 } end
		eq(craft.match(rodGrid, 3).item, "fishing_rod")
		local fishCount = 0
		for _, fish in Fishing.SPECIES do
			assert(Items.get(fish.key).food)
			eq(counts[fish.key], fish.weight * 320)
			fishCount += counts[fish.key]
		end
		eq(fishCount, 32000)
		eq(#Fishing.SPECIES, 16)
		for material, weight in { leather = 30, chainmail = 25, iron = 20, golden = 15, diamond = 10 } do
			for _, piece in { "helmet", "chestplate", "leggings", "boots" } do
				local key = material .. "_" .. piece
				eq(counts[key], weight * 20)
				assert(Items.get(key).armor)
			end
		end
	end)

	test("fishing server: dry cast, early reel, bite, single award, overflow, cancellation and water loss", function()
		local G = Fake.newGame()
		for k, v in G.env do Loader.globals[k] = v end
		Loader.globals.ColorSequence = require("@lune/roblox").ColorSequence
		Loader.forget("src/server/")
		Fake.mount(G.game:GetService("ReplicatedStorage"), "Shared", Loader.node("src/shared"))
		local c = Fake.newCharacter("Angler", Fake.CFrame.new(1.5, 9, 1.5))
		c.HumanoidRootPart.Anchored = true
		c.Parent = G.workspace
		G.player.Character = c
		local remote = Fake.Instance.new("RemoteEvent")
		local blocks = Loader.require("src/shared/Blocks/BlockRegistry")
		local floor = blocks.id("stone")
		local water = blocks.id("water")
		local rod = { item = "fishing_rod", count = 1, durability = 64 }
		local spills = 0
		-- Force a diamond-boots catch through the actual inventory insertion path.
		local rolls = { 1, 100, 4, 1, 100, 4 }
		Loader.globals.Random = { new = function()
			return { NextNumber = function() return 6 end, NextInteger = function(_, lo, hi)
				local result = table.remove(rolls, 1)
				assert(result and result >= lo and result <= hi)
				return result
			end }
		end }
		local stubs = {
			["src/shared/Net/Remotes.luau"] = { get = function() return remote end },
			["src/server/World/WorldService.luau"] = { getBlockIfLoaded = function(_, y) return if y <= 0 then floor else 0 end },
			["src/server/World/BlockEntityService.luau"] = { setChangedCallback = function() end },
			["src/server/World/ItemEntityService.luau"] = { spawn = function(s)
				eq(s.item, "diamond_boots")
				eq(s.durability, Items.get(s.item).tool.durability)
				spills += 1
			end },
		}
		for path, stub in stubs do Loader.stubs[path] = stub end
		local inventory = Loader.require("src/server/Player/InventoryService")
		inventory.setSlot(G.player, 1, rod)
		Loader.require("src/server/Simulation/FishingService").init()
		local function use() remote.OnServerEvent:Fire(G.player, Fake.Vector3.new(0, -0.3, -0.9539392)) end
		local function message() return rawget(remote, "__toClient")[#rawget(remote, "__toClient")][2] end
		local function untilMessage(target)
			for _ = 1, 600 do
				if message() == target then return end
				G.frame(1 / 30)
			end
			error("Expected " .. target .. ", saw " .. message())
		end
		use()
		untilMessage("Cast into open water")
		floor = water
		use()
		untilMessage("Watch the float…")
		use()
		eq(message(), "Reeled in empty")
		eq(inventory.getSlot(G.player, 2), nil)
		for _, overflow in { false, true } do
			if overflow then
				for i = 3, Loader.require("src/shared/Config").INVENTORY_SLOTS do
					inventory.setSlot(G.player, i, { item = "stone", count = 64 })
				end
			end
			G.frame(0.2); use()
			untilMessage("Bite! Reel in!")
			use(); use()
			local caught = inventory.getSlot(G.player, 2)
			eq(caught.item, "diamond_boots")
			eq(caught.count, 1)
			eq(caught.durability, Items.get("diamond_boots").tool.durability)
			eq(spills, if overflow then 1 else 0)
			assert(not G.workspace:FindFirstChild("FishingFloat"))
		end
		eq(rod.durability, 62)
		eq(spills, 1)
		G.frame(0.2); use()
		untilMessage("Bite! Reel in!")
		untilMessage("Missed the bite · waiting for another")
		eq(#rolls, 0)
		inventory.setSlot(G.player, 1, nil)
		untilMessage("Line withdrawn")
		inventory.setSlot(G.player, 1, rod)
		use()
		untilMessage("Watch the float…")
		floor = 0
		untilMessage("The float is out of water")
		for path in stubs do Loader.stubs[path] = nil end
		for k in G.env do Loader.globals[k] = nil end
		Loader.globals.ColorSequence = nil
		Loader.forget("src/server/")
	end)
end
