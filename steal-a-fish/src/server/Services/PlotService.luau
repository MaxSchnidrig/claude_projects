--!strict
--[[
	PlotService
	===========
	Builds the plots (Config.Plots.Count of them, in one row), gives each
	joining player a free plot, frees it when they leave, and makes players
	spawn on their own plot.

	What's on a plot (placeholder parts; see Util/Assets to swap in models):
	  - Floor (colored; faded while nobody owns it)
	  - Sign gate at the front with the owner's name
	  - SpawnLocation: the owner spawns here
	  - Treadmill at the front: train Speed here
	  - CollectPad (green, middle): step on it to collect your pets' money
	  - Pads along the left and right side (Config.Plots.PadsPerSide each).
	    Each pad holds ONE egg or ONE pet (PetService decides what's on it).
	    Locked pads are hidden. The "Upgrade Plot" board in front of the plot
	    adds one pad per level; level 5 builds a SECOND FLOOR with 10 more pads.
	  - An upgrade board next to the treadmill with an "Upgrade Treadmill"
	    prompt showing the next tier and its price.
	  Both prompts fire PlotService.UpgradePromptTriggered; UpgradeService
	  checks and takes the money.

	Plots are SAFE ZONES: bots stay in the danger zone (see WorldService), and
	other services can ask PlotService.IsInsideAnyPlot(position).

	Public interface:
		PlotService.GetPlot(player) -> PlotInfo?          -- the player's plot
		PlotService.GetPlots() -> { PlotInfo }             -- all plots
		PlotService.GetPlotAt(position) -> PlotInfo?       -- plot containing a point
		PlotService.IsInsideAnyPlot(position) -> boolean
		PlotService.SetPlotLevel(plot, level, animate?)    -- pads + second floor for a plot level
		PlotService.SetTreadmillTier(plot, tier)           -- rebuild the treadmill as another tier
		PlotService.TreadmillChanged:Connect(function(plot) end)
		PlotService.PlotAssigned:Connect(function(player, plot) end)
		PlotService.PlotReleased:Connect(function(player, plot) end)
		PlotService.UpgradePromptTriggered:Connect(function(player, plot, "Plot" | "Treadmill") end)
]]

local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local TweenService = game:GetService("TweenService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = require(ReplicatedStorage.Shared.Config)
local Layout = require(ReplicatedStorage.Shared.Layout)
local Signal = require(ReplicatedStorage.Shared.Signal)
local Types = require(ReplicatedStorage.Shared.Types)
local Notify = require(script.Parent.Parent.Util.Notify)
local Assets = require(script.Parent.Parent.Util.Assets)
local Build = require(script.Parent.Parent.Util.Build)
local Constants = require(ReplicatedStorage.Shared.Constants)
local Format = require(ReplicatedStorage.Shared.Format)
local Net = require(ReplicatedStorage.Shared.Net)
local TreadmillBuilder = require(script.Parent.Parent.Util.TreadmillBuilder)
local PlayerLifecycle = require(script.Parent.Parent.Util.PlayerLifecycle)
local WorldService = require(script.Parent.WorldService)

type PlotInfo = Types.PlotInfo

local PlotService = {}
PlotService.Name = "PlotService"

-- Fired with (player, plot) when a player gets a plot / gives it up.
PlotService.PlotAssigned = Signal.new()
PlotService.PlotReleased = Signal.new()
-- Fired with (plot) after a plot's treadmill was rebuilt as another tier.
PlotService.TreadmillChanged = Signal.new()
-- Fired with (player, plot, "Plot" or "Treadmill") when an upgrade prompt is used.
PlotService.UpgradePromptTriggered = Signal.new()

-- Every part of a plot gets the (strong) plot studs.
local function plotPart(props: Build.PartProps): Part
	props.StudTransparency = Config.Visuals.PlotStudTransparency
	return Build.part(props)
end

local plots: { PlotInfo } = {}
local plotByPlayer: { [Player]: PlotInfo } = {}

---------------------------------------------------------------------------
-- Building
---------------------------------------------------------------------------

-- Where pad number `padIndex` goes, relative to the plot center, and which
-- way it faces (toward the middle of the plot). Pads alternate left/right
-- and fill from the front (near the danger zone) to the back.
local function padCFrame(padIndex: number): CFrame
	local plots = Config.Plots
	local size = plots.Size
	local padSize = plots.PadSize
	local perSide = math.max(plots.PadsPerSide, 1)
	local side = if padIndex % 2 == 1 then -1 else 1 -- odd = left, even = right
	local row = math.ceil(padIndex / 2) - 1 -- 0 = front row

	-- Rows run from just behind the treadmill to the back rail.
	local firstZ = -size.Z / 2 + 26 + padSize.Z / 2
	local lastZ = size.Z / 2 - 1.5 - padSize.Z / 2
	local spacing = if perSide > 1 then (lastZ - firstZ) / (perSide - 1) else 0
	local x = side * (size.X / 2 - 1.5 - padSize.X / 2)
	local position = Vector3.new(x, padSize.Y / 2, firstZ + row * spacing)
	-- LookVector points toward the middle of the plot.
	return CFrame.lookAt(position, position + Vector3.new(-side, 0, 0))
end

-- Build a treadmill of the given tier (with its floating name label) and
-- return its belt.
local function buildTreadmill(origin: CFrame, parent: Instance, tier: number): BasePart
	local _, belt = TreadmillBuilder.build(origin, parent, tier)
	local tierName = Config.Treadmill.Tiers[math.clamp(tier, 1, #Config.Treadmill.Tiers)].Name
	Build.billboard(belt, `🏃 {tierName} Treadmill`, 8, 60)
	return belt
end

local function buildPlot(index: number, parent: Instance): PlotInfo
	local size = Config.Plots.Size
	local cf = Layout.plotCFrame(index)
	local color = Config.Plots.Colors[(index - 1) % #Config.Plots.Colors + 1]

	local model = Instance.new("Model")
	model.Name = `Plot{index}`
	model:SetAttribute("PlotIndex", index)
	model:SetAttribute("OwnerUserId", 0)

	local floor = plotPart({
		Name = "Floor",
		Size = size,
		CFrame = cf * CFrame.new(0, -size.Y / 2, 0),
		Color = color,
		Parent = model,
	})
	model.PrimaryPart = floor

	-- Low rails on the left, right and back. The front stays open.
	local railColor = color:Lerp(Color3.new(0, 0, 0), 0.35)
	for _, side in { -1, 1 } do
		plotPart({
			Name = "Rail",
			Size = Vector3.new(1, 2, size.Z),
			CFrame = cf * CFrame.new(side * (size.X / 2 - 0.5), 1, 0),
			Color = railColor,
			Parent = model,
		})
	end
	plotPart({
		Name = "Rail",
		Size = Vector3.new(size.X, 2, 1),
		CFrame = cf * CFrame.new(0, 1, size.Z / 2 - 0.5),
		Color = railColor,
		Parent = model,
	})

	-- Sign gate at the front: two posts with a board across the top.
	local frontZ = -size.Z / 2 + 1
	for _, side in { -1, 1 } do
		plotPart({
			Name = "SignPost",
			Size = Vector3.new(1.5, 12, 1.5),
			CFrame = cf * CFrame.new(side * 14, 6, frontZ),
			Color = railColor,
			Parent = model,
		})
	end
	local board = plotPart({
		Name = "Sign",
		Size = Vector3.new(30, 5, 1),
		CFrame = cf * CFrame.new(0, 14, frontZ),
		Color = Color3.fromRGB(35, 45, 70),
		Studs = false, -- keep the name easy to read
		Parent = model,
	})
	Assets.decorate(board, "PlotSign")
	-- "Front" faces the open front area; "Back" faces into the plot.
	local signLabels = {
		Build.surfaceText(board, Enum.NormalId.Front, ""),
		Build.surfaceText(board, Enum.NormalId.Back, ""),
	}

	-- Spawn point near the front.
	local spawn = Instance.new("SpawnLocation")
	spawn.Name = "Spawn"
	spawn.Anchored = true
	spawn.Size = Vector3.new(8, 0.4, 8)
	spawn.CFrame = cf * CFrame.new(0, 0.2, -size.Z / 2 + 8)
	spawn.Color = color:Lerp(Color3.new(1, 1, 1), 0.5)
	spawn.Material = Enum.Material.SmoothPlastic
	spawn.TopSurface = Enum.SurfaceType.Smooth
	spawn.Duration = 0 -- no spawn force field
	spawn.Neutral = false -- only used through Player.RespawnLocation
	spawn.Enabled = true
	spawn.Parent = model

	-- Treadmill at the front right corner, so it's easy to reach from the
	-- open area. You step on from the front and run toward the console.
	local treadmillOrigin = cf * CFrame.new(size.X / 2 - 9, 0, -size.Z / 2 + 11)
	local treadmill = buildTreadmill(treadmillOrigin, model, 1)

	-- Upgrade board next to the treadmill, facing the middle of the plot.
	local boardCFrame = cf * CFrame.new(size.X / 2 - 25, 0, -size.Z / 2 + 13) * CFrame.Angles(0, math.pi / 2, 0)
	plotPart({
		Name = "UpgradePost",
		Size = Vector3.new(1, 3, 1),
		CFrame = boardCFrame * CFrame.new(0, 1.5, 0),
		Color = railColor,
		Parent = model,
	})
	local upgradeSign = plotPart({
		Name = "UpgradeSign",
		Size = Vector3.new(7, 4, 0.8),
		CFrame = boardCFrame * CFrame.new(0, 5, 0),
		Color = Color3.fromRGB(35, 45, 70),
		StudFaces = { Enum.NormalId.Top, Enum.NormalId.Back },
		Parent = model,
	})
	local upgradeLabel = Build.surfaceText(upgradeSign, Enum.NormalId.Front, "", Color3.fromRGB(255, 235, 90))
	local upgradePrompt = Instance.new("ProximityPrompt")
	upgradePrompt.Name = "UpgradePrompt"
	upgradePrompt.ActionText = "Upgrade Treadmill"
	upgradePrompt.HoldDuration = 0.3
	upgradePrompt.MaxActivationDistance = 10
	upgradePrompt.RequiresLineOfSight = false
	upgradePrompt:SetAttribute(Constants.Attributes.OwnerUserId, 0)
	upgradePrompt.Parent = upgradeSign

	-- Collect pad in the middle, behind the spawn: step on it to take the
	-- money your pets made (Config.Economy.CollectMode = "Pad").
	local collectPad = plotPart({
		Name = "CollectPad",
		Size = Config.Economy.CollectPadSize,
		CFrame = cf * CFrame.new(0, Config.Economy.CollectPadSize.Y / 2, -size.Z / 2 + 20),
		Color = Color3.fromRGB(90, 220, 110),
		StudFaces = { Enum.NormalId.Top },
		Parent = model,
	})
	Assets.decorate(collectPad, "CollectPad")
	local collectLabel = Build.billboard(collectPad, "💰 $0", 4, 60)
	collectLabel.TextColor3 = Color3.fromRGB(120, 255, 140)

	-- Pads along both sides. Each one holds one egg or one pet.
	local padsFolder = Instance.new("Folder")
	padsFolder.Name = "Pads"
	padsFolder.Parent = model
	local pads: { BasePart } = {}
	-- Rotated so the pad's "depth" (PadSize.X) points toward the middle.
	local padSize = Config.Plots.PadSize
	-- Pads 1-10 on the ground floor, 11-20 on the second floor (same spots,
	-- SecondFloorHeight higher). Locked pads are hidden (parent = nil).
	local perFloor = Config.PadsPerFloor()
	for padIndex = 1, Config.MaxPads() do
		local floorIndex = (padIndex - 1) % perFloor + 1
		local height = if padIndex > perFloor then Config.Plots.SecondFloorHeight else 0
		local pad = plotPart({
			Name = `Pad{padIndex}`,
			Size = Vector3.new(padSize.Z, padSize.Y, padSize.X),
			CFrame = cf * CFrame.new(0, height, 0) * padCFrame(floorIndex),
			Color = Config.Plots.PadColor,
			Parent = padsFolder,
		})
		pad:SetAttribute("PadIndex", padIndex)
		Assets.decorate(pad, "Pad")
		pad.Parent = nil
		table.insert(pads, pad)
	end

	-- "Upgrade Plot" board in front of the plot, next to the entrance,
	-- facing the open area.
	local plotSignCFrame = cf * CFrame.new(-24, 0, -size.Z / 2 - 3)
	plotPart({
		Name = "PlotSignPost",
		Size = Vector3.new(1, 3, 1),
		CFrame = plotSignCFrame * CFrame.new(0, 1.5, 0),
		Color = railColor,
		Parent = model,
	})
	local plotSign = plotPart({
		Name = "PlotSign",
		Size = Vector3.new(9, 5, 0.8),
		CFrame = plotSignCFrame * CFrame.new(0, 5.5, 0),
		Color = Color3.fromRGB(40, 90, 60),
		StudFaces = { Enum.NormalId.Top, Enum.NormalId.Back },
		Parent = model,
	})
	local plotSignLabel = Build.surfaceText(plotSign, Enum.NormalId.Front, "", Color3.fromRGB(255, 240, 120))
	local plotPrompt = Instance.new("ProximityPrompt")
	plotPrompt.Name = "PlotPrompt"
	plotPrompt.ActionText = "Upgrade Plot"
	plotPrompt.HoldDuration = 0.3
	plotPrompt.MaxActivationDistance = 10
	plotPrompt.RequiresLineOfSight = false
	plotPrompt:SetAttribute(Constants.Attributes.OwnerUserId, 0)
	plotPrompt.Parent = plotSign

	model.Parent = parent

	return {
		Index = index,
		Model = model,
		Owner = nil,
		CFrame = cf,
		Spawn = spawn,
		Treadmill = treadmill,
		TreadmillOrigin = treadmillOrigin,
		TreadmillTier = 1,
		Pads = pads,
		UnlockedPads = 0,
		Level = 0,
		SecondFloor = nil,
		PlotSign = plotSign,
		PlotSignLabel = plotSignLabel,
		SignLabels = signLabels,
		CollectPad = collectPad,
		CollectLabel = collectLabel,
		UpgradeSign = upgradeSign,
		UpgradeLabel = upgradeLabel,
	}
end

-- The upgrade board shows the next treadmill tier and its price.
local function refreshTreadmillSign(plot: PlotInfo)
	local tiers = Config.Treadmill.Tiers
	local nextTier = tiers[plot.TreadmillTier + 1]
	local prompt = plot.UpgradeSign:FindFirstChild("UpgradePrompt")
	if nextTier then
		plot.UpgradeLabel.Text = `⬆ NEXT TREADMILL\n{nextTier.Name}  +{Format.short(nextTier.Gain)}/s\n${Format.short(nextTier.Price)}`
	else
		plot.UpgradeLabel.Text = "🏆 BEST TREADMILL!\nYou have them all"
	end
	if prompt and prompt:IsA("ProximityPrompt") then
		prompt.ObjectText = if nextTier then `{nextTier.Name}  ${Format.short(nextTier.Price)}` else "Max tier"
	end
end

---------------------------------------------------------------------------
-- Ownership
---------------------------------------------------------------------------

-- Updates the sign text and floor brightness to match the owner.
local function refreshLooks(plot: PlotInfo)
	local text = if plot.Owner
		then `{plot.Owner.DisplayName}'s Aquarium`
		else `Empty Plot #{plot.Index}`
	for _, label in plot.SignLabels do
		label.Text = text
	end
	local baseColor = Config.Plots.Colors[(plot.Index - 1) % #Config.Plots.Colors + 1]
	local floor = plot.Model.PrimaryPart
	if floor then
		-- Free plots look faded and grey.
		floor.Color = if plot.Owner then baseColor else baseColor:Lerp(Color3.fromRGB(120, 120, 120), 0.6)
	end
end

-- Replace the plot's treadmill with another tier from Config.Treadmill.Tiers.
-- (SpeedService stops anyone training on it first.)
function PlotService.SetTreadmillTier(plot: PlotInfo, tier: number)
	tier = math.clamp(math.floor(tier), 1, #Config.Treadmill.Tiers)
	if tier == plot.TreadmillTier then
		return
	end
	local oldModel = plot.Treadmill.Parent
	if oldModel then
		oldModel:Destroy()
	end
	plot.Treadmill = buildTreadmill(plot.TreadmillOrigin, plot.Model, tier)
	plot.TreadmillTier = tier
	refreshTreadmillSign(plot)
	PlotService.TreadmillChanged:Fire(plot)
end

-- The second floor: walkways along both sides (where its pads go) and
-- across the back, railings, pillars, and stairs up the middle. The middle
-- stays open, so you can still see the fish downstairs.
local function buildSecondFloor(plot: PlotInfo): Model
	local size = Config.Plots.Size
	local cf = plot.CFrame
	local height = Config.Plots.SecondFloorHeight
	local deckWidth = Config.Plots.SecondFloorDeckWidth
	local color = Config.Plots.Colors[(plot.Index - 1) % #Config.Plots.Colors + 1]:Lerp(Color3.new(1, 1, 1), 0.15)
	local railColor = color:Lerp(Color3.new(0, 0, 0), 0.35)
	local thickness = 1

	local model = Instance.new("Model")
	model.Name = "SecondFloor"

	local frontZ = -size.Z / 2 + 24 -- the walkways start just behind the treadmill
	local backZ = size.Z / 2
	local bridgeDepth = 12
	local bridgeFront = backZ - bridgeDepth
	local innerX = size.X / 2 - deckWidth -- inner edge of the side walkways

	local function part(name: string, partSize: Vector3, center: Vector3, partColor: Color3?)
		plotPart({
			Name = name,
			Size = partSize,
			CFrame = cf * CFrame.new(center),
			Color = partColor or color,
			Parent = model,
		})
	end

	-- Side walkways and the back bridge.
	for _, side in { -1, 1 } do
		part("Walkway", Vector3.new(deckWidth, thickness, backZ - frontZ), Vector3.new(side * (size.X / 2 - deckWidth / 2), height - thickness / 2, (frontZ + backZ) / 2))
		-- Railings: outer edge, inner edge (up to the bridge) and front end.
		part("Railing", Vector3.new(0.6, 3, backZ - frontZ), Vector3.new(side * (size.X / 2 - 0.3), height + 1.5, (frontZ + backZ) / 2), railColor)
		part("Railing", Vector3.new(0.6, 3, bridgeFront - frontZ), Vector3.new(side * innerX, height + 1.5, (frontZ + bridgeFront) / 2), railColor)
		part("Railing", Vector3.new(deckWidth, 3, 0.6), Vector3.new(side * (size.X / 2 - deckWidth / 2), height + 1.5, frontZ + 0.3), railColor)
		-- Pillars under the walkway.
		for _, z in { frontZ + 1, (frontZ + backZ) / 2, backZ - 1 } do
			part("Pillar", Vector3.new(1.5, height - thickness, 1.5), Vector3.new(side * (innerX + 1), (height - thickness) / 2, z), railColor)
		end
	end
	part("Bridge", Vector3.new(innerX * 2, thickness, bridgeDepth), Vector3.new(0, height - thickness / 2, backZ - bridgeDepth / 2))
	part("Railing", Vector3.new(size.X, 3, 0.6), Vector3.new(0, height + 1.5, backZ - 0.3), railColor)

	-- Stairs up the middle, ending at the front of the bridge (with railings
	-- on the bridge's front edge on both sides of the stairs).
	local stairWidth = 8
	local steps = math.ceil(height)
	local run = 2
	for step = 1, steps do
		local top = math.min(step, height)
		local z = bridgeFront - (steps - step + 0.5) * run
		part("Stair", Vector3.new(stairWidth, top, run), Vector3.new(0, top / 2, z), railColor:Lerp(color, 0.5))
	end
	for _, side in { -1, 1 } do
		local half = (innerX - stairWidth / 2)
		part("Railing", Vector3.new(half, 3, 0.6), Vector3.new(side * (stairWidth / 2 + half / 2), height + 1.5, bridgeFront + 0.3), railColor)
	end

	model.Parent = plot.Model
	return model
end

-- Little "build" effect: everyone nearby sees a sparkle burst there.
local function buildEffect(position: Vector3)
	Net.event(Net.Names.PlotUpgraded):FireAllClients(position)
end

-- The plot's upgrade board shows its level and what the next upgrade gives.
local function refreshPlotSign(plot: PlotInfo)
	local level = plot.Level
	local price = Config.NextPlotPrice(level)
	local prompt = plot.PlotSign:FindFirstChild("PlotPrompt")
	local text
	if not price then
		text = `🏠 PLOT LEVEL {level}\nMAX`
	elseif level + 1 == Config.Upgrades.SecondFloorLevel then
		text = `🏠 PLOT LEVEL {level}\n🏗 BUILD 2ND FLOOR\n${Format.short(price)}`
	else
		text = `🏠 PLOT LEVEL {level}\n+1 PAD\n${Format.short(price)}`
	end
	plot.PlotSignLabel.Text = text
	if prompt and prompt:IsA("ProximityPrompt") then
		prompt.ObjectText = if price then `${Format.short(price)}` else "MAX"
	end
end

-- Set a plot's level: shows the unlocked pads (hides the rest) and builds or
-- removes the second floor. animate = true plays the build effects (an
-- upgrade was just bought).
function PlotService.SetPlotLevel(plot: PlotInfo, level: number, animate: boolean?)
	level = math.clamp(math.floor(level), 0, Config.MaxPlotLevel())
	plot.Level = level
	local count = Config.PadsAtPlotLevel(level)
	local before = plot.UnlockedPads
	plot.UnlockedPads = count

	-- Second floor.
	local wantFloor = Config.HasSecondFloor(level)
	if wantFloor and not plot.SecondFloor then
		plot.SecondFloor = buildSecondFloor(plot)
		if animate then
			buildEffect((plot.CFrame * CFrame.new(0, Config.Plots.SecondFloorHeight, Config.Plots.Size.Z / 2 - 6)).Position)
		end
	elseif not wantFloor and plot.SecondFloor then
		(plot.SecondFloor :: Model):Destroy()
		plot.SecondFloor = nil
	end

	-- Pads: unlocked ones are in the world, locked ones are hidden.
	local folder = plot.Model:FindFirstChild("Pads")
	for padIndex, pad in plot.Pads do
		local unlocked = padIndex <= count
		if unlocked and pad.Parent == nil then
			pad.Parent = folder
			if animate and padIndex > before then
				-- The new pad rises out of the floor with a sparkle.
				local target = pad.CFrame
				pad.CFrame = target * CFrame.new(0, -1.5, 0)
				TweenService:Create(pad, TweenInfo.new(0.6, Enum.EasingStyle.Back, Enum.EasingDirection.Out), { CFrame = target }):Play()
				buildEffect(target.Position)
			end
		elseif not unlocked and pad.Parent then
			pad.Parent = nil
		end
	end
	refreshPlotSign(plot)
end

local function spawnCFrame(plot: PlotInfo): CFrame
	-- Stand on the spawn pad, facing the danger zone (the plot's front).
	return plot.Spawn.CFrame * CFrame.new(0, 3.5, 0)
end

-- Make sure a freshly spawned character is standing on its own plot.
local function onCharacterAdded(player: Player, character: Model)
	local plot = plotByPlayer[player]
	if not plot then
		return
	end
	local root = character:WaitForChild("HumanoidRootPart", 10)
	if not (root and root:IsA("BasePart")) then
		return
	end
	-- Wait one frame so Roblox finishes its own spawn placement first.
	task.wait()
	if character.Parent and (root.Position - plot.Spawn.Position).Magnitude > 12 then
		character:PivotTo(spawnCFrame(plot))
	end
end

local function assignPlot(player: Player)
	if plotByPlayer[player] then
		return
	end
	local freePlot: PlotInfo? = nil
	for _, plot in plots do
		if plot.Owner == nil then
			freePlot = plot
			break
		end
	end
	if not freePlot then
		-- More players than plots. Set the server size to Config.Plots.Count
		-- in Game Settings so this never happens.
		player:Kick("Sorry, this server is full! Please join a different server.")
		return
	end

	local plot = freePlot
	plot.Owner = player
	plotByPlayer[player] = plot
	plot.Model:SetAttribute("OwnerUserId", player.UserId)
	local upgradePrompt = plot.UpgradeSign:FindFirstChild("UpgradePrompt") :: ProximityPrompt
	upgradePrompt:SetAttribute(Constants.Attributes.OwnerUserId, player.UserId)
	local plotPrompt = plot.PlotSign:FindFirstChild("PlotPrompt") :: ProximityPrompt
	plotPrompt:SetAttribute(Constants.Attributes.OwnerUserId, player.UserId)
	PlotService.SetPlotLevel(plot, 0)
	refreshLooks(plot)

	-- Spawn the player on this plot from now on.
	player.RespawnLocation = plot.Spawn
	player.CharacterAdded:Connect(function(character)
		onCharacterAdded(player, character)
	end)
	if player.Character then
		task.spawn(onCharacterAdded, player, player.Character)
	end

	if Config.Debug then
		print(`[{Config.GameName}] {player.Name} got Plot {plot.Index}`)
	end
	Notify.send(player, `Your aquarium is Plot #{plot.Index}!`)
	PlotService.PlotAssigned:Fire(player, plot)
end

local function releasePlot(player: Player)
	local plot = plotByPlayer[player]
	if not plot then
		return
	end
	plotByPlayer[player] = nil
	plot.Owner = nil
	plot.Model:SetAttribute("OwnerUserId", 0)
	local upgradePrompt = plot.UpgradeSign:FindFirstChild("UpgradePrompt") :: ProximityPrompt
	upgradePrompt:SetAttribute(Constants.Attributes.OwnerUserId, 0)
	local plotPrompt = plot.PlotSign:FindFirstChild("PlotPrompt") :: ProximityPrompt
	plotPrompt:SetAttribute(Constants.Attributes.OwnerUserId, 0)
	PlotService.SetPlotLevel(plot, 0)
	PlotService.SetTreadmillTier(plot, 1)
	refreshLooks(plot)

	if Config.Debug then
		print(`[{Config.GameName}] Plot {plot.Index} is free again`)
	end
	PlotService.PlotReleased:Fire(player, plot)
end

---------------------------------------------------------------------------
-- Public queries
---------------------------------------------------------------------------

function PlotService.GetPlot(player: Player): PlotInfo?
	return plotByPlayer[player]
end

function PlotService.GetPlots(): { PlotInfo }
	return plots
end

function PlotService.GetPlotAt(position: Vector3): PlotInfo?
	for _, plot in plots do
		if Layout.isInsidePlot(plot.Index, position) then
			return plot
		end
	end
	return nil
end

function PlotService.IsInsideAnyPlot(position: Vector3): boolean
	return PlotService.GetPlotAt(position) ~= nil
end

---------------------------------------------------------------------------
-- Lifecycle
---------------------------------------------------------------------------

function PlotService.Init()
end

function PlotService.Start()
	local folder = Instance.new("Folder")
	folder.Name = "Plots"
	folder.Parent = WorldService.GetFolder()

	for index = 1, Config.Plots.Count do
		local plot = buildPlot(index, folder)
		table.insert(plots, plot)
		refreshTreadmillSign(plot)
		local upgradePrompt = plot.UpgradeSign:FindFirstChild("UpgradePrompt") :: ProximityPrompt
		CollectionService:AddTag(upgradePrompt, Constants.Tags.PetPrompt)
		upgradePrompt.Triggered:Connect(function(player: Player)
			PlotService.UpgradePromptTriggered:Fire(player, plot, "Treadmill")
		end)
		local plotPrompt = plot.PlotSign:FindFirstChild("PlotPrompt") :: ProximityPrompt
		CollectionService:AddTag(plotPrompt, Constants.Tags.PetPrompt)
		plotPrompt.Triggered:Connect(function(player: Player)
			PlotService.UpgradePromptTriggered:Fire(player, plot, "Plot")
		end)
		PlotService.SetPlotLevel(plot, 0)
		refreshLooks(plot)
	end

	Players.PlayerAdded:Connect(assignPlot)
	PlayerLifecycle.onLeave(releasePlot)
	-- In Studio, you may have joined before this code ran.
	for _, player in Players:GetPlayers() do
		task.spawn(assignPlot, player)
	end
end

return PlotService
