--!nocheck
-- Runs the REAL src/client/Player/MovementController.luau frame by frame in a fake Roblox
-- (FakeRoblox.luau): keys go in, frames tick, and the body's position is checked where a player
-- would see it. The modules it talks to that need a real client (the chunk store, the server
-- sync, the inventory) are small stand-ins.
--
-- Usage (from run.luau):  require("./ClientMovementTests")(test, eq)

local Loader = require("./Loader")
local Fake = require("./FakeRoblox")

local Vector3, CFrame, Enum = Fake.Vector3, Fake.CFrame, Fake.Enum
local Key = Enum.KeyCode
local BS = 3 -- Config.BLOCK_SIZE
local FRAME = 1 / 60

return function(test: (string, () -> ()) -> (), eq: (any, any, string?) -> ())
	local BlockRegistry = Loader.require("src/shared/Blocks/BlockRegistry")
	local STONE = BlockRegistry.id("stone")
	local FLOOR = 64 -- the ground's top (blocks) in these worlds

	type Game = {
		G: any, MC: any, cells: { [string]: number }, survival: any, inventory: any, remotes: { [string]: any },
		character: any, root: any, humanoid: any, seen: { any }, unloaded: ((number, number, number) -> boolean)?,
	}

	-- Start a fake client with MovementController running. `cells` are blocks above the floor.
	local function boot(cells: { [string]: number }?): Game
		local G = Fake.newGame()
		for k, v in G.env do
			Loader.globals[k] = v
		end
		Loader.forget("src/client/")
		local T: Game = { G = G, cells = cells or {}, remotes = {}, seen = {} } :: any
		T.survival = {
			canSprint = true, dead = false, food = 20,
			sprint = {}, sneak = {}, falls = {},
		}
		function T.survival.setSprinting(on: boolean)
			table.insert(T.survival.sprint, on)
		end
		function T.survival.setSneaking(on: boolean)
			table.insert(T.survival.sneak, on)
		end
		function T.survival.reportFall(blocks: number)
			table.insert(T.survival.falls, blocks)
		end
		T.inventory = { uiOpen = false }
		Loader.stubs["src/client/Survival/SurvivalClient.luau"] = T.survival
		Loader.stubs["src/client/Player/InventoryClient.luau"] = T.inventory
		Loader.stubs["src/client/World/ClientWorld.luau"] = {
			getBlock = function(x: number, y: number, z: number): number?
				if T.unloaded and T.unloaded(x, y, z) then
					return nil
				end
				if y < 0 or y >= 384 then
					return 0
				end
				return T.cells[`{x},{y},{z}`] or (if y < FLOOR then STONE else 0)
			end,
		}
		Loader.stubs["src/shared/Net/Remotes.luau"] = {
			get = function(name: string)
				local r = T.remotes[name]
				if not r then
					r = Fake.Instance.new("RemoteEvent")
					r.Name = name
					T.remotes[name] = r
				end
				return r
			end,
		}
		Fake.mount(G.game:GetService("ReplicatedStorage"), "Shared", Loader.node("src/shared"))
		T.MC = Loader.require("src/client/Player/MovementController")
		T.MC.init()
		-- what a player sees: the body's position when the frame is drawn (after the render
		-- steps, before physics gets its turn)
		G.game:GetService("RunService").RenderStepped:Connect(function()
			if T.root then
				T.seen = { T.root.Position.X / BS, (T.root.Position.Y - 3) / BS, T.root.Position.Z / BS }
			end
		end)
		return T
	end

	-- The server spawns the character with its feet half a stud above (x, y, z) (blocks).
	local function spawn(T: Game, x: number, y: number, z: number)
		if T.character then
			T.character:Destroy()
		end
		local character = Fake.newCharacter("Tester", CFrame.new(x * BS, y * BS + 3.5, z * BS))
		character.Parent = T.G.workspace
		T.character = character
		T.root = character.HumanoidRootPart
		T.humanoid = character.Humanoid
		T.G.player.Character = character
		T.G.player.CharacterAdded:Fire(character)
	end

	local function frames(T: Game, n: number, dt: number?)
		for _ = 1, n do
			T.G.frame(dt or FRAME)
		end
	end

	local function feet(T: Game)
		return T.MC.feet()
	end

	local function near(a: number, b: number, tolerance: number, label: string)
		if math.abs(a - b) > tolerance then
			error(`{label}: expected {b} (within {tolerance}), got {a}`, 2)
		end
	end

	local function wall(cells: { [string]: number }, x0: number, x1: number, z0: number, z1: number, height: number?)
		for x = x0, x1 do
			for z = z0, z1 do
				for y = FLOOR, FLOOR + (height or 3) - 1 do
					cells[`{x},{y},{z}`] = STONE
				end
			end
		end
	end

	local function cleanup()
		for _, path in {
			"src/client/Survival/SurvivalClient.luau", "src/client/Player/InventoryClient.luau",
			"src/client/World/ClientWorld.luau", "src/shared/Net/Remotes.luau",
		} do
			Loader.stubs[path] = nil
		end
	end

	print("Client movement (real MovementController in a fake Roblox)")

	test("client: the body rests on the ground, weightless, in the ghost group; nothing waits", function()
		local T = boot()
		spawn(T, 24.5, FLOOR, 24.5)
		frames(T, 120)
		eq(T.MC.onGround, true)
		near(feet(T).Y, FLOOR, 1e-6, "feet on the floor")
		near(T.seen[2], FLOOR, 1e-4, "the body is drawn on the floor")
		near(T.seen[1], 24.5, 1e-4, "x")
		near(T.seen[3], 24.5, 1e-4, "z")
		eq(T.humanoid:GetState(), Enum.HumanoidStateType.Physics)
		for _, d in T.character:GetDescendants() do
			if d:IsA("BasePart") then
				eq(d.CollisionGroup, "RocraftGhost", d.Name)
				eq(d.CanCollide, false)
			end
		end
		local force = T.root:FindFirstChildOfClass("VectorForce")
		assert(force and force.Attachment0, "anti-gravity force on the root")
		near(force.Force.Y, T.root.AssemblyMass * T.G.workspace.Gravity, 1e-3, "it cancels gravity")
		-- between frames Roblox physics leaves the body where it was put
		near((T.root.Position.Y - 3) / BS, FLOOR, 1e-3, "no drift after physics")
		eq(#Fake.warnings, 0, "warnings: " .. table.concat(Fake.warnings, "; "))
		cleanup()
	end)

	test("client: W walks where you look at 4.317 b/s; double-tap sprints at 5.612; FOV follows", function()
		local T = boot()
		spawn(T, 0.5, FLOOR, 0.5)
		frames(T, 30)
		-- yaw 0 looks toward -Z
		T.G.press(Key.W)
		frames(T, 60)
		local z0 = feet(T).Z
		frames(T, 60)
		near(z0 - feet(T).Z, 4.317, 0.02, "walking speed")
		near(feet(T).X, 0.5, 1e-6, "straight")
		eq(T.MC.sprinting, false)
		-- look east (+X): yaw = -90 degrees
		T.MC.lookYaw = -math.pi / 2
		frames(T, 60)
		local x0 = feet(T).X
		frames(T, 60)
		near(feet(T).X - x0, 4.317, 0.02, "walking east")
		-- double-tap W: sprint
		T.G.release(Key.W)
		frames(T, 2)
		T.G.press(Key.W)
		T.G.release(Key.W)
		T.G.press(Key.W)
		frames(T, 60)
		eq(T.MC.sprinting, true)
		eq(T.survival.sprint[#T.survival.sprint], true)
		x0 = feet(T).X
		frames(T, 60)
		near(feet(T).X - x0, 5.612, 0.03, "sprinting speed")
		near(T.G.workspace.CurrentCamera.FieldOfView, 80.5, 0.2, "sprint FOV")
		-- letting go ends it; a slow double tap doesn't start it
		T.G.release(Key.W)
		frames(T, 30)
		eq(T.MC.sprinting, false)
		T.G.press(Key.W)
		T.G.release(Key.W)
		frames(T, 30) -- half a second: too slow
		T.G.press(Key.W)
		frames(T, 30)
		eq(T.MC.sprinting, false)
		-- A / D strafe, S backs up
		T.G.release(Key.W)
		frames(T, 30)
		local zBefore = feet(T).Z
		T.G.press(Key.D)
		frames(T, 60)
		assert(feet(T).Z > zBefore + 2, "D strafes right (looking east: +Z)")
		T.G.release(Key.D)
		cleanup()
	end)

	test("client: walls hold at spawn-like coordinates, in every direction, for minutes", function()
		-- (0.8.8-0.8.10 walked through walls here: positions lived in 32-bit Vector3s)
		for _, case in {
			{ yaw = 0, dx = 0, dz = -1 }, { yaw = math.pi, dx = 0, dz = 1 },
			{ yaw = -math.pi / 2, dx = 1, dz = 0 }, { yaw = math.pi / 2, dx = -1, dz = 0 },
		} do
			for _, base in { 24, 40, 300, -1000 } do
				local cells = {}
				local wx, wz = base + case.dx * 3, base + case.dz * 3
				wall(cells, wx - 3 * math.abs(case.dz), wx + 3 * math.abs(case.dz), wz - 3 * math.abs(case.dx), wz + 3 * math.abs(case.dx))
				local T = boot(cells)
				spawn(T, base + 0.5, FLOOR, base + 0.5)
				T.MC.lookYaw = case.yaw
				frames(T, 10)
				T.G.press(Key.W)
				T.G.release(Key.W)
				T.G.press(Key.W) -- sprint into it
				frames(T, 600)
				local f = feet(T)
				local travelled = (f.X - (base + 0.5)) * case.dx + (f.Z - (base + 0.5)) * case.dz
				local expected = 2.5 - 0.3 -- the wall's near face is 2.5 blocks from the start, the box is 0.3 deep
				near(travelled, expected, 1e-3, `wall at {base}, direction ({case.dx}, {case.dz})`)
				near(T.seen[2], FLOOR, 1e-4, "still on the floor")
				eq(T.MC.sprinting, false) -- Java: running into a wall ends the sprint
				cleanup()
			end
		end
	end)

	test("client: Space jumps 1.2522 blocks; holding it re-jumps; a block is jumped onto in full", function()
		local cells = {}
		wall(cells, 20, 28, 5, 21, 1) -- a 1-block-high terrace to the north
		local T = boot(cells)
		spawn(T, 24.5, FLOOR, 24.5)
		frames(T, 30)
		T.G.press(Key.Space)
		local top, jumps, wasUp = 0, 0, false
		for _ = 1, 180 do
			frames(T, 1)
			local y = T.seen[2] - FLOOR
			top = math.max(top, y)
			if y > 0.5 and not wasUp then
				jumps += 1
			end
			wasUp = y > 0.5
		end
		T.G.release(Key.Space)
		near(top, 1.2522, 0.01, "jump height")
		assert(jumps >= 4 and jumps <= 6, `held jump re-jumps about every 12 ticks ({jumps} jumps in 3 s)`)
		frames(T, 60)
		-- run into the step, then jump while pushing: the jump goes all the way up
		T.G.press(Key.W)
		frames(T, 90)
		near(feet(T).Z, 22.3, 1e-4, "stopped by the step")
		T.G.press(Key.Space)
		top = 0
		for _ = 1, 40 do
			frames(T, 1)
			top = math.max(top, T.seen[2] - FLOOR)
		end
		T.G.release(Key.Space)
		assert(top > 1.2, `full jump against the block (peak {top})`)
		frames(T, 30)
		near(feet(T).Y, FLOOR + 1, 1e-6, "standing on the block")
		cleanup()
	end)

	test("client: a long frame (or no anti-gravity at all) never drops the player through the floor", function()
		for _, forceWorks in { true, false } do
			local T = boot()
			spawn(T, 24.5, FLOOR, 24.5)
			frames(T, 30)
			if not forceWorks then
				T.root:FindFirstChildOfClass("VectorForce").Enabled = false -- as if Roblox ignored it
			end
			frames(T, 30)
			frames(T, 1, 0.8) -- a hitch: physics gets 0.8 s with the body
			frames(T, 1, 2.5) -- and a worse one
			frames(T, 5)
			near(T.seen[2], FLOOR, 1e-4, `on the floor after the hitch (anti-gravity {forceWorks})`)
			near(T.seen[1], 24.5, 1e-4, "x")
			-- walking through hitches
			T.G.press(Key.W)
			for i = 1, 200 do
				frames(T, 1, if i % 20 == 0 then 0.6 else FRAME)
				near(T.seen[2], FLOOR, 1e-4, "walking: on the floor")
			end
			T.G.release(Key.W)
			assert(feet(T).Z < 24.5 - 5, "walked on through the hitches")
			eq(#T.survival.falls, 0)
			cleanup()
		end
	end)

	test("client: spectator (N) hovers, flies through walls, sprints, and lands again", function()
		local cells = {}
		wall(cells, 20, 28, 20, 21, 6)
		local T = boot(cells)
		spawn(T, 24.5, FLOOR, 24.5)
		frames(T, 30)
		T.G.press(Key.N)
		T.G.release(Key.N)
		eq(T.MC.spectating, true)
		eq(T.G.player:GetAttribute("Spectating"), true)
		-- hovering: no sinking
		T.G.press(Key.Space)
		frames(T, 30)
		T.G.release(Key.Space)
		local y0 = feet(T).Y
		near(y0 - FLOOR, 10.92 * 0.5, 0.2, "Space flies up at 10.92 b/s")
		frames(T, 240)
		near(feet(T).Y, y0, 1e-9, "hovers")
		near(T.seen[2], y0, 1e-4, "the body hovers too")
		-- Shift flies down
		T.G.press(Key.LeftShift)
		frames(T, 12)
		T.G.release(Key.LeftShift)
		assert(feet(T).Y < y0 - 1.5, "Shift flies down")
		eq(T.MC.sneaking, false)
		-- through the wall at 10.92 b/s; double-tap doubles it
		local z0 = feet(T).Z
		T.G.press(Key.W)
		frames(T, 60)
		near(z0 - feet(T).Z, 10.92, 0.25, "flies through the wall")
		T.G.release(Key.W)
		T.G.press(Key.W)
		T.G.release(Key.W)
		T.G.press(Key.W)
		frames(T, 2)
		eq(T.MC.sprinting, true)
		z0 = feet(T).Z
		frames(T, 60)
		near(z0 - feet(T).Z, 21.84, 0.5, "sprint-flying")
		T.G.release(Key.W)
		-- the server isn't charged sprint hunger for flying
		for _, on in T.survival.sprint do
			eq(on, false)
		end
		-- back to normal: falls and lands
		T.G.press(Key.N)
		T.G.release(Key.N)
		eq(T.MC.spectating, false)
		frames(T, 240)
		near(feet(T).Y, FLOOR, 1e-6, "landed")
		eq(T.MC.onGround, true)
		cleanup()
	end)

	test("client: typing, open windows and the Roblox menu don't move the player", function()
		local T = boot()
		spawn(T, 0.5, FLOOR, 0.5)
		frames(T, 30)
		T.G.focusTextBox(true)
		T.G.press(Key.W, true)
		T.G.press(Key.Space, true)
		frames(T, 60)
		near(feet(T).Z, 0.5, 1e-9, "typing W doesn't walk")
		near(feet(T).Y, FLOOR, 1e-9, "typing a space doesn't jump")
		T.G.focusTextBox(false)
		T.inventory.uiOpen = true
		frames(T, 60)
		near(feet(T).Z, 0.5, 1e-9, "no walking with a window open")
		T.inventory.uiOpen = false
		T.G.game:GetService("GuiService").MenuIsOpen = true
		frames(T, 60)
		near(feet(T).Z, 0.5, 1e-9, "no walking with the Roblox menu open")
		T.G.game:GetService("GuiService").MenuIsOpen = false
		frames(T, 60)
		assert(feet(T).Z < 0, "walks again")
		cleanup()
	end)

	test("client: sneaking (Shift) is slow, reported, and stops at edges; falls are reported once", function()
		local cells = {}
		-- a platform 5 blocks up
		for x = 20, 28 do
			for z = 20, 28 do
				for y = FLOOR, FLOOR + 4 do
					cells[`{x},{y},{z}`] = STONE
				end
			end
		end
		local T = boot(cells)
		spawn(T, 24.5, FLOOR + 5, 24.5)
		frames(T, 30)
		T.G.press(Key.LeftShift)
		T.G.press(Key.W)
		frames(T, 600)
		eq(T.MC.sneaking, true)
		eq(T.survival.sneak[#T.survival.sneak], true)
		near(feet(T).Y, FLOOR + 5, 1e-6, "still on the platform")
		assert(feet(T).Z < 20.31 and feet(T).Z > 19.69, `stopped at the edge (z {feet(T).Z})`)
		near(T.MC.eyeHeight, 0.81, 0.01, "sneaking eye height")
		eq(#T.survival.falls, 0)
		-- stand up and walk off: a 5-block fall, reported once
		T.G.release(Key.LeftShift)
		frames(T, 120)
		T.G.release(Key.W)
		near(feet(T).Y, FLOOR, 1e-6, "on the ground below")
		eq(#T.survival.falls, 1)
		assert(T.survival.falls[1] > 4 and T.survival.falls[1] <= 5, `a 5-block fall ({T.survival.falls[1]})`)
		eq(T.survival.sneak[#T.survival.sneak], false)
		cleanup()
	end)

	test("client: death, respawn, sleeping and waking keep the motor and the body in step", function()
		local T = boot()
		spawn(T, 24.5, FLOOR, 24.5)
		frames(T, 30)
		T.G.press(Key.W)
		frames(T, 30)
		-- death: the body stays where it died, nothing errors
		T.survival.dead = true
		T.humanoid.Health = 0
		local diedAt = feet(T)
		frames(T, 20)
		near(T.seen[3], diedAt.Z, 0.02, "the body stays where it died")
		near(T.seen[2], FLOOR, 1e-3, "and on the ground")
		for _, d in T.character:GetDescendants() do -- the server freezes the body
			if d:IsA("BasePart") then
				d.Anchored = true
			end
		end
		frames(T, 20)
		-- respawn somewhere else
		T.survival.dead = false
		spawn(T, -300.5, FLOOR, 40.5)
		frames(T, 60)
		near(feet(T).Y, FLOOR, 1e-6, "respawned on the ground")
		assert(feet(T).Z < 40.5 - 2, "W is still held: walking again")
		T.G.release(Key.W)
		frames(T, 30)

		-- sleeping: the server anchors the body on the bed and moves it there
		local bed = CFrame.new(-298.5 * BS, (FLOOR + 0.6) * BS, 44.5 * BS)
		T.root.Anchored = true
		T.root.CFrame = bed
		frames(T, 60)
		eq(T.root.CFrame.Position, bed.Position, "the motor leaves a held body alone")
		eq(T.MC.stats.held, true)
		-- waking: the server moves it next to the bed, lets go, and names the spot
		local spot = Vector3.new(-297.5, FLOOR, 44.5)
		T.root.CFrame = CFrame.new(spot.X * BS, spot.Y * BS + 3.05, spot.Z * BS)
		T.root.Anchored = false
		T.MC.teleport(spot + Vector3.new(0, 0.05 / BS, 0))
		frames(T, 60)
		near(feet(T).X, -297.5, 1e-4, "standing next to the bed")
		near(feet(T).Y, FLOOR, 1e-6, "on the floor")
		eq(T.MC.stats.held, false)
		-- ... and if the message is late, the body's own position is used meanwhile
		T.root.Anchored = true
		T.root.CFrame = bed
		frames(T, 10)
		T.root.CFrame = CFrame.new(spot.X * BS, spot.Y * BS + 3.05, spot.Z * BS)
		T.root.Anchored = false
		frames(T, 30)
		near(feet(T).X, -297.5, 1e-3, "took the position the server left the body at")
		near(feet(T).Y, FLOOR, 1e-6, "on the floor")
		cleanup()
	end)

	test("client: respawning never starts inside the floor (named spawn spot, lift-out)", function()
		local SLAB = BlockRegistry.id("stone_slab")
		local T = boot({ [`10,{FLOOR},10`] = SLAB })
		-- the server names the spot; the body itself already dropped 1.5 studs into the floor
		-- (the server simulated it before handing it over)
		local function spawnNamed(x: number, y: number, z: number, dropStuds: number, named: boolean)
			if T.character then
				T.character:Destroy()
			end
			local character = Fake.newCharacter("Tester", CFrame.new(x * BS, y * BS + 3.05 - dropStuds, z * BS))
			if named then
				character:SetAttribute("SpawnFeet", Vector3.new(x, y + 0.05 / BS, z))
			end
			character.Parent = T.G.workspace
			T.character = character
			T.root = character.HumanoidRootPart
			T.humanoid = character.Humanoid
			T.G.player.Character = character
			T.G.player.CharacterAdded:Fire(character)
		end
		spawnNamed(4.5, FLOOR, 4.5, 1.5, true)
		frames(T, 120)
		near(feet(T).Y, FLOOR, 1e-6, "stands on the floor at the named spot")
		near(feet(T).X, 4.5, 1e-6, "at the named x")
		-- no name (older server / fallback) and 0.6 blocks inside the floor: lifted onto it
		spawnNamed(6.5, FLOOR, 6.5, 0.6 * BS, false)
		frames(T, 120)
		near(feet(T).Y, FLOOR, 1e-6, "lifted out of the floor onto it")
		-- spawning on a bed-height block (the mattress is 9/16): stands on it
		spawnNamed(10.5, FLOOR + 0.5, 10.5, 0.3, true)
		frames(T, 120)
		near(feet(T).Y, FLOOR + 0.5, 1e-6, "on the slab")
		-- a chunk that arrives late: when it comes we're lifted out if inside it
		T.unloaded = function(x: number)
			return x >= 96
		end
		spawnNamed(120.5, FLOOR - 0.4, 0.5, 0, true)
		frames(T, 30)
		eq(T.MC.stats.waitingForChunk, true)
		T.unloaded = nil
		frames(T, 60)
		near(feet(T).Y, FLOOR, 1e-6, "lifted onto the floor once the chunk came")
		cleanup()
	end)

	test("client: in bed the view lies on the pillow looking to the foot; W does nothing; waking stands up", function()
		local T = boot()
		spawn(T, 0.5, FLOOR, 0.5)
		frames(T, 30)
		-- a bed facing east: foot at x 2, head at x 3 (the server's sleep message)
		local head = Vector3.new(3, FLOOR, 0)
		T.MC.sleep(head, "east")
		frames(T, 30)
		eq(T.MC.sleeping, true)
		local eye, look = T.MC.sleepView()
		near(eye.X / BS, 3.8, 1e-4, "eye toward the headboard")
		near(eye.Y / BS, FLOOR + 0.8875, 1e-4, "eye just above the pillow")
		near(eye.Z / BS, 0.5, 1e-4, "eye in the middle of the bed")
		near(look.X, -1, 1e-6, "looking toward the foot")
		near(look.Y, 0, 1e-6, "level")
		-- the body lies along the bed whether or not the server's anchored pose arrived
		near(T.root.Position.X / BS, 3, 1e-4, "body in the middle of the bed")
		near(T.root.Position.Y / BS, FLOOR + 0.6, 1e-4, "on the mattress")
		near(T.root.CFrame.LookVector.Y, 1, 1e-4, "lying down")
		T.G.press(Key.W)
		T.G.press(Key.Space)
		frames(T, 60)
		T.G.release(Key.W)
		T.G.release(Key.Space)
		near(T.root.Position.X / BS, 3, 1e-4, "W and Space don't move a sleeper")
		-- the server anchors it too: still fine
		T.root.Anchored = true
		frames(T, 30)
		near(T.root.Position.Y / BS, FLOOR + 0.6, 1e-4, "still lying")
		-- wake: the server stands us up beside the bed
		T.MC.sleep(nil)
		local spot = Vector3.new(3.5, FLOOR, 1.5)
		T.root.CFrame = CFrame.new(spot.X * BS, spot.Y * BS + 3.05, spot.Z * BS)
		T.root.Anchored = false
		T.MC.teleport(spot + Vector3.new(0, 0.05 / BS, 0))
		frames(T, 60)
		eq(T.MC.sleeping, false)
		eq((T.MC.sleepView()), nil)
		near(feet(T).X, 3.5, 1e-6, "standing beside the bed")
		near(feet(T).Y, FLOOR, 1e-6, "on the floor")
		T.G.press(Key.W)
		frames(T, 30)
		T.G.release(Key.W)
		assert(math.abs(feet(T).X - 3.5) + math.abs(feet(T).Z - 1.5) > 0.5, "walks again")
		-- dying in bed: a new character is never stuck asleep
		T.MC.sleep(head, "east")
		frames(T, 5)
		spawn(T, 0.5, FLOOR, 0.5) -- (no wake message: the new body must not start in the bed)
		eq(T.MC.sleeping, false)
		frames(T, 30)
		near(feet(T).Y, FLOOR, 1e-6, "respawned standing")
		cleanup()
	end)

	test("client: walking up slabs and stairs moves the camera smoothly up, never down (any frame rate)", function()
		local SLAB = BlockRegistry.id("stone_slab")
		local STAIRS = BlockRegistry.id("oak_stairs_east_bottom") -- steps up toward +x
		assert(STAIRS, "stairs id")
		for _, rate in { 60, 144, 30, 0 } do -- 0: uneven frames
			-- slab, block, slab on block, block + block ... a staircase of half steps along +x,
			-- then real stairs
			local cells = {}
			local function put(x: number, y: number, id: number)
				for z = -2, 2 do
					cells[`{x},{y},{z}`] = id
				end
			end
			put(3, FLOOR, SLAB)
			put(4, FLOOR, STONE)
			put(5, FLOOR, STONE); put(5, FLOOR + 1, SLAB)
			put(6, FLOOR, STONE); put(6, FLOOR + 1, STONE)
			put(7, FLOOR, STONE); put(7, FLOOR + 1, STAIRS)
			put(8, FLOOR, STONE); put(8, FLOOR + 1, STONE); put(8, FLOOR + 2, STAIRS)
			for x = 9, 14 do
				put(x, FLOOR, STONE); put(x, FLOOR + 1, STONE); put(x, FLOOR + 2, STONE)
			end
			local T = boot(cells)
			spawn(T, 0.5, FLOOR, 0.5)
			T.MC.lookYaw = -math.pi / 2 -- look +x
			frames(T, 30)
			T.G.press(Key.W)
			local last = -math.huge
			local n = 0
			for i = 1, 600 do
				local dt = if rate == 0 then (if i % 3 == 0 then 1 / 25 else 1 / 90) else 1 / rate
				T.G.frame(dt)
				local eye = T.seen[2] + (T.MC.eyeHeight + T.MC.stepOffset) / BS
				if last > -math.huge then
					assert(eye >= last - 1e-9, `camera dipped at {rate} fps: {last} -> {eye} (x {feet(T).X})`)
					assert(eye - last <= 0.5 + 1e-6, `camera jumped {eye - last} blocks in one frame at {rate} fps`)
				end
				last = eye
				n += 1
				if feet(T).X > 11 then
					break
				end
			end
			T.G.release(Key.W)
			assert(feet(T).X > 11, `walked up to the top at {rate} fps (x {feet(T).X})`)
			near(feet(T).Y, FLOOR + 3, 1e-6, `on top at {rate} fps`)
			cleanup()
		end
	end)

	test("client: waits while the chunk isn't loaded; knockback; touch input; step-up; animations", function()
		local cells = { [`3,{FLOOR},0`] = BlockRegistry.id("stone_slab") }
		local T = boot(cells)
		-- respawned somewhere the chunks haven't arrived yet: hold still, then fall into place
		T.unloaded = function(x: number)
			return x >= 96
		end
		spawn(T, 150.5, FLOOR + 2, 0.5)
		frames(T, 120)
		eq(T.MC.stats.waitingForChunk, true)
		near(T.seen[2], FLOOR + 2 + 0.5 / BS, 1e-3, "waits in the air")
		T.unloaded = nil
		frames(T, 60)
		eq(T.MC.stats.waitingForChunk, false)
		near(feet(T).Y, FLOOR, 1e-6, "landed once the chunk came")

		-- knockback from a hit: Java's 0.4, away from the attacker
		spawn(T, 0.5, FLOOR, 0.5)
		frames(T, 30)
		T.remotes.Knockback.OnClientEvent:Fire({ dir = Vector3.new(0, 0, 1), strength = 0.4 })
		local top = 0
		for _ = 1, 30 do
			frames(T, 1)
			top = math.max(top, T.seen[2] - FLOOR)
		end
		assert(feet(T).Z > 0.5 + 0.5, `knocked back (z {feet(T).Z})`)
		assert(top > 0.5, `and up ({top})`)

		-- touch: the thumbstick arrives in MoveDirection, the jump button in Jump
		spawn(T, 0.5, FLOOR, 0.5)
		frames(T, 30)
		T.G.game:GetService("UserInputService").TouchEnabled = true
		T.humanoid:Move(Vector3.new(1, 0, 0))
		frames(T, 30)
		-- walks +X, up onto the slab at x = 3 without jumping; the camera never dips
		for _ = 1, 60 do
			frames(T, 1)
			eq(T.MC.stepOffset, 0, "no extra camera offset on a step")
			if feet(T).X > 3.4 then
				break -- on the slab: stop here
			end
		end
		near(feet(T).Y, FLOOR + 0.5, 1e-6, "stepped onto the slab")
		T.humanoid:Move(Vector3.zero)
		frames(T, 30)
		T.humanoid.Jump = true
		top = 0
		for _ = 1, 20 do
			frames(T, 1)
			top = math.max(top, T.seen[2] - (FLOOR + 0.5))
		end
		T.humanoid.Jump = false
		assert(top > 1.2, "the touch jump button jumps")

		-- animations: ours, picked by what the body is doing
		local animator = T.humanoid.Animator
		local function playing(): string
			local names = {}
			for _, t in animator:GetPlayingAnimationTracks() do
				table.insert(names, t.Name)
			end
			table.sort(names)
			return table.concat(names, ",")
		end
		frames(T, 60)
		eq(playing(), "Animation1") -- idle
		T.humanoid:Move(Vector3.new(0, 0, 1))
		frames(T, 30)
		eq(playing(), "WalkAnim")
		eq(T.character.Animate.Enabled, false)
		cleanup()
	end)

	-- leave the loader as the other tests expect it
	for _, k in { "game", "workspace", "Instance", "Enum", "CFrame", "Vector2", "Color3", "UDim2", "UDim", "task", "os", "time", "tick", "warn" } do
		Loader.globals[k] = nil
	end
	Loader.forget("src/client/")
end
