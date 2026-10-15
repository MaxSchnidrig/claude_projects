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
	  - HatchPad: deliver eggs here (Milestone 2)
	  - Treadmill: train Speed here (Milestone 5)
	  - PetSlots: pedestals for pets (Milestone 4). All Config.Plots.MaxPetSlots
	    pedestals are built, but only the unlocked ones are shown.

	Plots are SAFE ZONES: bots stay in the danger zone (see WorldService), and
	other services can ask PlotService.IsInsideAnyPlot(position).

	Public interface:
		PlotService.GetPlot(player) -> PlotInfo?          -- the player's plot
		PlotService.GetPlots() -> { PlotInfo }             -- all plots
		PlotService.GetPlotAt(position) -> PlotInfo?       -- plot containing a point
		PlotService.IsInsideAnyPlot(position) -> boolean
		PlotService.SetUnlockedSlots(plot, count)          -- show/hide pedestals
		PlotService.PlotAssigned:Connect(function(player, plot) end)
		PlotService.PlotReleased:Connect(function(player, plot) end)
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = require(ReplicatedStorage.Shared.Config)
local Layout = require(ReplicatedStorage.Shared.Layout)
local Net = require(ReplicatedStorage.Shared.Net)
local Signal = require(ReplicatedStorage.Shared.Signal)
local Types = require(ReplicatedStorage.Shared.Types)
local Assets = require(script.Parent.Parent.Util.Assets)
local Build = require(script.Parent.Parent.Util.Build)
local WorldService = require(script.Parent.WorldService)

type PlotInfo = Types.PlotInfo

local PlotService = {}
PlotService.Name = "PlotService"

-- Fired with (player, plot) when a player gets a plot / gives it up.
PlotService.PlotAssigned = Signal.new()
PlotService.PlotReleased = Signal.new()

local plots: { PlotInfo } = {}
local plotByPlayer: { [Player]: PlotInfo } = {}

---------------------------------------------------------------------------
-- Building
---------------------------------------------------------------------------

-- Where pet pedestal number `slotIndex` goes, relative to the plot center.
-- Pedestals fill the back half of the plot in rows of 4.
local SLOT_COLUMNS = 4
local function slotOffset(slotIndex: number): Vector3
	local size = Config.Plots.Size
	local rows = math.ceil(Config.Plots.MaxPetSlots / SLOT_COLUMNS)
	local column = (slotIndex - 1) % SLOT_COLUMNS
	local row = math.floor((slotIndex - 1) / SLOT_COLUMNS)
	local spacingX = (size.X - 10) / SLOT_COLUMNS
	local backHalfDepth = size.Z / 2 - 6
	local spacingZ = backHalfDepth / rows
	local x = -size.X / 2 + 5 + spacingX * (column + 0.5)
	local z = 4 + spacingZ * (row + 0.5)
	return Vector3.new(x, 0, z)
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
		Parent = model,
	})
	Assets.decorate(board, "PlotSign")
	-- "Front" faces the beach; "Back" faces into the plot.
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

	-- Hatch pad in the middle front.
	local hatchPad = Build.cylinder({
		Name = "HatchPad",
		Size = Vector3.new(10, 0.6, 10),
		CFrame = cf * CFrame.new(0, 0.3, -14),
		Color = Color3.fromRGB(255, 230, 90),
		Material = Enum.Material.Neon,
		Parent = model,
	})
	Assets.decorate(hatchPad, "HatchPad")
	Build.billboard(hatchPad, "🥚 Hatch Pad", 4, 60)

	-- Treadmill on the right side.
	local treadmill = Build.part({
		Name = "Treadmill",
		Size = Vector3.new(8, 0.6, 24),
		CFrame = cf * CFrame.new(size.X / 2 - 8, 0.3, -12),
		Color = Color3.fromRGB(45, 45, 50),
		Parent = model,
	})
	-- Neon side stripes so it's easy to spot (hidden if a custom model is used).
	local treadmillModel = Assets.decorate(treadmill, "Treadmill")
	for _, side in { -1, 1 } do
		Build.part({
			Name = "TreadmillStripe",
			Size = Vector3.new(0.6, 0.7, 24),
			CFrame = treadmill.CFrame * CFrame.new(side * 4.3, 0, 0),
			Color = Color3.fromRGB(80, 255, 140),
			Material = Enum.Material.Neon,
			Transparency = if treadmillModel then 1 else 0,
			CanCollide = false,
			CanTouch = false,
			Parent = treadmill,
		})
	end
	Build.billboard(treadmill, "🏃 Treadmill", 4, 60)

	-- Pet pedestals in the back half.
	local slotsFolder = Instance.new("Folder")
	slotsFolder.Name = "PetSlots"
	slotsFolder.Parent = model
	local slots: { BasePart } = {}
	for slotIndex = 1, Config.Plots.MaxPetSlots do
		local slot = Build.cylinder({
			Name = `Slot{slotIndex}`,
			Size = Vector3.new(6, 2, 6),
			CFrame = cf * CFrame.new(slotOffset(slotIndex)) * CFrame.new(0, 1, 0),
			Color = Color3.fromRGB(230, 230, 240),
			Material = Enum.Material.Marble,
			Parent = slotsFolder,
		})
		slot:SetAttribute("SlotIndex", slotIndex)
		Assets.decorate(slot, "PetSlot")
		table.insert(slots, slot)
	end

	model.Parent = parent

	return {
		Index = index,
		Model = model,
		Owner = nil,
		CFrame = cf,
		Spawn = spawn,
		HatchPad = hatchPad,
		Treadmill = treadmill,
		Slots = slots,
		UnlockedSlots = #slots,
		SignLabels = signLabels,
	}
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

-- Show the first `count` pedestals and hide the rest.
function PlotService.SetUnlockedSlots(plot: PlotInfo, count: number)
	count = math.clamp(count, 0, #plot.Slots)
	plot.UnlockedSlots = count
	local folder = plot.Model:FindFirstChild("PetSlots")
	for slotIndex, slot in plot.Slots do
		-- Hidden pedestals are simply taken out of the world (parent = nil).
		slot.Parent = if slotIndex <= count then folder else nil
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
	PlotService.SetUnlockedSlots(plot, Config.Plots.StartingPetSlots)
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
	Net.event(Net.Names.Notify):FireClient(player, `Your aquarium is Plot #{plot.Index}!`)
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
	PlotService.SetUnlockedSlots(plot, Config.Plots.StartingPetSlots)
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
		PlotService.SetUnlockedSlots(plot, Config.Plots.StartingPetSlots)
		refreshLooks(plot)
	end

	Players.PlayerAdded:Connect(assignPlot)
	Players.PlayerRemoving:Connect(releasePlot)
	-- In Studio, you may have joined before this code ran.
	for _, player in Players:GetPlayers() do
		task.spawn(assignPlot, player)
	end
end

return PlotService
