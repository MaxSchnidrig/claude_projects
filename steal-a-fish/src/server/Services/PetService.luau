--!strict
--[[
	PetService
	==========
	Owns everything that happens on a plot after an egg is delivered: eggs
	sitting on the hatch pad, hatching them into pets (Milestone 4), placing
	pets on pedestals, and selling pets.

	Milestone 2 part: the hatch pad holds up to Config.Eggs.MaxEggsOnPad
	delivered eggs. They just sit there until hatching arrives in Milestone 4.

	Public interface:
		PetService.AcceptEgg(player, rarity) -> boolean
			Puts a delivered egg on the player's hatch pad. Returns false if
			the pad is full (the player keeps carrying the egg).
		PetService.GetPadEggCount(player) -> number
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = require(ReplicatedStorage.Shared.Config)
local Types = require(ReplicatedStorage.Shared.Types)
local Build = require(script.Parent.Parent.Util.Build)
local EggVisual = require(script.Parent.Parent.Util.EggVisual)
local PlotService = require(script.Parent.PlotService)

type PadEgg = {
	Rarity: string,
	Part: BasePart,
}

local PetService = {}
PetService.Name = "PetService"

-- Eggs on each plot's hatch pad, by plot index.
local padEggs: { [number]: { PadEgg } } = {}

-- Where egg number `spot` sits on the pad (eggs stand side by side).
local function padSpotCFrame(plot: Types.PlotInfo, spot: number): CFrame
	local pad = plot.HatchPad
	local padTop = pad.Position.Y + pad.Size.X / 2 -- an upright cylinder's height is its X size
	local count = Config.Eggs.MaxEggsOnPad
	local spacing = math.min(3.2, (pad.Size.Y - 2) / math.max(count, 1))
	local x = (spot - (count + 1) / 2) * spacing
	-- Eggs sit partly sunk into the pad, like the ones in the sand.
	local centerY = padTop + Config.Eggs.Size.Y * (Config.Eggs.VisibleFraction - 0.5)
	local base = CFrame.new(pad.Position.X, centerY, pad.Position.Z) * plot.CFrame.Rotation
	return base * CFrame.new(x, 0, 0)
end

function PetService.GetPadEggCount(player: Player): number
	local plot = PlotService.GetPlot(player)
	if not plot then
		return 0
	end
	local list = padEggs[plot.Index]
	return if list then #list else 0
end

function PetService.AcceptEgg(player: Player, rarity: string): boolean
	local plot = PlotService.GetPlot(player)
	if not plot then
		return false
	end
	local list = padEggs[plot.Index]
	if not list then
		list = {}
		padEggs[plot.Index] = list
	end
	if #list >= Config.Eggs.MaxEggsOnPad then
		return false
	end

	-- Find the first empty spot on the pad.
	local used: { [number]: boolean } = {}
	for _, egg in list do
		used[egg.Part:GetAttribute("PadSpot") :: number] = true
	end
	local spot = 1
	while used[spot] do
		spot += 1
	end

	local part = EggVisual.create(rarity, true)
	part.CFrame = padSpotCFrame(plot, spot)
	part:SetAttribute("PadSpot", spot)
	Build.billboard(part, `{rarity} Egg`, 2.5, 40)
	part.Parent = plot.Model

	local padEgg: PadEgg = { Rarity = rarity, Part = part }
	table.insert(list, padEgg)
	return true
end

-- Remove every egg from a plot's pad (when its owner leaves).
local function clearPad(plotIndex: number)
	local list = padEggs[plotIndex]
	if list then
		for _, egg in list do
			egg.Part:Destroy()
		end
	end
	padEggs[plotIndex] = nil
end

function PetService.Init()
end

function PetService.Start()
	PlotService.PlotReleased:Connect(function(_player: Player, plot: Types.PlotInfo)
		clearPad(plot.Index)
	end)
end

return PetService
