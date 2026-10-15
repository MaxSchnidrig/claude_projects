--!strict
--[[
	PetService
	==========
	Owns what sits on a plot's PADS. Each pad holds exactly ONE item:
	  - an "Egg" (delivered by the player, waiting to hatch), or
	  - a "Pet" (what hatched from that egg; it stays on the same pad and
	    earns money until it is sold).
	So pads are egg slots and pet slots at the same time.

	Right now (before the hatching milestone) eggs just sit on their pads.
	The hatching milestone will turn an Egg item into a Pet item on the SAME
	pad, the money milestone pays out per pet, and selling a pet frees its pad.

	Public interface:
		PetService.AcceptEgg(player, rarity, nearPosition) -> boolean
			Puts a delivered egg on the FREE unlocked pad closest to
			nearPosition. Returns false if every pad is taken (the player keeps
			carrying the egg).
		PetService.GetFreePadCount(player) -> number
		PetService.GetPadItem(plot, padIndex) -> PadItem?
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = require(ReplicatedStorage.Shared.Config)
local Types = require(ReplicatedStorage.Shared.Types)
local Build = require(script.Parent.Parent.Util.Build)
local EggVisual = require(script.Parent.Parent.Util.EggVisual)
local PlotService = require(script.Parent.PlotService)

-- What sits on one pad.
export type PadItem = {
	Kind: "Egg" | "Pet",
	Rarity: string,
	PetName: string?, -- only for pets (hatching milestone)
	Part: BasePart, -- the 3D egg or pet
}

local PetService = {}
PetService.Name = "PetService"

-- padItems[plotIndex][padIndex] = what's on that pad (nil = free).
local padItems: { [number]: { [number]: PadItem } } = {}

local function getItems(plot: Types.PlotInfo): { [number]: PadItem }
	local items = padItems[plot.Index]
	if not items then
		items = {}
		padItems[plot.Index] = items
	end
	return items
end

-- Where an egg sits on a pad: centered, half sunk into it.
local function eggCFrameOnPad(pad: BasePart): CFrame
	local padTop = pad.Position.Y + pad.Size.Y / 2
	local centerY = padTop + Config.Eggs.Size.Y * (Config.Eggs.VisibleFraction - 0.5)
	return CFrame.new(pad.Position.X, centerY, pad.Position.Z) * pad.CFrame.Rotation
end

function PetService.GetPadItem(plot: Types.PlotInfo, padIndex: number): PadItem?
	return getItems(plot)[padIndex]
end

function PetService.GetFreePadCount(player: Player): number
	local plot = PlotService.GetPlot(player)
	if not plot then
		return 0
	end
	local items = getItems(plot)
	local free = 0
	for padIndex = 1, plot.UnlockedPads do
		if not items[padIndex] then
			free += 1
		end
	end
	return free
end

function PetService.AcceptEgg(player: Player, rarity: string, nearPosition: Vector3): boolean
	local plot = PlotService.GetPlot(player)
	if not plot then
		return false
	end
	local items = getItems(plot)

	-- The closest free unlocked pad.
	local bestIndex: number? = nil
	local bestDistance = math.huge
	for padIndex = 1, plot.UnlockedPads do
		if not items[padIndex] then
			local distance = (plot.Pads[padIndex].Position - nearPosition).Magnitude
			if distance < bestDistance then
				bestIndex = padIndex
				bestDistance = distance
			end
		end
	end
	if not bestIndex then
		return false
	end

	local pad = plot.Pads[bestIndex]
	local part = EggVisual.create(rarity, true)
	part.CFrame = eggCFrameOnPad(pad)
	part:SetAttribute("PadIndex", bestIndex)
	Build.billboard(part, `{rarity} Egg`, 2.5, 40)
	part.Parent = plot.Model

	items[bestIndex] = { Kind = "Egg", Rarity = rarity, PetName = nil, Part = part }
	return true
end

-- Remove everything from a plot's pads (when its owner leaves).
local function clearPads(plotIndex: number)
	local items = padItems[plotIndex]
	if items then
		for _, item in items do
			item.Part:Destroy()
		end
	end
	padItems[plotIndex] = nil
end

function PetService.Init()
end

function PetService.Start()
	PlotService.PlotReleased:Connect(function(_player: Player, plot: Types.PlotInfo)
		clearPads(plot.Index)
	end)
end

return PetService
