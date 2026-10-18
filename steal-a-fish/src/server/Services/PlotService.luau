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
	    Locked pads are see-through and show their price ("🔒 $1.2K"); the
	    NEXT locked pad has an "Unlock Pad" prompt (only its owner sees it).
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
		PlotService.SetUnlockedPads(plot, count)           -- show/hide pads
		PlotService.SetTreadmillTier(plot, tier)           -- rebuild the treadmill as another tier
		PlotService.TreadmillChanged:Connect(function(plot) end)
		PlotService.PlotAssigned:Connect(function(player, plot) end)
		PlotService.PlotReleased:Connect(function(player, plot) end)
		PlotService.UpgradePromptTriggered:Connect(function(player, plot, "Pad" | "Treadmill") end)
]]

local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
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
-- Fired with (player, plot, "Pad" or "Treadmill") when an upgrade prompt is used.
PlotService.UpgradePromptTriggered = Signal.new()

local LOCKED_PAD_COLOR = Color3.fromRGB(90, 90, 100)

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

	local floor = Build.part({
		Name = "Floor",
		Size = size,
		CFrame = cf * CFrame.new(0, -size.Y / 2, 0),
		Color = color,
		StudFaces = { Enum.NormalId.Top },
		Parent = model,
	})
	model.PrimaryPart = floor

	-- Low rails on the left, right and back. The front stays open.
	local railColor = color:Lerp(Color3.new(0, 0, 0), 0.35)
	for _, side in { -1, 1 } do
		Build.part({
			Name = "Rail",
			Size = Vector3.new(1, 2, size.Z),
			CFrame = cf * CFrame.new(side * (size.X / 2 - 0.5), 1, 0),
			Color = railColor,
			Parent = model,
		})
	end
	Build.part({
		Name = "Rail",
		Size = Vector3.new(size.X, 2, 1),
		CFrame = cf * CFrame.new(0, 1, size.Z / 2 - 0.5),
		Color = railColor,
		Parent = model,
	})

	-- Sign gate at the front: two posts with a board across the top.
	local frontZ = -size.Z / 2 + 1
	for _, side in { -1, 1 } do
		Build.part({
			Name = "SignPost",
			Size = Vector3.new(1.5, 12, 1.5),
			CFrame = cf * CFrame.new(side * 14, 6, frontZ),
			Color = railColor,
			Parent = model,
		})
	end
	local board = Build.part({
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
	Build.part({
		Name = "UpgradePost",
		Size = Vector3.new(1, 3, 1),
		CFrame = boardCFrame * CFrame.new(0, 1.5, 0),
		Color = railColor,
		Parent = model,
	})
	local upgradeSign = Build.part({
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
	local collectPad = Build.part({
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
	for padIndex = 1, Config.Plots.PadsPerSide * 2 do
		local pad = Build.part({
			Name = `Pad{padIndex}`,
			Size = Vector3.new(padSize.Z, padSize.Y, padSize.X),
			CFrame = cf * padCFrame(padIndex),
			Color = Config.Plots.PadColor,
			Parent = padsFolder,
		})
		pad:SetAttribute("PadIndex", padIndex)
		Assets.decorate(pad, "Pad")
		table.insert(pads, pad)
	end

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
		UnlockedPads = #pads,
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

-- Price of locked pad number `padIndex` (pads are unlocked in order).
function PlotService.PadPrice(padIndex: number): number
	local bought = padIndex - Config.Plots.StartingPads - 1
	return Config.UpgradePrice(Config.Upgrades.Pads.Base, Config.Upgrades.Pads.Growth, math.max(bought, 0))
end

-- The first `count` pads are unlocked. Locked pads are see-through with
-- their price; the next one gets an "Unlock Pad" prompt for the owner.
function PlotService.SetUnlockedPads(plot: PlotInfo, count: number)
	count = math.clamp(count, 0, #plot.Pads)
	plot.UnlockedPads = count
	for padIndex, pad in plot.Pads do
		local locked = padIndex > count
		pad:SetAttribute("Locked", locked)
		pad.Color = if locked then LOCKED_PAD_COLOR else Config.Plots.PadColor
		pad.Transparency = if locked then 0.55 else 0
		local oldLabel = pad:FindFirstChild("Label")
		if oldLabel then
			oldLabel:Destroy()
		end
		local oldPrompt = pad:FindFirstChild("UnlockPrompt")
		if oldPrompt then
			oldPrompt:Destroy()
		end
		if locked then
			local label = Build.billboard(pad, `🔒 ${Format.short(PlotService.PadPrice(padIndex))}`, 2.5, 50)
			label.TextColor3 = Color3.fromRGB(255, 220, 90)
			if padIndex == count + 1 and plot.Owner then
				local prompt = Instance.new("ProximityPrompt")
				prompt.Name = "UnlockPrompt"
				prompt.ActionText = "Unlock Pad"
				prompt.ObjectText = `${Format.short(PlotService.PadPrice(padIndex))}`
				prompt.HoldDuration = 0.3
				prompt.MaxActivationDistance = 8
				prompt.RequiresLineOfSight = false
				-- Same tag as pet prompts: only the owner sees it.
				prompt:SetAttribute(Constants.Attributes.OwnerUserId, plot.Owner.UserId)
				prompt.Parent = pad
				CollectionService:AddTag(prompt, Constants.Tags.PetPrompt)
				prompt.Triggered:Connect(function(player: Player)
					PlotService.UpgradePromptTriggered:Fire(player, plot, "Pad")
				end)
			end
		end
	end
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
	PlotService.SetUnlockedPads(plot, Config.Plots.StartingPads)
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
	PlotService.SetUnlockedPads(plot, Config.Plots.StartingPads)
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
		PlotService.SetUnlockedPads(plot, Config.Plots.StartingPads)
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
