--!strict
--[[
	BotService
	==========
	The sharks. Each zone gets the number of sharks and the chase speed from
	its row in Config.Sharks (row 1 = zone 1, and so on).

	What a shark does (checked every Config.Bots.UpdateInterval seconds):
	  - PATROL: swim slowly to a random point in its home zone, wait, repeat.
	    If it is outside its home zone (after a chase), it swims back at full
	    speed first.
	  - CHASE: ONLY when an egg is stolen from ITS zone (EggService tells us
	    which zone). Sharks never react just because someone walks by.
	    It chases that thief across zone borders, at full speed:
	      * Close by (DirectChaseDistance): swim straight at them.
	      * Farther away: follow a path from PathfindingService. Paths are
	        recalculated at most every PathRecomputeInterval seconds per shark,
	        and all sharks share a budget of MaxPathComputesPerSecond.
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

	Model: a placeholder shark built from parts, or your own model named
	Config.Bots.ModelName ("Shark") in ReplicatedStorage.Assets. Sharks use a
	Humanoid without legs, floating at Config.Bots.HoverHeight.

	Public interface:
		BotService.PlayerCaught:Connect(function(player) end)
]]

local PathfindingService = game:GetService("PathfindingService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Config = require(ReplicatedStorage.Shared.Config)
local Layout = require(ReplicatedStorage.Shared.Layout)
local Net = require(ReplicatedStorage.Shared.Net)
local Signal = require(ReplicatedStorage.Shared.Signal)
local Notify = require(script.Parent.Parent.Util.Notify)
local Assets = require(script.Parent.Parent.Util.Assets)
local Build = require(script.Parent.Parent.Util.Build)
local EggService = require(script.Parent.EggService)
local WorldService = require(script.Parent.WorldService)

type BotState = "Patrol" | "Pause" | "Chase"

type Bot = {
	Model: Model,
	Root: BasePart,
	Humanoid: Humanoid,
	Indicator: BillboardGui, -- the "!" shown while chasing
	Path: Path,
	Zone: number,
	Speed: number,
	-- Leash area (inclusive), in world X and Z.
	MinX: number,
	MaxX: number,
	MinZ: number,
	MaxZ: number,

	State: BotState,
	Target: Player?,
	PatrolPoint: Vector3?,
	PauseUntil: number,
	Waypoints: { Vector3 }?,
	WaypointIndex: number,
	LastPathTime: number,
	Computing: boolean,
}

local BotService = {}
BotService.Name = "BotService"

-- Fired with (player) whenever a shark catches someone.
BotService.PlayerCaught = Signal.new()

local SHARK_SIZE = Vector3.new(3, 3, 9) -- invisible body box (nose points to -Z)
local WAYPOINT_REACHED = 3 -- studs: close enough to move on to the next waypoint
local PATROL_REACHED = 4

local rng = Random.new()
local bots: { Bot } = {}
local botsFolder: Folder
local lastCaught: { [Player]: number } = {}
local pathTokens = Config.Bots.MaxPathComputesPerSecond

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

local function randomPointInZone(zoneIndex: number): Vector3
	local cf, size = Layout.zoneCFrameAndSize(zoneIndex)
	local margin = 8
	local x = rng:NextNumber(-size.X / 2 + margin, size.X / 2 - margin)
	local z = rng:NextNumber(-size.Z / 2 + margin, size.Z / 2 - margin)
	return (cf * CFrame.new(x, 0, z)).Position
end

local function notify(player: Player, message: string, kind: string?)
	Notify.send(player, message, kind)
end

---------------------------------------------------------------------------
-- Building a shark
---------------------------------------------------------------------------

-- A simple shark made of parts, welded to the (invisible) root part.
local function buildPlaceholderShark(model: Model, root: BasePart)
	local bodyColor = Color3.fromRGB(105, 125, 150)
	local function add(name: string, size: Vector3, offset: CFrame, color: Color3, shape: string?): BasePart
		local part: BasePart
		if shape == "Wedge" then
			part = Instance.new("WedgePart")
		else
			part = Instance.new("Part")
		end
		part.Name = name
		part.Size = size
		part.Color = color
		part.Material = Enum.Material.SmoothPlastic
		part.CanCollide = false
		part.CanQuery = false
		part.CanTouch = false
		part.Massless = true
		part.CFrame = root.CFrame * offset
		if shape == "Egg" then
			local mesh = Instance.new("SpecialMesh")
			mesh.MeshType = Enum.MeshType.Sphere
			mesh.Parent = part
		end
		local weld = Instance.new("WeldConstraint")
		weld.Part0 = root
		weld.Part1 = part
		weld.Parent = part
		part.Parent = model
		return part
	end

	-- Body: a stretched sphere. The nose points to -Z (the way it swims).
	add("Body", Vector3.new(3.2, 3, 9), CFrame.new(), bodyColor, "Egg")
	-- Pale belly.
	add("Belly", Vector3.new(2.6, 1.6, 7), CFrame.new(0, -0.8, -0.3), Color3.fromRGB(230, 235, 240), "Egg")
	-- Dorsal fin on top (a wedge).
	add("DorsalFin", Vector3.new(0.4, 2.6, 2.6), CFrame.new(0, 2.4, 0.6), bodyColor, "Wedge")
	-- Tail fin at the back, standing up.
	add("TailFin", Vector3.new(0.4, 3.2, 2), CFrame.new(0, 0.6, 5) * CFrame.Angles(0, math.pi, 0), bodyColor, "Wedge")
	-- Side fins.
	for _, side in { -1, 1 } do
		add("SideFin", Vector3.new(2.2, 0.3, 1.4), CFrame.new(side * 2, -0.6, -0.8) * CFrame.Angles(0, 0, side * math.rad(-20)), bodyColor)
		add("Eye", Vector3.new(0.45, 0.45, 0.45), CFrame.new(side * 1.05, 0.5, -3.3), Color3.new(0, 0, 0), "Egg")
	end
	-- Mouth.
	add("Mouth", Vector3.new(1.6, 0.25, 0.8), CFrame.new(0, -0.5, -3.9), Color3.fromRGB(120, 20, 30))
end

local function createBot(zoneIndex: number): Bot
	local zone = Config.Zones[zoneIndex]
	local sharkSpeed = Config.Sharks[zoneIndex].Speed
	local spawnPoint = randomPointInZone(zoneIndex)
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

	if not Assets.decorate(root, Config.Bots.ModelName, true) then
		buildPlaceholderShark(model, root)
	end

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
	local label = Build.billboard(root, "❗", 4, 120)
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
	local path = PathfindingService:CreatePath({
		AgentRadius = 3,
		AgentHeight = 6,
		AgentCanJump = false,
		AgentCanClimb = false,
		WaypointSpacing = 8,
	})

	return {
		Model = model,
		Root = root,
		Humanoid = humanoid,
		Indicator = indicator,
		Path = path,
		Zone = zoneIndex,
		Speed = sharkSpeed,
		MinX = -halfWidth,
		MaxX = halfWidth,
		MinZ = Layout.DangerZoneBack + edge,
		MaxZ = Layout.DangerZoneFront - Config.Bots.SafeLineMargin,
		State = "Patrol",
		Target = nil,
		PatrolPoint = nil,
		PauseUntil = 0,
		Waypoints = nil,
		WaypointIndex = 1,
		LastPathTime = 0,
		Computing = false,
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
	bot.Waypoints = nil
	bot.LastPathTime = 0
	bot.Humanoid.WalkSpeed = bot.Speed
	bot.Indicator.Enabled = true
end

local function stopChase(bot: Bot)
	bot.State = "Patrol"
	bot.Target = nil
	bot.Waypoints = nil
	bot.PatrolPoint = nil
	bot.Humanoid.WalkSpeed = bot.Speed * Config.Bots.PatrolSpeedMultiplier
	bot.Indicator.Enabled = false
end

local function catch(bot: Bot, player: Player, now: number)
	lastCaught[player] = now
	EggService.DropEgg(player, "caught")
	notify(player, "🦈 Caught by a shark! You lost your egg.", "danger")

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

-- Ask PathfindingService for a new path (in the background, within budget).
local function requestPath(bot: Bot, goal: Vector3, now: number)
	if bot.Computing or now - bot.LastPathTime < Config.Bots.PathRecomputeInterval or pathTokens < 1 then
		return
	end
	pathTokens -= 1
	bot.LastPathTime = now
	bot.Computing = true
	task.spawn(function()
		local ok = pcall(function()
			bot.Path:ComputeAsync(bot.Root.Position, goal)
		end)
		bot.Computing = false
		if ok and bot.Path.Status == Enum.PathStatus.Success and bot.State == "Chase" then
			local points: { Vector3 } = {}
			for _, waypoint in bot.Path:GetWaypoints() do
				table.insert(points, waypoint.Position)
			end
			bot.Waypoints = points
			bot.WaypointIndex = math.min(2, #points) -- point 1 is where we already are
		else
			bot.Waypoints = nil -- no path: swim straight instead
		end
	end)
end

local function chaseStep(bot: Bot, now: number)
	local player = bot.Target
	local targetRoot = if player then getRoot(player) else nil
	if not (player and targetRoot) then
		stopChase(bot)
		return
	end

	local distance = (targetRoot.Position - bot.Root.Position).Magnitude
	if distance <= Config.Bots.CatchDistance and not onCatchCooldown(player, now) then
		catch(bot, player, now)
		return
	end

	local goal = clampToLeash(bot, targetRoot.Position)
	if distance <= Config.Bots.DirectChaseDistance then
		bot.Waypoints = nil
		bot.Humanoid:MoveTo(goal)
		return
	end

	requestPath(bot, goal, now)

	-- Follow the current path, if we have one.
	local waypoints = bot.Waypoints
	while waypoints and bot.WaypointIndex <= #waypoints do
		local waypoint = waypoints[bot.WaypointIndex]
		if flatDistance(bot.Root.Position, waypoint) > WAYPOINT_REACHED then
			bot.Humanoid:MoveTo(waypoint)
			return
		end
		bot.WaypointIndex += 1
	end
	bot.Humanoid:MoveTo(goal)
end

local function patrolStep(bot: Bot, now: number)
	local point = bot.PatrolPoint
	if point and flatDistance(bot.Root.Position, point) <= PATROL_REACHED then
		-- Arrived: rest a moment before choosing the next point.
		bot.PatrolPoint = nil
		bot.State = "Pause"
		bot.PauseUntil = now + Config.Bots.PatrolPauseTime
		return
	end
	if not point then
		point = randomPointInZone(bot.Zone)
		bot.PatrolPoint = point
	end
	-- Outside its home zone (after a chase)? Hurry back at full speed.
	local near, far = Layout.zoneZRange(bot.Zone)
	local z = bot.Root.Position.Z
	local atHome = z <= near and z >= far
	bot.Humanoid.WalkSpeed = if atHome then bot.Speed * Config.Bots.PatrolSpeedMultiplier else bot.Speed
	bot.Humanoid:MoveTo(point :: Vector3)
end

local function updateBot(bot: Bot, now: number)
	-- Safety net: if a shark somehow falls out of the world, put it back.
	if bot.Root.Position.Y < Layout.GroundTop - 15 then
		bot.Model:PivotTo(CFrame.new(randomPointInZone(bot.Zone) + Vector3.new(0, Config.Bots.HoverHeight + 2, 0)))
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
			stopChase(bot) -- safe, dropped the egg, died or left: go home
		end
	end

	if bot.State == "Chase" then
		chaseStep(bot, now)
	elseif bot.State == "Patrol" then
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

	-- An egg was stolen: ONLY the shark(s) of that zone come after the thief.
	EggService.EggPickedUp:Connect(function(player: Player, _rarity: string, zoneIndex: number)
		for _, bot in bots do
			if bot.Zone == zoneIndex and bot.State ~= "Chase" then
				startChase(bot, player)
			end
		end
	end)

	local elapsed = 0
	RunService.Heartbeat:Connect(function(dt: number)
		-- Refill the shared pathfinding budget.
		local maxTokens = Config.Bots.MaxPathComputesPerSecond
		pathTokens = math.min(maxTokens, pathTokens + dt * maxTokens)

		elapsed += dt
		if elapsed < Config.Bots.UpdateInterval then
			return
		end
		elapsed = 0
		local now = os.clock()
		for _, bot in bots do
			updateBot(bot, now)
		end
	end)
end

return BotService
