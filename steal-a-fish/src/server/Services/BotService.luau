--!strict
--[[
	BotService
	==========
	The sharks. Each zone gets the number of sharks and the chase speed from
	its row in Config.Sharks (row 1 = zone 1, and so on).

	What a shark does (checked every Config.Bots.UpdateInterval seconds):
	  - PATROL: swim slowly back and forth along a straight line across the
	    width of its zone, at the zone's far (deep) end (Bots.PatrolLineInset).
	    Away from that line (after a chase)? It swims back at full speed first.
	  - CHASE: ONLY when an egg is stolen from ITS zone (EggService tells us
	    which zone). Sharks never react just because someone walks by.
	    It chases that thief across zone borders, at full speed:
	      * It swims STRAIGHT at them (the danger zone is open), aiming a bit
	        ahead of where they're running, at full speed from the first moment.
	      * Give up when the thief reaches the safe zone, drops/loses the egg,
	        dies or leaves. Then swim back home.
	  - CATCH: getting within CatchDistance = caught. The egg drops (or is lost,
	    see Config.Eggs.OnCaught), the player is knocked back (or killed, if
	    Config.Bots.KillOnCatch) and can't be caught again for CatchCooldown
	    seconds. The shark rests for PostCatchPause seconds.

	Leash: sharks may go anywhere in the danger zone while chasing, but stop
	Config.Bots.SafeLineMargin studs before the safe zone. That (plus the
	invisible BotBarrier from WorldService) keeps them away from the open
	area and the plots.

	Model: built by SharkModel (each zone's shark looks different, deeper =
	bigger and scarier; it glows red while chasing), or your own model named
	"Shark<zone>" / "Shark" in ReplicatedStorage.Assets. Sharks use a
	Humanoid without legs, floating at Config.Bots.HoverHeight.

	The CHASING shark is always the one from the zone the egg was ORIGINALLY
	stolen from (EggService remembers that zone for the egg's whole life,
	also when it's dropped and picked up again).

	Public interface:
		BotService.PlayerCaught:Connect(function(player) end)
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Config = require(ReplicatedStorage.Shared.Config)
local Layout = require(ReplicatedStorage.Shared.Layout)
local Net = require(ReplicatedStorage.Shared.Net)
local Signal = require(ReplicatedStorage.Shared.Signal)
local Notify = require(script.Parent.Parent.Util.Notify)
local DebugCommands = require(script.Parent.Parent.Util.DebugCommands)
local Build = require(script.Parent.Parent.Util.Build)
local SharkModel = require(ReplicatedStorage.Shared.Models.SharkModel)
local EggService = require(script.Parent.EggService)
local WorldService = require(script.Parent.WorldService)

type BotState = "Patrol" | "Pause" | "Chase"

type Bot = {
	Model: Model,
	Root: BasePart,
	Humanoid: Humanoid,
	Indicator: BillboardGui, -- the "!" shown while chasing
	Zone: number,
	Speed: number,
	Scale: number, -- the shark's size (Config.Sharks[...].Scale); bigger sharks catch from farther
	-- Leash area (inclusive), in world X and Z.
	MinX: number,
	MaxX: number,
	MinZ: number,
	MaxZ: number,

	State: BotState,
	Target: Player?,
	PatrolPoint: Vector3?,
	PatrolSide: number, -- which end of the patrol line it swims to next (-1 or 1)
	PauseUntil: number,
	-- Studio chase log (Config.Bots.DebugChaseLog)
	ChaseStartedAt: number,
	ReactionLogged: boolean,
	NextLogAt: number,
	TopSpeedSeen: number,
	SpeedSum: number, -- for the average measured chase speed (log)
	SpeedSamples: number,
	AimVelocity: Vector3, -- the thief's velocity, smoothed (so the aim doesn't wobble)
}

local BotService = {}
BotService.Name = "BotService"

-- Fired with (player) whenever a shark catches someone.
BotService.PlayerCaught = Signal.new()

local SHARK_SIZE = Vector3.new(3, 3, 9) -- invisible body box (nose points to -Z)
local PATROL_REACHED = 4
local LINE_TOLERANCE = 6 -- studs from the patrol line that still count as "on the line"

local rng = Random.new()
local bots: { Bot } = {}
local botsFolder: Folder
local lastCaught: { [Player]: number } = {}
local chaseLog = Config.Bots.DebugChaseLog and RunService:IsStudio()

---------------------------------------------------------------------------
-- Helpers
---------------------------------------------------------------------------

local function getRoot(player: Player): BasePart?
	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	if root and root:IsA("BasePart") then
		return root
	end
	return nil
end

local function isAlive(player: Player): boolean
	local character = player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	return humanoid ~= nil and humanoid.Health > 0
end

local function flatDistance(a: Vector3, b: Vector3): number
	return Vector3.new(a.X - b.X, 0, a.Z - b.Z).Magnitude
end

-- The closest point inside the shark's leash area, at swimming height.
local function clampToLeash(bot: Bot, position: Vector3): Vector3
	return Vector3.new(
		math.clamp(position.X, bot.MinX, bot.MaxX),
		Layout.GroundTop,
		math.clamp(position.Z, bot.MinZ, bot.MaxZ)
	)
end

-- One end of a zone's patrol line (side -1 = left, 1 = right).
local function linePoint(zoneIndex: number, side: number): Vector3
	local halfLine = Config.World.DangerZoneWidth / 2 - Config.Bots.PatrolEdgeMargin
	return Vector3.new(side * halfLine, Layout.GroundTop, Layout.patrolLineZ(zoneIndex))
end

-- A random spot on a zone's patrol line (where sharks start).
local function randomPointOnLine(zoneIndex: number): Vector3
	local halfLine = Config.World.DangerZoneWidth / 2 - Config.Bots.PatrolEdgeMargin
	return Vector3.new(rng:NextNumber(-halfLine, halfLine), Layout.GroundTop, Layout.patrolLineZ(zoneIndex))
end

local function notify(player: Player, message: string, kind: string?)
	Notify.send(player, message, kind)
end

---------------------------------------------------------------------------
-- Building a shark
---------------------------------------------------------------------------

local function createBot(zoneIndex: number): Bot
	local zone = Config.Zones[zoneIndex]
	local sharkSpeed = Config.Sharks[zoneIndex].Speed
	local spawnPoint = randomPointOnLine(zoneIndex)
	local hover = Config.Bots.HoverHeight

	local model = Instance.new("Model")
	model.Name = `Shark_{zone.Name}`

	local root = Instance.new("Part")
	root.Name = "HumanoidRootPart"
	root.Size = SHARK_SIZE
	root.Transparency = 1
	root.CanCollide = true -- bumps into walls; the Bots group ignores players
	root.CanQuery = false
	root.CanTouch = false
	root.CFrame = CFrame.new(spawnPoint + Vector3.new(0, hover + SHARK_SIZE.Y / 2, 0))
	root.Parent = model
	model.PrimaryPart = root

	-- The looks (per zone, see Config.Sharks) come from SharkModel.
	SharkModel.build(model, root, zoneIndex)

	-- A Humanoid without legs ("R15" rig type) floats at HipHeight above the floor.
	local humanoid = Instance.new("Humanoid")
	humanoid.RigType = Enum.HumanoidRigType.R15
	humanoid.HipHeight = hover
	humanoid.WalkSpeed = sharkSpeed * Config.Bots.PatrolSpeedMultiplier
	humanoid.AutoJumpEnabled = false
	humanoid.UseJumpPower = true
	humanoid.JumpPower = 0
	humanoid.DisplayDistanceType = Enum.HumanoidDisplayDistanceType.None
	humanoid.BreakJointsOnDeath = false
	humanoid.Parent = model

	-- "!" above the shark while it chases someone.
	local label = Build.billboard(root, "❗", 3 + 2.5 * Config.Sharks[zoneIndex].Scale, 120)
	label.TextColor3 = Color3.fromRGB(255, 70, 70)
	local indicator = label.Parent :: BillboardGui
	indicator.Enabled = false

	for _, item in model:GetDescendants() do
		if item:IsA("BasePart") then
			item.CollisionGroup = WorldService.CollisionGroups.Bots
		end
	end
	model.Parent = botsFolder
	-- The server controls sharks' physics (so players can't mess with them).
	root:SetNetworkOwner(nil)

	-- Leash area: the whole danger zone, but never the safe zone.
	local halfWidth = Config.World.DangerZoneWidth / 2 - 4
	local edge = 3

	return {
		Model = model,
		Root = root,
		Humanoid = humanoid,
		Indicator = indicator,
		Zone = zoneIndex,
		Speed = sharkSpeed,
		Scale = Config.Sharks[zoneIndex].Scale,
		MinX = -halfWidth,
		MaxX = halfWidth,
		MinZ = Layout.DangerZoneBack + edge,
		MaxZ = Layout.DangerZoneFront - Config.Bots.SafeLineMargin,
		State = "Patrol",
		Target = nil,
		PatrolPoint = nil,
		PatrolSide = if rng:NextNumber() < 0.5 then -1 else 1,
		PauseUntil = 0,
		ChaseStartedAt = 0,
		ReactionLogged = false,
		NextLogAt = 0,
		TopSpeedSeen = 0,
		SpeedSum = 0,
		SpeedSamples = 0,
		AimVelocity = Vector3.zero,
	}
end

---------------------------------------------------------------------------
-- Brain
---------------------------------------------------------------------------

-- Should a shark keep chasing this player? Only while they are alive, still
-- carry an egg and are still in the danger zone.
local function isValidTarget(player: Player): boolean
	if player.Parent == nil or not EggService.IsCarrying(player) or not isAlive(player) then
		return false
	end
	local root = getRoot(player)
	return root ~= nil and root.Position.Z < Layout.DangerZoneFront
end

-- Just caught? Then the player can't be caught again for a moment.
local function onCatchCooldown(player: Player, now: number): boolean
	local caughtAt = lastCaught[player]
	return caughtAt ~= nil and now - caughtAt < Config.Bots.CatchCooldown
end

local function startChase(bot: Bot, player: Player)
	bot.State = "Chase"
	bot.Target = player
	bot.ChaseStartedAt = os.clock()
	bot.ReactionLogged = false
	bot.NextLogAt = 0
	bot.TopSpeedSeen = 0
	bot.SpeedSum = 0
	bot.SpeedSamples = 0
	bot.AimVelocity = Vector3.zero
	bot.Humanoid.WalkSpeed = bot.Speed
	bot.Indicator.Enabled = true
	SharkModel.setChasing(bot.Model, true)
	-- No reaction delay: start swimming at the thief right now (not at the
	-- next brain update).
	local targetRoot = getRoot(player)
	if targetRoot then
		bot.Humanoid:MoveTo(clampToLeash(bot, targetRoot.Position))
	end
	if chaseLog then
		print(string.format("[Race] shark %d starts chasing %s (set speed %.1f)", bot.Zone, player.Name, bot.Speed))
	end
end

local function stopChase(bot: Bot)
	bot.State = "Patrol"
	bot.Target = nil
	bot.PatrolPoint = nil
	bot.Humanoid.WalkSpeed = bot.Speed * Config.Bots.PatrolSpeedMultiplier
	bot.Indicator.Enabled = false
	SharkModel.setChasing(bot.Model, false)
end

local function catch(bot: Bot, player: Player, now: number)
	lastCaught[player] = now
	local outcome = EggService.DropEgg(player, "caught")
	if outcome == "Dropped" then
		notify(player, "🦈 Caught! Your egg dropped. Grab it again before it's gone!", "danger")
	else
		notify(player, "🦈 Caught by a shark! Your egg is gone.", "danger")
	end

	local character = player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	local targetRoot = getRoot(player)
	if Config.Bots.KillOnCatch then
		if humanoid then
			humanoid.Health = 0
		end
	elseif targetRoot then
		-- Push the player away from the shark. Players control their own
		-- character's physics, so the push is applied on their computer.
		local away = targetRoot.Position - bot.Root.Position
		away = Vector3.new(away.X, 0, away.Z)
		if away.Magnitude < 0.1 then
			away = -bot.Root.CFrame.LookVector
		end
		local velocity = away.Unit * Config.Bots.KnockbackForce + Vector3.new(0, Config.Bots.KnockbackUpForce, 0)
		Net.event(Net.Names.Knockback):FireClient(player, velocity)
	end

	stopChase(bot)
	bot.State = "Pause"
	bot.PauseUntil = now + Config.Bots.PostCatchPause
	bot.Humanoid:MoveTo(bot.Root.Position)

	if Config.Debug then
		print(`[{Config.GameName}] {bot.Model.Name} caught {player.Name}`)
	end
	BotService.PlayerCaught:Fire(player)
end

-- How close counts as "caught" for this shark (bigger sharks reach farther).
local function catchDistance(bot: Bot): number
	return Config.Bots.CatchDistance * bot.Scale
end

local function flatSpeed(part: BasePart): number
	local velocity = part.AssemblyLinearVelocity
	return Vector3.new(velocity.X, 0, velocity.Z).Magnitude
end

-- Studio only: print what really happens in a chase, to compare with the
-- balance math (Config.Bots.DebugChaseLog).
local function logChase(bot: Bot, player: Player, targetRoot: BasePart, distance: number, now: number)
	local sharkSpeed = flatSpeed(bot.Root)
	bot.TopSpeedSeen = math.max(bot.TopSpeedSeen, sharkSpeed)
	if bot.ReactionLogged then
		bot.SpeedSum += sharkSpeed
		bot.SpeedSamples += 1
	end
	if not bot.ReactionLogged and sharkSpeed >= bot.Speed * 0.9 then
		bot.ReactionLogged = true
		print(string.format("[Race] shark %d reached 90%% of its speed %.2fs after the steal", bot.Zone, now - bot.ChaseStartedAt))
	end
	if now < bot.NextLogAt then
		return
	end
	bot.NextLogAt = now + 0.5
	local character = player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	local near = Layout.zoneZRange(bot.Zone)
	print(string.format(
		"[Race] t=%.1fs  shark %d: set %.1f, real %.1f (top %.1f)  |  player: WalkSpeed %.1f, real %.1f  |  gap %.1f (caught at %.1f)  |  player %.0f studs from zone start",
		now - bot.ChaseStartedAt,
		bot.Zone,
		bot.Humanoid.WalkSpeed,
		sharkSpeed,
		bot.TopSpeedSeen,
		if humanoid then humanoid.WalkSpeed else 0,
		flatSpeed(targetRoot),
		distance,
		catchDistance(bot),
		targetRoot.Position.Z - near
	))
end

-- Chase: always swim STRAIGHT at the thief (the danger zone is open, so no
-- pathfinding), aiming a little ahead of where they're running so the shark
-- cuts them off instead of trailing behind. Runs EVERY FRAME while chasing,
-- with the same Humanoid:MoveTo movement as patrolling/returning, so the
-- shark moves smoothly at its full configured speed.
-- (The old version followed a pathfinding route that was rebuilt only every
-- 0.5 s toward where the thief HAD been, stepping from waypoint to waypoint:
-- that was the stutter and the slow chase.)
local function chaseStep(bot: Bot, now: number, dt: number)
	local player = bot.Target
	local targetRoot = if player then getRoot(player) else nil
	if not (player and targetRoot) then
		stopChase(bot)
		return
	end

	local distance = (targetRoot.Position - bot.Root.Position).Magnitude
	if chaseLog then
		logChase(bot, player, targetRoot, distance, now)
	end
	if distance <= catchDistance(bot) and not onCatchCooldown(player, now) then
		if chaseLog then
			local zoneHere = Layout.zoneIndexAt(targetRoot.Position)
			print(string.format("[Race] CAUGHT after %.1fs in zone %s (egg's zone %d)", now - bot.ChaseStartedAt, tostring(zoneHere), bot.Zone))
			if bot.SpeedSamples > 0 then
				print(string.format("[Race] shark %d average measured chase speed %.1f vs configured %.1f", bot.Zone, bot.SpeedSum / bot.SpeedSamples, bot.Speed))
			end
		end
		catch(bot, player, now)
		return
	end

	-- Lead the target: where will they be when we get there? (Their velocity
	-- is smoothed a little so the aim doesn't jitter.)
	local velocity = targetRoot.AssemblyLinearVelocity
	local flatVelocity = Vector3.new(velocity.X, 0, velocity.Z)
	bot.AimVelocity = bot.AimVelocity:Lerp(flatVelocity, math.clamp(dt * 8, 0, 1))
	local leadTime = math.clamp(distance / math.max(bot.Speed, 1), 0, Config.Bots.MaxLeadTime)
	local aim = targetRoot.Position + bot.AimVelocity * leadTime
	bot.Humanoid:MoveTo(clampToLeash(bot, aim))
end

local function patrolStep(bot: Bot, now: number)
	local point = bot.PatrolPoint
	if point and flatDistance(bot.Root.Position, point) <= PATROL_REACHED then
		-- Reached one end: rest a moment, then swim to the other end.
		bot.PatrolPoint = nil
		bot.PatrolSide = -bot.PatrolSide
		bot.State = "Pause"
		bot.PauseUntil = now + Config.Bots.PatrolPauseTime
		return
	end
	if not point then
		point = linePoint(bot.Zone, bot.PatrolSide)
		bot.PatrolPoint = point
	end
	local onLine = math.abs(bot.Root.Position.Z - Layout.patrolLineZ(bot.Zone)) <= LINE_TOLERANCE
	bot.Humanoid.WalkSpeed = if onLine then bot.Speed * Config.Bots.PatrolSpeedMultiplier else bot.Speed
	bot.Humanoid:MoveTo(point :: Vector3)
end

local function updateBot(bot: Bot, now: number)
	-- Safety net: if a shark somehow falls out of the world, put it back.
	if bot.Root.Position.Y < Layout.GroundTop - 15 then
		bot.Model:PivotTo(CFrame.new(randomPointOnLine(bot.Zone) + Vector3.new(0, Config.Bots.HoverHeight + 2, 0)))
		stopChase(bot)
	end

	if bot.State == "Pause" then
		if now < bot.PauseUntil then
			return
		end
		bot.State = "Patrol"
	end

	if bot.State == "Chase" then
		local player = bot.Target
		if not (player and isValidTarget(player)) then
			if chaseLog and player then
				local root = getRoot(player)
				local where = if root then Layout.zoneIndexAt(root.Position) else nil
				print(string.format("[Race] chase over after %.1fs (thief reached %s, still carrying: %s)", now - bot.ChaseStartedAt, if where then `zone {where}` else "the safe zone", tostring(EggService.IsCarrying(player))))
				if bot.SpeedSamples > 0 then
					print(string.format("[Race] shark %d average measured chase speed %.1f vs configured %.1f", bot.Zone, bot.SpeedSum / bot.SpeedSamples, bot.Speed))
				end
			end
			stopChase(bot) -- safe, dropped the egg, died or left: go home
		end
	end

	if bot.State == "Patrol" then
		patrolStep(bot, now)
	end
end

---------------------------------------------------------------------------
-- Lifecycle
---------------------------------------------------------------------------

function BotService.Init()
end

function BotService.Start()
	botsFolder = Instance.new("Folder")
	botsFolder.Name = "Sharks"
	botsFolder.Parent = WorldService.GetFolder()

	for zoneIndex in Config.Zones do
		local row = Config.Sharks[zoneIndex]
		if not row then
			warn(`[{Config.GameName}] Config.Sharks has no row for zone {zoneIndex}; no shark there.`)
			continue
		end
		for _ = 1, row.Count do
			if #bots >= Config.Bots.MaxBotsTotal then
				break
			end
			table.insert(bots, createBot(zoneIndex))
		end
	end
	if Config.Debug then
		print(`[{Config.GameName}] Spawned {#bots} sharks`)
	end

	Players.PlayerRemoving:Connect(function(player)
		lastCaught[player] = nil
	end)

	-- Studio test: "!race 4" puts you at a typical egg spot in zone 4 with a
	-- zone 4 egg, puts zone 4's shark at a typical spot on its patrol line,
	-- counts down 3-2-1 (you're frozen) and starts the chase.
	DebugCommands.register("race", function(player, args)
		local zoneIndex = math.clamp(math.floor(tonumber(args[1]) or 1), 1, #Config.Zones)
		local zone = Config.Zones[zoneIndex]
		local character = player.Character
		local root = getRoot(player)
		if not (character and root) then
			return
		end
		if EggService.IsCarrying(player) then
			EggService.DropEgg(player, "race")
		end
		local near = Layout.zoneZRange(zoneIndex)
		local startZ = near - zone.Length * Config.Balance.PlayerStartFraction
		local spot = Vector3.new(0, Layout.GroundTop + 3, startZ)
		-- Facing the zone's start (+Z), so you can just hold W.
		character:PivotTo(CFrame.lookAt(spot, spot + Vector3.new(0, 0, 10)))
		root.Anchored = true
		for _, bot in bots do
			if bot.Zone == zoneIndex then
				stopChase(bot)
				bot.State = "Pause"
				bot.PauseUntil = math.huge
				local sharkSpot = Vector3.new(Config.Balance.AverageSideOffset, Layout.GroundTop, Layout.patrolLineZ(zoneIndex))
				local facing = Vector3.new(spot.X, sharkSpot.Y, spot.Z)
				bot.Model:PivotTo(CFrame.lookAt(sharkSpot, facing) + Vector3.new(0, Config.Bots.HoverHeight + SHARK_SIZE.Y / 2, 0))
				bot.Humanoid:MoveTo(bot.Root.Position)
			end
		end
		-- The most common egg rarity of that zone.
		local rarity, best = "Common", -1
		for name, weight in zone.EggWeights do
			if weight > best then
				rarity, best = name, weight
			end
		end
		task.spawn(function()
			for count = 3, 1, -1 do
				notify(player, `[Studio] Race in zone {zoneIndex}: {count}...`, "info")
				task.wait(1)
			end
			root.Anchored = false
			lastCaught[player] = nil
			notify(player, "🏃 RUN to the zone's start!", "warning")
			EggService.GiveCarriedEgg(player, rarity, zoneIndex)
		end)
	end)

	-- An egg was stolen: ONLY the shark(s) of the egg's ORIGINAL zone come
	-- after the thief (EggService passes the zone the egg first spawned in).
	EggService.EggPickedUp:Connect(function(player: Player, _rarity: string, zoneIndex: number)
		for _, bot in bots do
			if bot.Zone == zoneIndex and bot.State ~= "Chase" then
				startChase(bot, player)
			end
		end
	end)

	local elapsed = 0
	RunService.Heartbeat:Connect(function(dt: number)
		local now = os.clock()
		-- Chasing sharks steer every frame (smooth, full speed).
		for _, bot in bots do
			if bot.State == "Chase" then
				chaseStep(bot, now, dt)
			end
		end
		-- Everything else (patrol, pauses, giving up) a few times per second.
		elapsed += dt
		if elapsed < Config.Bots.UpdateInterval then
			return
		end
		elapsed = 0
		for _, bot in bots do
			updateBot(bot, now)
		end
	end)
end

return BotService
