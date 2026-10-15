--!strict
--[[
	SpeedService
	============
	Speed is the main progression: train on your treadmill -> faster -> you can
	outrun the sharks in deeper zones -> rarer eggs.

	This service owns:
	  - The Speed STAT of every player (shown in the HUD and on the leaderboard).
	    WalkSpeed is calculated from it by Config.WalkSpeedFromStat (via the
	    PlayerSpeed helper).
	  - Treadmill training:
	      * Walking onto YOUR OWN treadmill belt starts training. You're locked
	        in place facing the console (your character is anchored).
	      * Every Config.Treadmill.GainInterval seconds you gain Speed:
	          tier Gain * every gain multiplier (Robux boosts, later)
	        and your client shows a "+X Speed" popup.
	      * Pressing jump (Space, or the mobile jump button) asks the server to
	        let you off. Dying, resetting, leaving or a treadmill swap also stop
	        training.
	  - Which treadmill tier each player has (Config.Treadmill.Tiers). Everyone
	    has tier 1 for now; buying better tiers comes in the Upgrades milestone,
	    which will call SpeedService.SetTreadmillTier.

	Speed is NOT saved yet (that's the Saving milestone).

	Studio-only test commands (type in chat while play-testing in Studio):
		!speed 5000     set your Speed stat
		!speed zone 4   set your Speed stat to just enough for zone 4's shark
		!tier 5         swap your treadmill to tier 5
	If chat commands don't work, use the Command Bar (set to Server) instead:
		game.Players:GetPlayers()[1]:SetAttribute("DebugCommand", "!speed 5000")

	Public interface:
		SpeedService.GetStat(player) -> number
		SpeedService.SetStat(player, value)
		SpeedService.AddStat(player, amount)
		SpeedService.GetGainPerTick(player) -> number
		SpeedService.SetGainMultiplier(player, key, value?)  -- e.g. "Pass2x" = 2
		SpeedService.GetTreadmillTier(player) -> number
		SpeedService.SetTreadmillTier(player, tier)
		SpeedService.IsTraining(player) -> boolean
		SpeedService.SpeedChanged:Connect(function(player, stat) end)
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Config = require(ReplicatedStorage.Shared.Config)
local Constants = require(ReplicatedStorage.Shared.Constants)
local Format = require(ReplicatedStorage.Shared.Format)
local Net = require(ReplicatedStorage.Shared.Net)
local Signal = require(ReplicatedStorage.Shared.Signal)
local Types = require(ReplicatedStorage.Shared.Types)
local DebugCommands = require(script.Parent.Parent.Util.DebugCommands)
local Leaderstats = require(script.Parent.Parent.Util.Leaderstats)
local PlayerSpeed = require(script.Parent.Parent.Util.PlayerSpeed)
local RateLimiter = require(script.Parent.Parent.Util.RateLimiter)
local PlotService = require(script.Parent.PlotService)

type Session = {
	Belt: BasePart,
	Plot: Types.PlotInfo,
	NextGain: number,
}

local SpeedService = {}
SpeedService.Name = "SpeedService"

-- Fired with (player, newStat) whenever a Speed stat changes.
SpeedService.SpeedChanged = Signal.new()

local stats: { [Player]: number } = {}
local tiers: { [Player]: number } = {}
local gainMultipliers: { [Player]: { [string]: number } } = {}
local sessions: { [Player]: Session } = {}
local reEnterAt: { [Player]: number } = {}
local lastWrongTreadmillNotice: { [Player]: number } = {}
local stopLimiter = RateLimiter.new(5, 1)

local CHECK_INTERVAL = 0.15 -- seconds between "is anyone standing on a belt?" checks

local function notify(player: Player, message: string)
	Net.event(Net.Names.Notify):FireClient(player, message)
end

local function getRoot(player: Player): BasePart?
	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	if root and root:IsA("BasePart") then
		return root
	end
	return nil
end

local function getHumanoid(player: Player): Humanoid?
	local character = player.Character
	return if character then character:FindFirstChildOfClass("Humanoid") else nil
end

---------------------------------------------------------------------------
-- Speed stat
---------------------------------------------------------------------------

function SpeedService.GetStat(player: Player): number
	return stats[player] or Config.Speed.StartingStat
end

function SpeedService.SetStat(player: Player, value: number)
	value = math.max(0, value)
	stats[player] = value
	player:SetAttribute(Constants.Attributes.SpeedStat, value)
	Leaderstats.set(player, "Speed", Format.short(value))
	PlayerSpeed.SetSpeedStat(player, value)
	SpeedService.SpeedChanged:Fire(player, value)
end

function SpeedService.AddStat(player: Player, amount: number)
	SpeedService.SetStat(player, SpeedService.GetStat(player) + amount)
end

---------------------------------------------------------------------------
-- Treadmill tiers and gain
---------------------------------------------------------------------------

function SpeedService.GetTreadmillTier(player: Player): number
	return tiers[player] or 1
end

-- How much Speed one training tick gives: the tier's Gain times every boost.
function SpeedService.GetGainPerTick(player: Player): number
	local tier = Config.Treadmill.Tiers[SpeedService.GetTreadmillTier(player)]
	local gain = tier.Gain
	local multipliers = gainMultipliers[player]
	if multipliers then
		for _, multiplier in multipliers do
			gain *= multiplier
		end
	end
	return gain
end

-- Add/remove a named boost, e.g. SetGainMultiplier(player, "SpeedPass", 2).
function SpeedService.SetGainMultiplier(player: Player, key: string, value: number?)
	local multipliers = gainMultipliers[player]
	if not multipliers then
		multipliers = {}
		gainMultipliers[player] = multipliers
	end
	if value then
		multipliers[key] = value
	else
		multipliers[key] = nil
	end
end

function SpeedService.IsTraining(player: Player): boolean
	return sessions[player] ~= nil
end

---------------------------------------------------------------------------
-- Training
---------------------------------------------------------------------------

-- Is `position` (a character's root) standing on this belt?
local function isOnBelt(belt: BasePart, position: Vector3): boolean
	local localPos = belt.CFrame:PointToObjectSpace(position)
	return math.abs(localPos.X) <= belt.Size.X / 2 + 0.5
		and math.abs(localPos.Z) <= belt.Size.Z / 2
		and localPos.Y > 0
		and localPos.Y < 7
end

-- How high a character's root part sits above the surface it stands on.
local function rootHeight(humanoid: Humanoid, root: BasePart): number
	if humanoid.RigType == Enum.HumanoidRigType.R6 then
		return 3
	end
	return humanoid.HipHeight + root.Size.Y / 2
end

local function startTraining(player: Player, plot: Types.PlotInfo, root: BasePart, humanoid: Humanoid)
	local belt = plot.Treadmill
	local character = root.Parent
	if not (character and character:IsA("Model")) then
		return
	end

	-- Stand in the middle of the belt, facing the console (the belt's +Z end).
	local beltTop = belt.Position.Y + belt.Size.Y / 2
	local position = Vector3.new(belt.Position.X, beltTop + rootHeight(humanoid, root), belt.Position.Z)
	character:PivotTo(CFrame.lookAt(position, position - belt.CFrame.LookVector))
	root.AssemblyLinearVelocity = Vector3.zero
	root.Anchored = true

	sessions[player] = {
		Belt = belt,
		Plot = plot,
		NextGain = os.clock() + Config.Treadmill.GainInterval,
	}
	player:SetAttribute(Constants.Attributes.Training, true)
	belt:SetAttribute(Constants.Attributes.BeltActive, true)
end

-- Stop training. stepOff = true puts the player down in front of the treadmill.
local function stopTraining(player: Player, stepOff: boolean)
	local session = sessions[player]
	if not session then
		return
	end
	sessions[player] = nil
	player:SetAttribute(Constants.Attributes.Training, nil)
	reEnterAt[player] = os.clock() + Config.Treadmill.ReEnterCooldown

	local belt = session.Belt
	if belt.Parent then
		belt:SetAttribute(Constants.Attributes.BeltActive, false)
	end

	local root = getRoot(player)
	if root then
		if stepOff and belt.Parent then
			-- In front of the entry end, facing away from the treadmill.
			local exit = (belt.CFrame * CFrame.new(0, 0, -(belt.Size.Z / 2 + 4))).Position
			local position = Vector3.new(exit.X, root.Position.Y, exit.Z)
			local character = root.Parent
			if character and character:IsA("Model") then
				character:PivotTo(CFrame.lookAt(position, position + belt.CFrame.LookVector))
			end
		end
		root.Anchored = false
	end
end

-- Runs a few times per second: start training for players standing on their
-- own belt.
local function checkBelts(now: number)
	for _, player in Players:GetPlayers() do
		if sessions[player] or now < (reEnterAt[player] or 0) then
			continue
		end
		local root = getRoot(player)
		local humanoid = getHumanoid(player)
		if not (root and humanoid and humanoid.Health > 0) or root.Anchored then
			continue
		end
		local ownPlot = PlotService.GetPlot(player)
		if ownPlot and isOnBelt(ownPlot.Treadmill, root.Position) then
			startTraining(player, ownPlot, root, humanoid)
			continue
		end
		-- Standing on someone else's treadmill? Tell them (not too often).
		for _, plot in PlotService.GetPlots() do
			if plot ~= ownPlot and isOnBelt(plot.Treadmill, root.Position) then
				if now - (lastWrongTreadmillNotice[player] or 0) > 4 then
					lastWrongTreadmillNotice[player] = now
					notify(player, "That's not your treadmill! Use the one on your own plot.")
				end
				break
			end
		end
	end
end

-- Runs every frame: hand out Speed to everyone who is training.
local function giveGains(now: number)
	for player, session in sessions do
		-- Safety: the treadmill was rebuilt or the plot changed hands.
		if session.Belt.Parent == nil or session.Plot.Owner ~= player then
			stopTraining(player, false)
			continue
		end
		if now >= session.NextGain then
			session.NextGain += Config.Treadmill.GainInterval
			local amount = SpeedService.GetGainPerTick(player)
			SpeedService.AddStat(player, amount)
			Net.event(Net.Names.SpeedGained):FireClient(player, amount)
		end
	end
end

-- Swap the player's treadmill tier (the Upgrades milestone calls this after
-- a purchase).
function SpeedService.SetTreadmillTier(player: Player, tier: number)
	tier = math.clamp(math.floor(tier), 1, #Config.Treadmill.Tiers)
	tiers[player] = tier
	local plot = PlotService.GetPlot(player)
	if plot and plot.TreadmillTier ~= tier then
		stopTraining(player, false)
		PlotService.SetTreadmillTier(plot, tier)
	end
end

---------------------------------------------------------------------------
-- Balance printout and Studio test commands
---------------------------------------------------------------------------

local function formatMinutes(minutes: number): string
	if minutes <= 0 then
		return "from the start"
	elseif minutes < 60 then
		return `~{math.ceil(minutes)} min`
	end
	return `~{Format.decimal(minutes / 60, 1)} h`
end

local function printBalanceTable()
	local lines = {
		`[{Config.GameName}] SPEED BALANCE (outrun = walk {Config.Speed.OutrunMargin} faster than the shark)`,
		"  Zone  Name                 Shark  Speed stat needed  Time on Basic treadmill",
	}
	for index, zone in Config.Zones do
		local shark = Config.Sharks[index]
		if shark then
			local needed = shark.SpeedStatNeeded or 0
			local neededText = if needed == math.huge then "impossible (cap)" else Format.short(needed)
			table.insert(
				lines,
				string.format(
					"  %-5d %-20s %-6s %-18s %s",
					index,
					zone.Name,
					tostring(shark.Speed),
					neededText,
					formatMinutes(shark.MinutesAtTier1 or 0)
				)
			)
		end
	end
	table.insert(lines, "  Treadmill tiers:")
	for index, tier in Config.Treadmill.Tiers do
		table.insert(
			lines,
			string.format("    %2d %-8s price %-8s +%s Speed/sec", index, tier.Name, Format.short(tier.Price), Format.short(tier.Gain))
		)
	end
	print(table.concat(lines, "\n"))
end

local function registerDebugCommands()
	DebugCommands.register("speed", function(player, args)
		local value: number?
		if args[1] == "zone" then
			local zone = tonumber(args[2])
			local shark = if zone then Config.Sharks[zone] else nil
			value = if shark then shark.SpeedStatNeeded else nil
		else
			value = tonumber(args[1])
		end
		if value and value < math.huge then
			SpeedService.SetStat(player, value)
			notify(player, `[Studio] Speed stat set to {Format.short(value)} (WalkSpeed {Format.decimal(PlayerSpeed.Get(player), 1)})`)
		end
	end)
	DebugCommands.register("tier", function(player, args)
		local tier = tonumber(args[1])
		if tier then
			SpeedService.SetTreadmillTier(player, tier)
			notify(player, `[Studio] Treadmill tier set to {SpeedService.GetTreadmillTier(player)}`)
		end
	end)
end

---------------------------------------------------------------------------
-- Lifecycle
---------------------------------------------------------------------------

local function watchPlayer(player: Player)
	SpeedService.SetStat(player, SpeedService.GetStat(player))

	local function watchCharacter(character: Model)
		local humanoid = character:WaitForChild("Humanoid", 10)
		if humanoid and humanoid:IsA("Humanoid") then
			humanoid.Died:Connect(function()
				stopTraining(player, false)
			end)
		end
	end
	player.CharacterAdded:Connect(watchCharacter)
	player.CharacterRemoving:Connect(function()
		stopTraining(player, false)
	end)
	if player.Character then
		task.spawn(watchCharacter, player.Character)
	end
end

function SpeedService.Init()
end

function SpeedService.Start()
	if Config.Debug then
		printBalanceTable()
	end
	registerDebugCommands()

	Players.PlayerAdded:Connect(watchPlayer)
	for _, player in Players:GetPlayers() do
		watchPlayer(player)
	end
	Players.PlayerRemoving:Connect(function(player)
		stopTraining(player, false)
		stats[player] = nil
		tiers[player] = nil
		gainMultipliers[player] = nil
		reEnterAt[player] = nil
		lastWrongTreadmillNotice[player] = nil
	end)

	-- Give each owner their own treadmill tier when they get a plot.
	PlotService.PlotAssigned:Connect(function(player: Player, plot: Types.PlotInfo)
		PlotService.SetTreadmillTier(plot, SpeedService.GetTreadmillTier(player))
	end)

	-- The client asks to step off (jump pressed). We only trust WHO asked:
	-- they must actually be training, and can't spam the request.
	Net.event(Net.Names.StopTraining).OnServerEvent:Connect(function(player: Player)
		if stopLimiter.allow(player) and sessions[player] then
			stopTraining(player, true)
		end
	end)

	local checkElapsed = 0
	RunService.Heartbeat:Connect(function(dt: number)
		local now = os.clock()
		giveGains(now)
		checkElapsed += dt
		if checkElapsed >= CHECK_INTERVAL then
			checkElapsed = 0
			checkBelts(now)
		end
	end)
end

return SpeedService
