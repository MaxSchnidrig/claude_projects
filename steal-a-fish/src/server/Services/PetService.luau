--!strict
--[[
	PetService
	==========
	Owns what sits on a plot's PADS. Each pad holds exactly ONE item:
	  - an "Egg": delivered by the player, counting down to hatch, or
	  - a "Pet": what hatched from that egg. It appears on the SAME pad, stays
	    there and earns money (EconomyService pays it out) until it is sold.
	So pads are egg slots and pet slots at the same time.

	Placing: the player equips an egg from their hotbar and presses E on a
	free pad ("Place Egg" prompt). EggService checks the egg, then calls
	PetService.PlaceEggOnPad.

	Hatching:
	  - Hatch time = Config.Eggs.ByRarity[rarity].HatchTime
	                 * Config.Eggs.HatchTimeMultiplier * the player's own
	                 hatch multiplier (for a "Faster Hatching" pass later).
	  - The countdown is shown above the egg (the client draws it from the
	    egg's HatchEndsAt attribute). When it reaches zero the egg is READY:
	    it glows and gets a "Hatch" prompt. The owner holds E to hatch it.
	  - The pet's rarity is rolled with Config.HatchOdds[eggRarity]; then one
	    pet of that rarity is picked at random (all equally likely).
	  - Everyone sees a burst effect; the owner gets a "You hatched ...!" card;
	    rare hatches are announced to the whole server.

	Eggs and pets are saved by DataService (ExportPads / ImportPads). An egg's
	hatch timer pauses while its owner is offline.

	Studio-only test command:
		!hatch          make all your eggs READY right now

	Public interface:
		PetService.GetFreePadCount(player) -> number
		PetService.GetPadItem(plot, padIndex) -> PadItem?
		PetService.GetIncomePerSecond(player) -> number   -- all pets, before boosts
		PetService.FinishHatching(player)                 -- make every egg READY now (Instant Hatch product later)
		PetService.PlaceEggOnPad(player, padIndex, rarity) -> boolean
		PetService.SetHatchTimeMultiplier(player, value)  -- e.g. 0.5 for a Faster Hatching pass
		PetService.ExportPads(player) / ImportPads(player, list)  -- saving (DataService)
		PetService.SetPetLevel(plot, padIndex, level)     -- after a paid upgrade
		PetService.RemovePet(plot, padIndex)               -- after selling; frees the pad
		PetService.PetHatched:Connect(function(player, petName, rarity) end)
		PetService.PetPromptTriggered:Connect(function(player, plot, padIndex, action) end)
]]

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
local Notify = require(script.Parent.Parent.Util.Notify)
local DebugCommands = require(script.Parent.Parent.Util.DebugCommands)
local EggVisual = require(script.Parent.Parent.Util.EggVisual)
local PetVisual = require(script.Parent.Parent.Util.PetVisual)
local PlayerLifecycle = require(script.Parent.Parent.Util.PlayerLifecycle)
local PlotService = require(script.Parent.PlotService)

-- What sits on one pad.
export type PadItem = {
	Kind: "Egg" | "Pet",
	Rarity: string,
	PetName: string?, -- pets only
	Income: number, -- pets only: money per second at level 1 (0 for eggs)
	Level: number, -- pets only (pet upgrades come later)
	Instance: Instance, -- the egg Part or the pet Model
	HatchEndsAt: number?, -- eggs only: server time its timer finishes
	Ready: boolean, -- eggs only: timer finished, waiting for the owner to hold E
}

local PetService = {}
PetService.Name = "PetService"

-- Fired with (player, petName, rarity) after an egg hatches.
PetService.PetHatched = Signal.new()
-- Fired with (player, plot, padIndex, "Upgrade" or "Sell") when someone uses
-- a pet's prompt. UpgradeService checks and handles it.
PetService.PetPromptTriggered = Signal.new()
-- Fired with (player, plot, padIndex) when someone uses a pad's "Place Egg"
-- prompt. EggService checks the player's equipped egg and places it.
PetService.PadPromptTriggered = Signal.new()

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

-- Mark a pad as taken/free (the client uses this to show "Place Egg" prompts).
local function setOccupied(plot: Types.PlotInfo, padIndex: number, occupied: boolean)
	local pad = plot.Pads[padIndex]
	if pad then
		pad:SetAttribute(Constants.Attributes.Occupied, occupied)
	end
end

local function notifyAll(message: string, kind: string?)
	Notify.all(message, kind)
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

-- secondsLeft: how long until it hatches (nil = the full hatch time).
local function placeEgg(player: Player, plot: Types.PlotInfo, padIndex: number, rarity: string, secondsLeft: number?)
	local pad = plot.Pads[padIndex]
	local part = EggVisual.create(rarity, true)
	part.CFrame = eggCFrameOnPad(pad)
	part:SetAttribute("PadIndex", padIndex)

	local endsAt = serverNow() + (secondsLeft or hatchSeconds(player, rarity))
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
		Ready = false,
	}
	setOccupied(plot, padIndex, true)
end

-- Put an egg from the player's inventory on one of their pads. Returns
-- false if that pad isn't theirs, isn't unlocked, or isn't free.
-- (EggService checks the inventory and the equipped egg first.)
function PetService.PlaceEggOnPad(player: Player, padIndex: number, rarity: string): boolean
	local plot = PlotService.GetPlot(player)
	if not plot or padIndex < 1 or padIndex > plot.UnlockedPads then
		return false
	end
	if getItems(plot)[padIndex] then
		return false
	end
	placeEgg(player, plot, padIndex, rarity)
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

	-- The client's Pets window reads these.
	model:SetAttribute(Constants.Attributes.PetName, item.PetName)
	model:SetAttribute(Constants.Attributes.BaseIncome, item.Income)
	model:SetAttribute(Constants.Attributes.Level, item.Level)

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
		Ready = false,
	}
	setOccupied(plot, padIndex, true)
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
		setOccupied(plot, padIndex, false)
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
			notifyAll(`🎉 {owner.DisplayName} hatched a {pet.Rarity} {pet.Name}!`, "epic")
		end
		if Config.Debug then
			print(`[{Config.GameName}] {owner.Name} hatched {pet.Rarity} {pet.Name} from a {egg.Rarity} Egg`)
		end
		PetService.PetHatched:Fire(owner, pet.Name, pet.Rarity)
	end
end

-- An egg's timer finished: it glows, says READY and gets a "Hatch" prompt.
-- It only hatches when its owner holds E on it.
local function markReady(plot: Types.PlotInfo, padIndex: number, item: PadItem)
	item.Ready = true
	local egg = item.Instance
	if not egg:IsA("BasePart") then
		return
	end
	egg:SetAttribute(Constants.Attributes.Ready, true)
	egg.Material = Enum.Material.Neon
	local light = egg:FindFirstChildOfClass("PointLight") or Instance.new("PointLight")
	light.Color = Rarity.color(item.Rarity)
	light.Range = 12
	light.Brightness = 3
	light.Parent = egg

	local prompt = Instance.new("ProximityPrompt")
	prompt.Name = "HatchPrompt"
	prompt.ActionText = "Hatch"
	prompt.ObjectText = `{item.Rarity} Egg`
	prompt.HoldDuration = Config.Eggs.HatchHoldDuration
	prompt.MaxActivationDistance = 10
	prompt.RequiresLineOfSight = false
	-- Same tag as the pet prompts: only the owner sees it.
	prompt:SetAttribute(Constants.Attributes.OwnerUserId, if plot.Owner then plot.Owner.UserId else 0)
	prompt.Parent = egg
	CollectionService:AddTag(prompt, Constants.Tags.PetPrompt)
	prompt.Triggered:Connect(function(player: Player)
		-- Check everything again: right owner, same egg still there, close enough.
		if plot.Owner ~= player or getItems(plot)[padIndex] ~= item or not item.Ready then
			return
		end
		local character = player.Character
		local root = character and character:FindFirstChild("HumanoidRootPart")
		if not (root and root:IsA("BasePart")) or (root.Position - egg.Position).Magnitude > 15 then
			return
		end
		hatch(plot, padIndex, item)
	end)
end

local function checkHatches()
	local now = serverNow()
	for _, plot in PlotService.GetPlots() do
		local items = padItems[plot.Index]
		if items then
			for padIndex, item in items do
				if item.Kind == "Egg" and not item.Ready and item.HatchEndsAt and now >= item.HatchEndsAt then
					markReady(plot, padIndex, item)
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
-- Saving and loading (used by DataService)
---------------------------------------------------------------------------

-- One pad's contents in a form that can be saved in a DataStore.
export type SavedPadItem = {
	Pad: number,
	Kind: string, -- "Egg" or "Pet"
	Rarity: string?, -- eggs
	SecondsLeft: number?, -- eggs: hatch time left (the timer pauses while you're offline)
	Name: string?, -- pets
	Level: number?, -- pets
}

function PetService.ExportPads(player: Player): { SavedPadItem }
	local result: { SavedPadItem } = {}
	local plot = PlotService.GetPlot(player)
	if not plot then
		return result
	end
	local now = serverNow()
	for padIndex, item in getItems(plot) do
		if item.Kind == "Egg" then
			table.insert(result, {
				Pad = padIndex,
				Kind = "Egg",
				Rarity = item.Rarity,
				SecondsLeft = math.max(0, (item.HatchEndsAt or now) - now),
			})
		elseif item.PetName then
			table.insert(result, { Pad = padIndex, Kind = "Pet", Name = item.PetName, Level = item.Level })
		end
	end
	return result
end

local function findPet(name: string): Config.PetConfig?
	for _, pet in Config.Pets do
		if pet.Name == name then
			return pet
		end
	end
	return nil
end

local function isKnownRarity(name: string): boolean
	return Rarity.rank(name) > 0
end

-- Put saved eggs and pets back on the player's plot. Items whose pad isn't
-- unlocked or is taken go to the first free pad. Unknown pets (for example
-- renamed in Config) are skipped with a warning.
function PetService.ImportPads(player: Player, saved: { SavedPadItem })
	local plot = PlotService.GetPlot(player)
	if not plot then
		return
	end
	local items = getItems(plot)
	local function freePad(preferred: number): number?
		if preferred >= 1 and preferred <= plot.UnlockedPads and not items[preferred] then
			return preferred
		end
		for padIndex = 1, plot.UnlockedPads do
			if not items[padIndex] then
				return padIndex
			end
		end
		return nil
	end

	for _, entry in saved do
		local padIndex = freePad(entry.Pad)
		if not padIndex then
			warn(`[{Config.GameName}] No free pad for a saved {entry.Kind} of {player.Name}; skipped.`)
			continue
		end
		if entry.Kind == "Egg" and entry.Rarity and isKnownRarity(entry.Rarity) then
			placeEgg(player, plot, padIndex, entry.Rarity, entry.SecondsLeft or 0)
		elseif entry.Kind == "Pet" and entry.Name then
			local pet = findPet(entry.Name)
			if pet then
				placePet(plot, padIndex, pet, math.clamp(entry.Level or 1, 1, Config.Upgrades.PetLevel.MaxLevel))
			else
				warn(`[{Config.GameName}] Saved pet "{entry.Name}" is not in Config.Pets; skipped.`)
			end
		end
	end
end

-- Remove every egg and pet from the player's pads (Studio !wipe command).
function PetService.ClearPlayerPads(player: Player)
	local plot = PlotService.GetPlot(player)
	if not plot then
		return
	end
	for padIndex, item in getItems(plot) do
		item.Instance:Destroy()
		getItems(plot)[padIndex] = nil
		setOccupied(plot, padIndex, false)
	end
end

---------------------------------------------------------------------------
-- Lifecycle
---------------------------------------------------------------------------

-- Remove everything from a plot's pads (when its owner leaves).
local function clearPads(plot: Types.PlotInfo)
	local items = padItems[plot.Index]
	if items then
		for padIndex, item in items do
			item.Instance:Destroy()
			setOccupied(plot, padIndex, false)
		end
	end
	padItems[plot.Index] = nil
end

local function registerDebugCommands()
	DebugCommands.register("hatch", function(player, _args)
		PetService.FinishHatching(player)
	end)

end

-- A "Place Egg" prompt on every pad of every plot. The client only shows
-- it to the owner, while they hold an egg and the pad is free.
local function addPadPrompts()
	for _, plot in PlotService.GetPlots() do
		for padIndex, pad in plot.Pads do
			local prompt = Instance.new("ProximityPrompt")
			prompt.Name = "PlacePrompt"
			prompt.ActionText = "Place Egg"
			prompt.ObjectText = `Pad {padIndex}`
			prompt.HoldDuration = Config.Eggs.PlaceHoldDuration
			prompt.MaxActivationDistance = 8
			prompt.RequiresLineOfSight = false
			prompt.Enabled = false
			prompt:SetAttribute(Constants.Attributes.OwnerUserId, 0)
			prompt.Parent = pad
			CollectionService:AddTag(prompt, Constants.Tags.PadPrompt)
			pad:SetAttribute(Constants.Attributes.Occupied, false)
			prompt.Triggered:Connect(function(player: Player)
				PetService.PadPromptTriggered:Fire(player, plot, padIndex)
			end)
		end
	end
end

-- Keep the owner on every pad prompt up to date.
local function setPadPromptOwner(plot: Types.PlotInfo, userId: number)
	for _, pad in plot.Pads do
		local prompt = pad:FindFirstChild("PlacePrompt")
		if prompt then
			prompt:SetAttribute(Constants.Attributes.OwnerUserId, userId)
		end
	end
end

function PetService.Init()
end

function PetService.Start()
	addPadPrompts()
	PlotService.PlotAssigned:Connect(function(player: Player, plot: Types.PlotInfo)
		setPadPromptOwner(plot, player.UserId)
	end)
	for _, plot in PlotService.GetPlots() do
		if plot.Owner then
			setPadPromptOwner(plot, plot.Owner.UserId)
		end
	end
	PlotService.PlotReleased:Connect(function(_player: Player, plot: Types.PlotInfo)
		clearPads(plot)
		setPadPromptOwner(plot, 0)
	end)
	PlayerLifecycle.onLeave(function(player)
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
