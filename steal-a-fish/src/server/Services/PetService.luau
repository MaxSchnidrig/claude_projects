--!strict
--[[
	PetService
	==========
	Owns what sits on a plot's PADS. Each pad holds exactly ONE item:
	  - an "Egg": delivered by the player, counting down to hatch, or
	  - a "Pet": what hatched from that egg. It appears on the SAME pad, stays
	    there and earns money (EconomyService pays it out) until it is sold.
	So pads are egg slots and pet slots at the same time.

	Hatching:
	  - Hatch time = Config.Eggs.ByRarity[rarity].HatchTime
	                 * Config.Eggs.HatchTimeMultiplier * the player's own
	                 hatch multiplier (for a "Faster Hatching" pass later).
	  - The countdown is shown above the egg (the client draws it from the
	    egg's HatchEndsAt attribute).
	  - The pet's rarity is rolled with Config.HatchOdds[eggRarity]; then one
	    pet of that rarity is picked at random (all equally likely).
	  - Everyone sees a burst effect; the owner gets a "You hatched ...!" card;
	    rare hatches are announced to the whole server.

	Pets are NOT saved yet (that's the Saving milestone).

	Studio-only test commands:
		!hatch          hatch all your eggs right now
		!egg mythic     put a Mythic egg on your nearest free pad

	Public interface:
		PetService.AcceptEgg(player, rarity, nearPosition) -> boolean
		PetService.GetFreePadCount(player) -> number
		PetService.GetPadItem(plot, padIndex) -> PadItem?
		PetService.GetIncomePerSecond(player) -> number   -- all pets, before boosts
		PetService.FinishHatching(player)                 -- hatch every egg now (Instant Hatch product later)
		PetService.SetHatchTimeMultiplier(player, value)  -- e.g. 0.5 for a Faster Hatching pass
		PetService.SetPetLevel(plot, padIndex, level)     -- after a paid upgrade
		PetService.RemovePet(plot, padIndex)               -- after selling; frees the pad
		PetService.PetHatched:Connect(function(player, petName, rarity) end)
		PetService.PetPromptTriggered:Connect(function(player, plot, padIndex, action) end)
]]

local Players = game:GetService("Players")
local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local Config = require(ReplicatedStorage.Shared.Config)
local Constants = require(ReplicatedStorage.Shared.Constants)
local Format = require(ReplicatedStorage.Shared.Format)
local Net = require(ReplicatedStorage.Shared.Net)
local Rarity = require(ReplicatedStorage.Shared.Rarity)
local Signal = require(ReplicatedStorage.Shared.Signal)
local Types = require(ReplicatedStorage.Shared.Types)
local DebugCommands = require(script.Parent.Parent.Util.DebugCommands)
local EggVisual = require(script.Parent.Parent.Util.EggVisual)
local PetVisual = require(script.Parent.Parent.Util.PetVisual)
local PlotService = require(script.Parent.PlotService)

-- What sits on one pad.
export type PadItem = {
	Kind: "Egg" | "Pet",
	Rarity: string,
	PetName: string?, -- pets only
	Income: number, -- pets only: money per second at level 1 (0 for eggs)
	Level: number, -- pets only (pet upgrades come later)
	Instance: Instance, -- the egg Part or the pet Model
	HatchEndsAt: number?, -- eggs only: server time it hatches at
}

local PetService = {}
PetService.Name = "PetService"

-- Fired with (player, petName, rarity) after an egg hatches.
PetService.PetHatched = Signal.new()
-- Fired with (player, plot, padIndex, "Upgrade" or "Sell") when someone uses
-- a pet's prompt. UpgradeService checks and handles it.
PetService.PetPromptTriggered = Signal.new()

local HATCH_CHECK_INTERVAL = 0.2

local rng = Random.new()
-- padItems[plotIndex][padIndex] = what's on that pad (nil = free).
local padItems: { [number]: { [number]: PadItem } } = {}
local hatchTimeMultipliers: { [Player]: number } = {}

local function serverNow(): number
	return Workspace:GetServerTimeNow()
end

local function getItems(plot: Types.PlotInfo): { [number]: PadItem }
	local items = padItems[plot.Index]
	if not items then
		items = {}
		padItems[plot.Index] = items
	end
	return items
end

local function notifyAll(message: string)
	Net.event(Net.Names.Notify):FireAllClients(message)
end

-- A floating label with a title line and a smaller second line.
local function makeLabel(parent: BasePart, title: string, titleColor: Color3, subtitle: string, height: number): BillboardGui
	local gui = Instance.new("BillboardGui")
	gui.Name = "Label"
	gui.Size = UDim2.fromOffset(200, 56)
	gui.StudsOffsetWorldSpace = Vector3.new(0, height, 0)
	gui.MaxDistance = 60
	gui.LightInfluence = 0
	gui.Parent = parent

	local function line(name: string, text: string, color: Color3, y: number, h: number)
		local label = Instance.new("TextLabel")
		label.Name = name
		label.Position = UDim2.fromScale(0, y)
		label.Size = UDim2.fromScale(1, h)
		label.BackgroundTransparency = 1
		label.Font = Enum.Font.FredokaOne
		label.TextScaled = true
		label.TextColor3 = color
		label.TextStrokeTransparency = 0.2
		label.Text = text
		label.Parent = gui
	end
	line("Title", title, titleColor, 0, 0.55)
	line("Subtitle", subtitle, Color3.new(1, 1, 1), 0.55, 0.45)
	return gui
end

---------------------------------------------------------------------------
-- Positions on a pad
---------------------------------------------------------------------------

local function padTop(pad: BasePart): number
	return pad.Position.Y + pad.Size.Y / 2
end

-- Eggs sit centered on the pad, half sunk into it.
local function eggCFrameOnPad(pad: BasePart): CFrame
	local centerY = padTop(pad) + Config.Eggs.Size.Y * (Config.Eggs.VisibleFraction - 0.5)
	return CFrame.new(pad.Position.X, centerY, pad.Position.Z) * pad.CFrame.Rotation
end

-- Pets float above the pad, facing the middle of the plot.
local function petCFrameOnPad(pad: BasePart): CFrame
	local position = Vector3.new(pad.Position.X, padTop(pad) + Config.PetDisplay.HoverHeight, pad.Position.Z)
	return CFrame.lookAt(position, position + pad.CFrame.LookVector)
end

---------------------------------------------------------------------------
-- Eggs
---------------------------------------------------------------------------

local function hatchSeconds(player: Player, rarity: string): number
	local rarityConfig = Config.Eggs.ByRarity[rarity]
	local base = if rarityConfig then rarityConfig.HatchTime else 10
	return base * Config.Eggs.HatchTimeMultiplier * (hatchTimeMultipliers[player] or 1)
end

local function placeEgg(player: Player, plot: Types.PlotInfo, padIndex: number, rarity: string)
	local pad = plot.Pads[padIndex]
	local part = EggVisual.create(rarity, true)
	part.CFrame = eggCFrameOnPad(pad)
	part:SetAttribute("PadIndex", padIndex)

	local endsAt = serverNow() + hatchSeconds(player, rarity)
	part:SetAttribute(Constants.Attributes.HatchEndsAt, endsAt)
	-- The client fills in the countdown ("0:35") on the Subtitle line.
	makeLabel(part, `{rarity} Egg`, Rarity.color(rarity), "", 2.8)
	CollectionService:AddTag(part, Constants.Tags.HatchingEgg)
	part.Parent = plot.Model

	getItems(plot)[padIndex] = {
		Kind = "Egg",
		Rarity = rarity,
		PetName = nil,
		Income = 0,
		Level = 1,
		Instance = part,
		HatchEndsAt = endsAt,
	}
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
	placeEgg(player, plot, bestIndex, rarity)
	return true
end

---------------------------------------------------------------------------
-- Hatching
---------------------------------------------------------------------------

-- Roll which pet comes out of an egg of `eggRarity`.
local function rollPet(eggRarity: string): Config.PetConfig
	local odds = Config.HatchOdds[eggRarity] or { [eggRarity] = 1 }
	local petRarity = Rarity.pick(odds) or eggRarity

	local function petsOf(rarity: string): { Config.PetConfig }
		local list = {}
		for _, pet in Config.Pets do
			if pet.Rarity == rarity then
				table.insert(list, pet)
			end
		end
		return list
	end
	local candidates = petsOf(petRarity)
	if #candidates == 0 then
		candidates = petsOf(eggRarity)
	end
	if #candidates == 0 then
		candidates = Config.Pets
	end
	return candidates[rng:NextInteger(1, #candidates)]
end

-- Text for a pet's label and its Upgrade/Sell prompts.
local function refreshPet(plot: Types.PlotInfo, padIndex: number)
	local item = getItems(plot)[padIndex]
	if not (item and item.Kind == "Pet") then
		return
	end
	local model = item.Instance
	local root = if model:IsA("Model") then model.PrimaryPart else nil
	if not root then
		return
	end
	local maxLevel = Config.Upgrades.PetLevel.MaxLevel

	local label = root:FindFirstChild("Label")
	local subtitle = label and label:FindFirstChild("Subtitle")
	if subtitle and subtitle:IsA("TextLabel") then
		subtitle.Text = `${Format.short(Config.PetIncome(item.Income, item.Level))}/s  •  Lv {item.Level}`
	end

	local upgrade = root:FindFirstChild("UpgradePrompt")
	if upgrade and upgrade:IsA("ProximityPrompt") then
		if item.Level >= maxLevel then
			upgrade.ActionText = "Max level"
		else
			upgrade.ActionText = `Upgrade  ${Format.short(Config.PetUpgradePrice(item.Income, item.Level))}`
		end
		upgrade.ObjectText = `{item.PetName or "Pet"}  Lv {item.Level}`
	end
	local sell = root:FindFirstChild("SellPrompt")
	if sell and sell:IsA("ProximityPrompt") then
		sell.ActionText = `Sell  ${Format.short(Config.PetSellValue(item.Income, item.Level))}`
		sell.ObjectText = item.PetName or "Pet"
	end
end

-- One prompt on a pet. Only the owner sees it (the client hides the rest),
-- and the server checks the owner again when it's used.
local function addPetPrompt(root: BasePart, plot: Types.PlotInfo, padIndex: number, action: string, key: Enum.KeyCode, hold: number)
	local prompt = Instance.new("ProximityPrompt")
	prompt.Name = `{action}Prompt`
	prompt.KeyboardKeyCode = key
	prompt.HoldDuration = hold
	prompt.MaxActivationDistance = 10
	prompt.RequiresLineOfSight = false
	prompt:SetAttribute(Constants.Attributes.OwnerUserId, if plot.Owner then plot.Owner.UserId else 0)
	prompt.Parent = root
	CollectionService:AddTag(prompt, Constants.Tags.PetPrompt)
	prompt.Triggered:Connect(function(player: Player)
		PetService.PetPromptTriggered:Fire(player, plot, padIndex, action)
	end)
end

local function placePet(plot: Types.PlotInfo, padIndex: number, pet: Config.PetConfig, level: number): Model
	local pad = plot.Pads[padIndex]
	local model = PetVisual.create(pet.Name, pet.Rarity, pet.Color, petCFrameOnPad(pad))
	model:SetAttribute("PadIndex", padIndex)
	local root = model.PrimaryPart :: BasePart
	makeLabel(root, pet.Name, Rarity.color(pet.Rarity), "", 3.2)
	addPetPrompt(root, plot, padIndex, "Upgrade", Enum.KeyCode.E, 0)
	-- Selling needs a 1-second hold, so it doesn't happen by accident.
	addPetPrompt(root, plot, padIndex, "Sell", Enum.KeyCode.F, 1)
	model.Parent = plot.Model

	getItems(plot)[padIndex] = {
		Kind = "Pet",
		Rarity = pet.Rarity,
		PetName = pet.Name,
		Income = pet.Income,
		Level = level,
		Instance = model,
		HatchEndsAt = nil,
	}
	refreshPet(plot, padIndex)
	return model
end

-- Change a pet's level (UpgradeService calls this after taking the money).
function PetService.SetPetLevel(plot: Types.PlotInfo, padIndex: number, level: number)
	local item = getItems(plot)[padIndex]
	if item and item.Kind == "Pet" then
		item.Level = math.clamp(level, 1, Config.Upgrades.PetLevel.MaxLevel)
		refreshPet(plot, padIndex)
	end
end

-- Take a pet off its pad (sold). The pad becomes free again.
function PetService.RemovePet(plot: Types.PlotInfo, padIndex: number)
	local items = getItems(plot)
	local item = items[padIndex]
	if item and item.Kind == "Pet" then
		item.Instance:Destroy()
		items[padIndex] = nil
	end
end

local function hatch(plot: Types.PlotInfo, padIndex: number, egg: PadItem)
	local owner = plot.Owner
	local pet = rollPet(egg.Rarity)
	local pad = plot.Pads[padIndex]

	egg.Instance:Destroy()
	placePet(plot, padIndex, pet, 1)

	-- Burst effect for everyone nearby, reveal card for the owner.
	Net.event(Net.Names.PetHatched):FireAllClients(pad.Position, pet.Rarity)
	if owner then
		Net.event(Net.Names.HatchReveal):FireClient(owner, pet.Name, pet.Rarity, pet.Income)
		if Rarity.rank(pet.Rarity) >= Rarity.rank(Config.PetDisplay.AnnounceFrom) then
			notifyAll(`🎉 {owner.DisplayName} hatched a {pet.Rarity} {pet.Name}!`)
		end
		if Config.Debug then
			print(`[{Config.GameName}] {owner.Name} hatched {pet.Rarity} {pet.Name} from a {egg.Rarity} Egg`)
		end
		PetService.PetHatched:Fire(owner, pet.Name, pet.Rarity)
	end
end

local function checkHatches()
	local now = serverNow()
	for _, plot in PlotService.GetPlots() do
		local items = padItems[plot.Index]
		if items then
			for padIndex, item in items do
				if item.Kind == "Egg" and item.HatchEndsAt and now >= item.HatchEndsAt then
					hatch(plot, padIndex, item)
				end
			end
		end
	end
end

function PetService.FinishHatching(player: Player)
	local plot = PlotService.GetPlot(player)
	if not plot then
		return
	end
	for _, item in getItems(plot) do
		if item.Kind == "Egg" then
			item.HatchEndsAt = 0
		end
	end
	checkHatches()
end

function PetService.SetHatchTimeMultiplier(player: Player, value: number)
	hatchTimeMultipliers[player] = value
end

---------------------------------------------------------------------------
-- Queries
---------------------------------------------------------------------------

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

-- Income of one pet item, including its level bonus.
local function petIncome(item: PadItem): number
	return Config.PetIncome(item.Income, item.Level)
end

function PetService.GetIncomePerSecond(player: Player): number
	local plot = PlotService.GetPlot(player)
	if not plot then
		return 0
	end
	local total = 0
	for _, item in getItems(plot) do
		if item.Kind == "Pet" then
			total += petIncome(item)
		end
	end
	return total
end

---------------------------------------------------------------------------
-- Lifecycle
---------------------------------------------------------------------------

-- Remove everything from a plot's pads (when its owner leaves).
local function clearPads(plotIndex: number)
	local items = padItems[plotIndex]
	if items then
		for _, item in items do
			item.Instance:Destroy()
		end
	end
	padItems[plotIndex] = nil
end

local function registerDebugCommands()
	DebugCommands.register("hatch", function(player, _args)
		PetService.FinishHatching(player)
	end)
	DebugCommands.register("egg", function(player, args)
		local wanted = args[1] or "common"
		for _, info in Config.Rarities do
			if string.lower(info.Name) == wanted then
				local character = player.Character
				local position = if character then character:GetPivot().Position else Vector3.zero
				if not PetService.AcceptEgg(player, info.Name, position) then
					Net.event(Net.Names.Notify):FireClient(player, "[Studio] All your pads are full!")
				end
				return
			end
		end
	end)
end

function PetService.Init()
end

function PetService.Start()
	PlotService.PlotReleased:Connect(function(_player: Player, plot: Types.PlotInfo)
		clearPads(plot.Index)
	end)
	Players.PlayerRemoving:Connect(function(player)
		hatchTimeMultipliers[player] = nil
	end)
	registerDebugCommands()

	local elapsed = 0
	RunService.Heartbeat:Connect(function(dt: number)
		elapsed += dt
		if elapsed >= HATCH_CHECK_INTERVAL then
			elapsed = 0
			checkHatches()
		end
	end)
end

return PetService
