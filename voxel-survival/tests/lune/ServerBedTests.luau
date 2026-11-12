--!nocheck
-- Runs the REAL src/server/Player/BedService.luau in a fake Roblox (FakeRoblox.luau) with a
-- small world, and checks where players respawn and stand up.
--
-- Usage (from run.luau):  require("./ServerBedTests")(test, eq)

local Loader = require("./Loader")
local Fake = require("./FakeRoblox")

local Vector3 = Fake.Vector3
local BS = 3 -- Config.BLOCK_SIZE

return function(test: (string, () -> ()) -> (), eq: (any, any, string?) -> ())
	print("Server beds (real BedService in a fake Roblox)")

	local function near(a: number, b: number, label: string)
		if math.abs(a - b) > 1e-4 then
			error(`{label}: expected {b}, got {a}`, 2)
		end
	end

	test("server: respawn on the bed when there's room, else beside it, never inside a block", function()
		local G = Fake.newGame()
		for k, v in G.env do
			Loader.globals[k] = v
		end
		Loader.forget("src/client/")
		Loader.forget("src/server/")
		local BlockRegistry = Loader.require("src/shared/Blocks/BlockRegistry")
		local Placement = Loader.require("src/shared/Blocks/Placement")
		local STONE = BlockRegistry.id("stone")
		local FLOOR = 64
		local cells: { [string]: number } = {}
		local resolver = nil
		local remote = Fake.Instance.new("RemoteEvent")
		Loader.stubs["src/server/World/WorldService.luau"] = {
			getBlock = function(x: number, y: number, z: number): number
				return cells[`{x},{y},{z}`] or (if y < FLOOR then STONE else 0)
			end,
		}
		Loader.stubs["src/server/Player/SpawnService.luau"] = {
			setRespawnResolver = function(fn)
				resolver = fn
			end,
		}
		Loader.stubs["src/server/Survival/DayNightService.luau"] = {
			ticks = function() return 13000 end,
			timeOfDay = function() return 13000 end,
			addTicks = function() end,
		}
		Loader.stubs["src/server/Mobs/MobService.luau"] = { anyIn = function() return false end }
		Loader.stubs["src/shared/Net/Remotes.luau"] = { get = function() return remote end }
		Fake.mount(G.game:GetService("ReplicatedStorage"), "Shared", Loader.node("src/shared"))
		local BedService = Loader.require("src/server/Player/BedService")
		BedService.init()
		assert(resolver, "BedService registered a respawn resolver")

		-- a white bed facing east: foot at (10, FLOOR, 10), head at (11, FLOOR, 10)
		local changes = Placement.resolve(BlockRegistry.id("white_bed"), {
			hx = 10, hy = FLOOR - 1, hz = 10, nx = 0, ny = 1, nz = 0, px = 10.5, py = FLOOR, pz = 10.5, lx = 1, lz = 0,
		}, function(x, y, z)
			return cells[`{x},{y},{z}`] or (if y < FLOOR then STONE else 0)
		end)
		assert(changes, "bed placed")
		for _, c in changes do
			cells[`{c.x},{c.y},{c.z}`] = c.id
		end
		local head = Vector3.new(11, FLOOR, 10)
		local player = G.player
		local function respawnFeet(): Vector3?
			BedService.restore(player, head, 0)
			local cf = resolver(player)
			return if cf then (cf.Position - Vector3.new(0, 3.05, 0)) / BS else nil
		end
		-- open room: on the mattress of the head half
		local f = respawnFeet()
		near(f.X, 11.5, "on the bed x")
		near(f.Y, FLOOR + 9 / 16, "on the mattress")
		near(f.Z, 10.5, "on the bed z")
		-- a ceiling 2 blocks up (room under it is too low to stand on the bed): beside it, on the floor
		for x = 8, 13 do
			for z = 8, 12 do
				cells[`{x},{FLOOR + 2},{z}`] = STONE
			end
		end
		f = respawnFeet()
		eq(math.floor(f.Y + 1e-6), FLOOR, "beside the bed, on the floor")
		near(f.Y - math.floor(f.Y), 0, "feet exactly on the floor")
		local function solidAt(x, y, z)
			local id = cells[`{math.floor(x)},{math.floor(y)},{math.floor(z)}`] or (if y < FLOOR then STONE else 0)
			return BlockRegistry.isSolid[id + 1]
		end
		assert(not solidAt(f.X, f.Y + 0.01, f.Z) and not solidAt(f.X, f.Y + 1.01, f.Z), "the spot is free")
		assert(solidAt(f.X, f.Y - 0.01, f.Z), "and has a floor")
		-- boxed in on every side at floor level: on nothing, so back to the world spawn
		for x = 9, 12 do
			for z = 9, 11 do
				if not cells[`{x},{FLOOR},{z}`] then
					cells[`{x},{FLOOR},{z}`] = STONE
					cells[`{x},{FLOOR + 1},{z}`] = STONE
				end
			end
		end
		eq(respawnFeet(), nil, "no room anywhere: world spawn")
		-- the bed is gone: world spawn (and the bed is forgotten)
		cells["11,64,10"] = 0
		cells["10,64,10"] = 0
		eq(respawnFeet(), nil, "no bed")

		for _, path in {
			"src/server/World/WorldService.luau", "src/server/Player/SpawnService.luau",
			"src/server/Survival/DayNightService.luau", "src/server/Mobs/MobService.luau", "src/shared/Net/Remotes.luau",
		} do
			Loader.stubs[path] = nil
		end
	end)

	for _, k in { "game", "workspace", "Instance", "Enum", "CFrame", "Vector2", "Color3", "UDim2", "UDim", "task", "os", "time", "tick", "warn" } do
		Loader.globals[k] = nil
	end
	Loader.forget("src/client/")
	Loader.forget("src/server/")
end
