--!strict
-- Plays ROCRAFT's sounds and music (every id lives in Shared/Audio/SoundConfig).
--
--   footsteps   Java timing: one step every 1/0.6 blocks walked (Entity.moveDist), only on the
--               ground and moving, never while sneaking (Java's "discrete" movement is silent),
--               swimming, spectating or in bed; the sound is the block underfoot's group
--               (SoundConfig.footsteps: soft / wood / stone). Roblox's own character sounds are
--               switched off (client/RbxCharacterSounds), so only ours plays: no doubled "echo".
--   blocks      dig hits while mining, break and place sounds by material
--   player      eating (every 4 ticks while eating), hurt, landing
--   containers  chest open / close when the window opens / closes
--   liquids     occasional lava pops near lava
--   mobs        hurt / death / teleport / angry from MobEvents, the Sneaker's fuse when it starts,
--               and now-and-then idle sounds from nearby mobs (MobClient.events)
--   music       calm tracks with long silences (SoundConfig.music); nothing plays until ids exist
-- Placeholders (empty ids) are skipped silently.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local SoundService = game:GetService("SoundService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared.Config)
local Remotes = require(Shared.Net.Remotes)
local SoundConfig = require(Shared.Audio.SoundConfig)
local BlockRegistry = require(Shared.Blocks.BlockRegistry)
local MobDefs = require(Shared.Mobs.MobDefs)

local BS = Config.BLOCK_SIZE
local AudioClient = {}

-- Volume sliders (Settings): one SoundGroup per category, its volume = category x master.
local SettingsSchema = require(Shared.Gameplay.SettingsSchema)
local CATEGORIES = { "music", "blocks", "hostile", "friendly", "players", "ambient" }
local groups: { [string]: SoundGroup } = {}
local volume: { [string]: number } = { master = 1 }
for _, c in CATEGORIES do
	local g = Instance.new("SoundGroup")
	g.Name = "Rocraft_" .. c
	g.Parent = SoundService
	groups[c] = g
	volume[c] = 1
end
local function applyVolumes()
	for _, c in CATEGORIES do
		groups[c].Volume = volume[c] * volume.master
	end
end

local holder: Part
local function group(id: number?): string
	local def = id and BlockRegistry.byId[id]
	return if def then def.sound else "stone"
end

-- Play a configured sound; `pos` (studs) makes it 3D. Returns false if it's a placeholder.
function AudioClient.play(name: string, pos: Vector3?, volumeScale: number?): boolean
	local e = SoundConfig.get(name)
	if not e or e.id == "" then
		return false
	end
	local s = Instance.new("Sound")
	s.SoundId = e.id
	s.Volume = e.volume * (volumeScale or 1)
	s.SoundGroup = groups[SettingsSchema.soundCategory(name)]
	local p = e.pitch
	if p then
		s.PlaybackSpeed = p[1] + math.random() * (p[2] - p[1])
	end
	local region = e.region
	if region then
		-- only this part of the file (a single footstep out of Roblox's running loop)
		local ok = pcall(function()
			(s :: any).PlaybackRegionsEnabled = true;
			(s :: any).PlaybackRegion = NumberRange.new(region[1], region[2])
		end)
		if not ok then
			task.delay((region[2] - region[1]) / s.PlaybackSpeed, function()
				s:Stop()
			end)
		end
	end
	local eq = e.eq
	if eq then
		local fx = Instance.new("EqualizerSoundEffect")
		fx.LowGain, fx.MidGain, fx.HighGain = eq[1], eq[2], eq[3]
		fx.Parent = s
	end
	if pos then
		local a = Instance.new("Attachment")
		a.WorldPosition = pos
		a.Parent = holder
		s.RollOffMinDistance = 6
		s.RollOffMaxDistance = 16 * BS
		s.Parent = a
		s.Ended:Connect(function()
			a:Destroy()
		end)
		task.delay(10, function()
			a:Destroy()
		end)
	else
		s.Parent = SoundService
		s.Ended:Connect(function()
			s:Destroy()
		end)
		task.delay(10, function()
			s:Destroy()
		end)
	end
	s:Play()
	return true
end

-- Material sound with a fallback (e.g. footsteps fall back to Roblox's built-in step).
local function playMaterial(kind: string, id: number?, pos: Vector3?, fallback: string?)
	if not AudioClient.play(`{kind}.{group(id)}`, pos) and fallback then
		AudioClient.play(fallback, pos)
	end
end

-- Footstep group of the block the feet stand on (Java getOnPos: 0.2 below the feet), or nil
-- when there's nothing to step on.
local stepWorld: any = nil
local function stepGroupAt(feet: Vector3): string?
	local id = stepWorld and stepWorld.getBlock(math.floor(feet.X / BS), math.floor((feet.Y - 0.2 * BS) / BS), math.floor(feet.Z / BS))
	local def = id and BlockRegistry.byId[id]
	if not def or id == 0 then
		return nil
	end
	local g = SoundConfig.stepGroup(def.family, def.sound)
	return if g == "none" then nil else g
end
AudioClient.stepGroupAt = stepGroupAt

-- Java Entity.move: moveDist grows by 0.6 x the horizontal distance; a step plays each time it
-- passes the next whole number. Distance only counts while footsteps can happen at all.
local stepMover: any = nil
local moveDist, nextStep = 0, 1
AudioClient.steps = 0 -- (tests / F3)
function AudioClient.stepTick(dt: number, velBlocks: Vector3, feet: Vector3)
	local M = stepMover
	if not M then
		return
	end
	local silent = M.sneaking or M.inLiquid or M.spectating or M.sleeping
		or Players.LocalPlayer:GetAttribute("Spectator") == true
	if silent then
		return
	end
	local horiz = Vector3.new(velBlocks.X, 0, velBlocks.Z).Magnitude * dt
	if horiz < 1e-4 then
		return -- standing still
	end
	moveDist += horiz * 0.6
	if moveDist > nextStep and M.onGround then
		local g = stepGroupAt(feet)
		if g then
			nextStep = math.floor(moveDist) + 1
			AudioClient.steps += 1
			AudioClient.play(`step.{g}`, feet)
		end
	end
end

-- Where footsteps read the world and the player's movement (init passes ClientWorld and
-- MovementController; tests pass stand-ins).
function AudioClient.setStepSources(world: any, mover: any)
	stepWorld = world
	stepMover = mover
end

local function blockCenter(x: number, y: number, z: number): Vector3
	return (Vector3.new(x, y, z) + Vector3.new(0.5, 0.5, 0.5)) * BS
end

function AudioClient.init(deps: { [string]: any })
	require(script.Parent.Parent.Player.Settings).onChange(function(key: string, value: any)
		if volume[key] ~= nil then
			volume[key] = value / 100
			applyVolumes()
		end
	end)
	holder = Instance.new("Part")
	holder.Name = "SoundHolder"
	holder.Anchored = true
	holder.CanCollide = false
	holder.CanQuery = false
	holder.CanTouch = false
	holder.Transparency = 1
	holder.Size = Vector3.one
	holder.CFrame = CFrame.new()
	holder.Parent = workspace

	local BlockInteraction = deps.BlockInteraction
	local ClientWorld = deps.ClientWorld
	local MovementController = deps.MovementController
	local InventoryClient = deps.InventoryClient
	local MobClient = deps.MobClient
	AudioClient.setStepSources(ClientWorld, MovementController)
	-- no reverb on anything (Java has none); and in case Roblox's default character sounds still
	-- got in (an old place file), mute the sounds it puts in the body
	SoundService.AmbientReverb = Enum.ReverbType.NoReverb
	local DEFAULT_SOUNDS = { Running = true, Jumping = true, Landing = true, FreeFalling = true, Climbing = true,
		GettingUp = true, Splash = true, Swimming = true, Died = true }
	local function muteDefaults(character: Model)
		local root = character:WaitForChild("HumanoidRootPart", 10)
		if not root then
			return
		end
		local function check(d: Instance)
			if d:IsA("Sound") and DEFAULT_SOUNDS[d.Name] then
				d.Volume = 0
			end
		end
		for _, d in root:GetChildren() do
			check(d)
		end
		root.ChildAdded:Connect(check)
	end
	local function watchPlayer(p: Player)
		if p.Character then
			task.spawn(muteDefaults, p.Character)
		end
		p.CharacterAdded:Connect(muteDefaults)
	end
	for _, p in Players:GetPlayers() do
		watchPlayer(p)
	end
	Players.PlayerAdded:Connect(watchPlayer)

	BlockInteraction.broken.Event:Connect(function(x, y, z, id)
		playMaterial("break", id, blockCenter(x, y, z))
	end)
	BlockInteraction.placed.Event:Connect(function(x, y, z, id)
		playMaterial("place", id, blockCenter(x, y, z))
	end)
	BlockInteraction.digging.Event:Connect(function(x, y, z, id)
		playMaterial("dig", id, blockCenter(x, y, z))
	end)
	BlockInteraction.used.Event:Connect(function(held: string, target: number)
		if held == "bucket_fill" then
			local def = BlockRegistry.byId[target]
			AudioClient.play(if def and def.fluid == "lava" then "bucket.fill_lava" else "bucket.fill")
		elseif held == "water_bucket" then
			AudioClient.play("bucket.empty")
		elseif held == "lava_bucket" then
			AudioClient.play("bucket.empty_lava")
		elseif held == "flint_and_steel" then
			AudioClient.play("fire.ignite")
		elseif held == "bow_shoot" then
			AudioClient.play("bow.shoot")
		elseif held == "crossbow_load" then
			AudioClient.play("crossbow.load")
		elseif held == "crossbow_shoot" then
			AudioClient.play("crossbow.shoot")
		elseif held == "armor_equip" then
			AudioClient.play("armor.equip")
		elseif held == "door_open" then
			AudioClient.play("door.open")
		elseif held == "door_close" then
			AudioClient.play("door.close")
		end
	end)
	if deps.EntityClient then
		deps.EntityClient.events.Event:Connect(function(kind: string, entityKind: string, pos: Vector3)
			if kind == "spawn" and entityKind == "tnt" then
				AudioClient.play("tnt.primed", pos)
			elseif kind == "remove" and entityKind == "falling" then
				AudioClient.play("sand.land", pos)
			elseif kind == "fizz" then
				AudioClient.play("fizz", pos)
			end
		end)
	end

	-- footsteps, landing, eating
	local wasGrounded = true
	local lastVy = 0
	local eatAcc = 0
	RunService.Heartbeat:Connect(function(dt)
		local c = Players.LocalPlayer.Character
		local h = c and c:FindFirstChildOfClass("Humanoid")
		local root = c and c:FindFirstChild("HumanoidRootPart") :: BasePart?
		if not h or not root or h.Health <= 0 then
			return
		end
		local grounded = MovementController.onGround
		local v = MovementController.velocity * 20 * BS -- studs/s
		local feet = root.Position - Vector3.new(0, 3, 0)
		AudioClient.stepTick(dt, v / BS, feet)
		-- landing: judged by the speed just before touching down
		if grounded and not wasGrounded and lastVy < -40 then
			AudioClient.play(if lastVy < -70 then "fall.big" else "fall.small", feet)
		end
		wasGrounded = grounded
		lastVy = v.Y
		if MovementController.usingItem then
			eatAcc += dt
			if eatAcc >= 0.2 then
				eatAcc = 0
				AudioClient.play("eat", root.Position)
			end
		else
			eatAcc = 0
		end
	end)

	-- hurt / death sounds from the server's survival sync
	Remotes.get("SurvivalSync").OnClientEvent:Connect(function(p: any)
		if typeof(p) == "table" and p.event == "hurt" then
			AudioClient.play("hurt")
		elseif typeof(p) == "table" and p.event == "blocked" then
			AudioClient.play("shield.block")
		end
	end)

	-- experience: orb pickups and every 5th level
	Remotes.get("Experience").OnClientEvent:Connect(function(m: any)
		if typeof(m) ~= "table" then
			return
		elseif m.type == "pickup" then
			AudioClient.play("xp.pickup")
		elseif m.type == "enchanted" then
			AudioClient.play("enchant")
		elseif m.type == "levelup" then
			AudioClient.play("xp.levelup", nil, math.clamp(tonumber(m.volume) or 0.75, 0, 1) / 0.75)
		end
	end)

	-- containers
	local lastKind = "inventory"
	InventoryClient.Changed:Connect(function()
		local kind = InventoryClient.window.kind
		if kind ~= lastKind then
			if kind == "chest" then
				AudioClient.play("chest.open")
			elseif lastKind == "chest" then
				AudioClient.play("chest.close")
			end
			lastKind = kind
		end
	end)

	-- mobs
	Remotes.get("MobEvent").OnClientEvent:Connect(function(e: any)
		if typeof(e) ~= "table" then
			return
		end
		local key = MobClient.keyOf(e.id)
		local pos = MobClient.positionOf(e.id)
		if e.type == "hurt" and key then
			AudioClient.play(`mob.{key}.hurt`, pos)
		elseif e.type == "died" and key then
			AudioClient.play(`mob.{key}.death`, pos)
		elseif e.type == "sweep" then
			AudioClient.play("attack.sweep", if typeof(e.pos) == "Vector3" then e.pos else pos)
		elseif e.type == "teleport" then
			AudioClient.play("mob.voidling.teleport", if typeof(e.to) == "Vector3" then e.to else pos)
		elseif e.type == "angry" then
			AudioClient.play("mob.voidling.angry", pos)
		elseif e.type == "explode" then
			AudioClient.play("explosion", if typeof(e.pos) == "Vector3" then e.pos else pos)
		elseif e.type == "crit" then
			AudioClient.play("attack.crit", pos)
		end
	end)
	MobClient.events.Event:Connect(function(kind: string, key: string, pos: Vector3)
		if kind == "fuse" then
			AudioClient.play(`mob.{key}.fuse`, pos)
		elseif kind == "idle" then
			AudioClient.play(`mob.{key}.idle`, pos)
		end
	end)

	-- lava pops: now and then if lava is near the camera
	task.spawn(function()
		local LAVA = BlockRegistry.id("lava")
		while true do
			task.wait(1.5 + math.random() * 2)
			local cam = workspace.CurrentCamera
			if cam then
				local p = cam.CFrame.Position / BS
				for _ = 1, 40 do
					local x = math.floor(p.X) + math.random(-6, 6)
					local y = math.floor(p.Y) + math.random(-6, 6)
					local z = math.floor(p.Z) + math.random(-6, 6)
					if ClientWorld.getBlock(x, y, z) == LAVA and ClientWorld.getBlock(x, y + 1, z) == 0 then
						AudioClient.play("lava.pop", blockCenter(x, y, z))
						break
					end
				end
			end
		end
	end)

	-- music: long silences, then a random configured track
	task.spawn(function()
		local m = SoundConfig.music
		local available = {}
		for _, t in m.tracks do
			if t.id ~= "" then
				table.insert(available, t)
			end
		end
		if #available == 0 then
			return
		end
		task.wait(m.firstDelay[1] + math.random() * (m.firstDelay[2] - m.firstDelay[1]))
		while true do
			local track = available[math.random(1, #available)]
			local s = Instance.new("Sound")
			s.SoundId = track.id
			s.Volume = m.volume
			s.SoundGroup = groups.music
			s.Parent = SoundService
			s:Play()
			s.Ended:Wait()
			s:Destroy()
			task.wait(m.gap[1] + math.random() * (m.gap[2] - m.gap[1]))
		end
	end)
	_ = MobDefs
end

return AudioClient
