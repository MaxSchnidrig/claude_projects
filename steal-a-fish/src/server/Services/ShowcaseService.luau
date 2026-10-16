--!strict
--[[
	ShowcaseService
	===============
	Studio-only preview commands, to look at the models without having to
	hatch or find them. Everything appears in a row on YOUR plot, with a name
	label, and disappears after SHOW_SECONDS (3 minutes) (or when you use
	another show command). Nothing here exists in the real game.

	Commands (type in chat while play-testing in Studio):
		!showfish 3     all 8 fish of zone 3
		!showeggs       one egg of each rarity (each from the zone where it's most common)
		!showeggs 7     one egg of each rarity, all from zone 7 (to see the zone detail)
		!showsharks     all 10 sharks (two rows of 5)
		!showclear      remove the preview

	Public interface: none (debug only).
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = require(ReplicatedStorage.Shared.Config)
local Fish = require(ReplicatedStorage.Shared.Fish)
local Format = require(ReplicatedStorage.Shared.Format)
local Rarity = require(ReplicatedStorage.Shared.Rarity)
local Build = require(script.Parent.Parent.Util.Build)
local DebugCommands = require(script.Parent.Parent.Util.DebugCommands)
local Notify = require(script.Parent.Parent.Util.Notify)
local PlayerLifecycle = require(script.Parent.Parent.Util.PlayerLifecycle)
local EggModel = require(script.Parent.Parent.Util.Models.EggModel)
local FishModel = require(script.Parent.Parent.Util.Models.FishModel)
local SharkModel = require(script.Parent.Parent.Util.Models.SharkModel)
local PlotService = require(script.Parent.PlotService)
local WorldService = require(script.Parent.WorldService)

local ShowcaseService = {}
ShowcaseService.Name = "ShowcaseService"

local SHOW_SECONDS = 180

local showcases: { [Player]: Folder } = {}

local function clear(player: Player)
	local folder = showcases[player]
	if folder then
		folder:Destroy()
		showcases[player] = nil
	end
end

-- A fresh folder for this player's preview (removed after SHOW_SECONDS).
local function newShowcase(player: Player): Folder
	clear(player)
	local folder = Instance.new("Folder")
	folder.Name = `Showcase_{player.Name}`
	folder.Parent = WorldService.GetFolder()
	showcases[player] = folder
	task.delay(SHOW_SECONDS, function()
		if showcases[player] == folder then
			clear(player)
		end
	end)
	return folder
end

-- A spot on the player's plot: x across the plot, z from front (-) to back (+),
-- facing the front (toward the danger zone, where you usually come from).
local function plotSpot(player: Player, x: number, height: number, z: number): CFrame?
	local plot = PlotService.GetPlot(player)
	if not plot then
		Notify.send(player, "[Studio] You need a plot first.", "warning")
		return nil
	end
	return plot.CFrame * CFrame.new(x, height, z)
end

local function label(part: BasePart, text: string, color: Color3, height: number)
	local textLabel = Build.billboard(part, text, height, 90)
	textLabel.TextColor3 = color
end

local function showFish(player: Player, args: { string })
	local zoneIndex = math.clamp(math.floor(tonumber(args[1]) or 1), 1, #Config.Zones)
	local list = Fish.inZone(zoneIndex)
	local spacing = 6.5
	local folder = newShowcase(player)
	for index, fish in list do
		local x = (index - (#list + 1) / 2) * spacing
		local spot = plotSpot(player, x, 0, 4)
		if not spot then
			return
		end
		local model = FishModel.create(fish, spot)
		local bottom = model:GetAttribute("Bottom")
		local top = model:GetAttribute("Top")
		model:PivotTo(spot + Vector3.new(0, 1 + (if typeof(bottom) == "number" then bottom else 1), 0))
		label(model.PrimaryPart :: BasePart, `{fish.Name}\n{fish.Rarity} • ${Format.short(fish.Income)}/s`, Rarity.color(fish.Rarity), (if typeof(top) == "number" then top else 1) + 1.6)
		model.Parent = folder
	end
	Notify.send(player, `[Studio] Showing the 8 fish of zone {zoneIndex} ({Config.Zones[zoneIndex].Name}) on your plot.`, "info")
end

local function showEggs(player: Player, args: { string })
	local forcedZone = tonumber(args[1])
	local folder = newShowcase(player)
	local count = #Config.Rarities
	for index, info in Config.Rarities do
		local zoneIndex = if forcedZone then math.clamp(math.floor(forcedZone), 1, #Config.Zones) else Fish.likelyZone(info.Name)
		local spot = plotSpot(player, (index - (count + 1) / 2) * 4.4, Config.Eggs.Size.Y / 2 + 0.5, 4)
		if not spot then
			return
		end
		local egg = EggModel.create(info.Name, zoneIndex, true)
		egg.CFrame = spot
		label(egg, `{info.Name}\n{Config.Zones[zoneIndex].Name}`, info.Color, Config.Eggs.Size.Y / 2 + 1.2)
		egg.Parent = folder
	end
	Notify.send(player, "[Studio] Showing one egg of each rarity on your plot.", "info")
end

local function showSharks(player: Player, _args: { string })
	local folder = newShowcase(player)
	for zoneIndex, look in Config.Sharks do
		-- Two rows of 5: shallow sharks in front, deep sharks behind.
		local row = if zoneIndex <= 5 then 0 else 1
		local column = (zoneIndex - 1) % 5
		local height = 1 + 1.6 * look.Scale
		local spot = plotSpot(player, (column - 2) * 11, height, if row == 0 then -16 else 14)
		if not spot then
			return
		end
		local model = Instance.new("Model")
		model.Name = `Shark{zoneIndex}`
		local root = Instance.new("Part")
		root.Name = "SharkRoot"
		root.Size = Vector3.new(3, 3, 9) * look.Scale
		root.Transparency = 1
		root.Anchored = true
		root.CanCollide = false
		root.CanQuery = false
		root.CanTouch = false
		root.CFrame = spot
		root.Parent = model
		model.PrimaryPart = root
		SharkModel.build(model, root, zoneIndex)
		label(root, `Zone {zoneIndex}: {Config.Zones[zoneIndex].Name}\nSpeed {look.Speed}`, Color3.fromRGB(255, 120, 120), 3.5 * look.Scale)
		model.Parent = folder
	end
	Notify.send(player, "[Studio] Showing all 10 sharks on your plot.", "info")
end

function ShowcaseService.Init()
end

function ShowcaseService.Start()
	DebugCommands.register("showfish", showFish)
	DebugCommands.register("showeggs", showEggs)
	DebugCommands.register("showsharks", showSharks)
	DebugCommands.register("showclear", function(player, _args)
		clear(player)
	end)
	PlayerLifecycle.onLeave(clear)
end

return ShowcaseService
