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
	  - Which fish comes out: one of the 8 fish of the zone the egg was
	    ORIGINALLY stolen from, weighted by the egg's rarity (Fish.roll, odds
	    in Config.Hatching). The full odds table is printed at server start.
	  - Everyone sees a burst effect; the owner gets a "You hatched ...!" card;
	    rare hatches are announced to the whole server.

	Eggs and pets are saved by DataService (ExportPads / ImportPads). An egg's
	hatch timer pauses while its owner is offline. Saved pets that no longer
	exist (the old pet list, or a fish renamed in Config) become a random
	fish of the same rarity.

	Studio-only test command:
		!hatch          make all your eggs READY right now

	Public interface:
		PetService.GetFreePadCount(player) -> number
		PetService.GetPadItem(plot, padIndex) -> PadItem?
		PetService.GetIncomePerSecond(player) -> number   -- all pets, before boosts
		PetService.FinishHatching(player)                 -- make every egg READY now (Instant Hatch product later)
		PetService.PlaceEggOnPad(player, padIndex, rarity, zone) -> boolean
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
local Fish = require(ReplicatedStorage.Shared.Fish)
local Notify = require(script.Parent.Parent.Util.Notify)
local DebugCommands = require(script.Parent.Parent.Util.DebugCommands)
local EggModel = require(ReplicatedStorage.Shared.Models.EggModel)
local FishModel = require(ReplicatedStorage.Shared.Models.FishModel)
local PlayerLifecycle = require(script.Parent.Parent.Util.PlayerLifecycle)
local PlotService = require(script.Parent.PlotService)

-- What sits on one pad.
export type PadItem = {
	Kind: "Egg" | "Pet",
	Rarity: string,
	Zone: number, -- eggs: the zone it was stolen from; pets: the fish's zone
	PetName: string?, -- pets only: the fish's fixed Id (saved)
	DisplayName: string?, -- pets only: the name players see
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

-- Pets float above the pad, facing the middle of the plot. (FishModel
-- lifts each fish so its lowest point is HoverHeight above the pad.)
local function petCFrameOnPad(pad: BasePart): CFrame
	local position = Vector3.new(pad.Position.X, padTop(pad), pad.Position.Z)
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
local function placeEgg(player: Player, plot: Types.PlotInfo, padIndex: number, rarity: string, zoneIndex: number, secondsLeft: number?)
	local pad = plot.Pads[padIndex]
	local part = EggModel.create(rarity, zoneIndex, true)
	part.CFrame = eggCFrameOnPad(pad)
	part:SetAttribute("PadIndex", padIndex)

	local fullTime = hatchSeconds(player, rarity)
	local endsAt = serverNow() + (secondsLeft or fullTime)
	part:SetAttribute(Constants.Attributes.HatchEndsAt, endsAt)
	-- The client grows the egg by how far along it is (HatchEndsAt / HatchDuration).
	part:SetAttribute("HatchDuration", math.max(fullTime, secondsLeft or 0, 0.1))
	-- The client fills in the countdown ("0:35") on the Subtitle line.
	makeLabel(part, `{rarity} Egg`, Rarity.color(rarity), "", 2.8)
	CollectionService:AddTag(part, Constants.Tags.HatchingEgg)
	part.Parent = plot.Model

	getItems(plot)[padIndex] = {
		Kind = "Egg",
		Rarity = rarity,
		Zone = zoneIndex,
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
function PetService.PlaceEggOnPad(player: Player, padIndex: number, rarity: string, zoneIndex: number): boolean
	local plot = PlotService.GetPlot(player)
	if not plot or padIndex < 1 or padIndex > plot.UnlockedPads then
		return false
	end
	if getItems(plot)[padIndex] then
		return false
	end
	placeEgg(player, plot, padIndex, rarity, zoneIndex)
	return true
end

---------------------------------------------------------------------------
-- Hatching
---------------------------------------------------------------------------

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
	model:SetAttribute(Constants.Attributes.PetName, item.DisplayName)
	model:SetAttribute("FishId", item.PetName)
	model:SetAttribute(Constants.Attributes.BaseIncome, item.Income)
	model:SetAttribute(Constants.Attributes.Level, item.Level)

	local label = root:FindFirstChild("Label")
	local subtitle = label and label:FindFirstChild("Subtitle")
	if subtitle and subtitle:IsA("TextLabel") then
		subtitle.Text = `${Format.short(Config.PetIncome(item.Income, item.Level))}/s  •  Lv {item.Level}`
	end

	local upgrade = root:FindFirstChild("UpgradePrompt")
	if upgrade and upgrade:IsA("ProximityPrompt") then
		local income = Config.PetIncome(item.Income, item.Level)
		if item.Level >= maxLevel then
			upgrade.ActionText = "Max level"
			upgrade.ObjectText = `{item.DisplayName or "Pet"}  Lv {item.Level}  •  ${Format.short(income)}/s`
		else
			-- Show what the upgrade gives: "Lv 5 → 6: $120/s → $134/s"
			local nextIncome = Config.PetIncome(item.Income, item.Level + 1)
			upgrade.ActionText = `Upgrade  ${Format.short(Config.PetUpgradePrice(item.Income, item.Level))}`
			upgrade.ObjectText = `Lv {item.Level} → {item.Level + 1}:  ${Format.short(income)}/s → ${Format.short(nextIncome)}/s`
		end
	end
	local sell = root:FindFirstChild("SellPrompt")
	if sell and sell:IsA("ProximityPrompt") then
		sell.ActionText = `Hold to sell  ${Format.short(Config.PetSellValue(item.Income, item.Level))}`
		sell.ObjectText = "" -- the name is already on the Upgrade prompt above
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
	-- Upgrade and Sell sit on the same fish: draw them one above the other
	-- (pixels on screen) instead of on top of each other.
	prompt.UIOffset = if action == "Upgrade" then Vector2.new(0, -44) else Vector2.new(0, 44)
	prompt:SetAttribute(Constants.Attributes.OwnerUserId, if plot.Owner then plot.Owner.UserId else 0)
	prompt.Parent = root
	CollectionService:AddTag(prompt, Constants.Tags.PetPrompt)
	prompt.Triggered:Connect(function(player: Player)
		PetService.PetPromptTriggered:Fire(player, plot, padIndex, action)
	end)
end

local function numberAttribute(instance: Instance, name: string, default: number): number
	local value = instance:GetAttribute(name)
	return if typeof(value) == "number" then value else default
end

-- Resize a fish for its level (1 = the size it was built at) and keep its
-- name label just above it.
local function applySize(model: Model, factor: number)
	model:ScaleTo(factor)
	local root = model.PrimaryPart
	local label = root and root:FindFirstChild("Label")
	if label and label:IsA("BillboardGui") then
		label.StudsOffsetWorldSpace = Vector3.new(0, numberAttribute(model, "Top", 1) * factor + 1.4, 0)
	end
end

local function placePet(plot: Types.PlotInfo, padIndex: number, pet: Config.FishConfig, level: number): Model
	local pad = plot.Pads[padIndex]
	local padTopCFrame = petCFrameOnPad(pad)
	local model = FishModel.create(pet, padTopCFrame)
	-- The fish's pivot is its LOWEST point, so it floats HoverHeight above the
	-- pad and grows upward (never into the pad) when it levels up.
	local root = model.PrimaryPart :: BasePart
	root.PivotOffset = CFrame.new(0, -numberAttribute(model, "Bottom", 1), 0)
	model:PivotTo(padTopCFrame + Vector3.new(0, Config.PetDisplay.HoverHeight, 0))
	model:SetAttribute("PadIndex", padIndex)
	makeLabel(root, pet.Name, Rarity.color(pet.Rarity), "", numberAttribute(model, "Top", 1) + 1.4)
	applySize(model, Config.PetSizeAtLevel(level))
	addPetPrompt(root, plot, padIndex, "Upgrade", Enum.KeyCode.E, 0)
	-- Selling needs a 1-second hold, so it doesn't happen by accident.
	addPetPrompt(root, plot, padIndex, "Sell", Enum.KeyCode.F, 1)
	model.Parent = plot.Model

	getItems(plot)[padIndex] = {
		Kind = "Pet",
		Rarity = pet.Rarity,
		Zone = pet.Zone,
		PetName = pet.Id,
		DisplayName = pet.Name,
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

-- Grow a fish smoothly to its new size, with a sparkle for everyone nearby.
local growTokens: { [Instance]: number } = {}
local function growTo(model: Model, rarity: string, targetSize: number)
	local token = (growTokens[model] or 0) + 1
	growTokens[model] = token
	Net.event(Net.Names.FishLeveledUp):FireAllClients(model:GetPivot().Position, rarity)
	task.spawn(function()
		local startSize = model:GetScale()
		local steps = 7
		for step = 1, steps do
			task.wait(Config.Upgrades.PetLevel.GrowSeconds / steps)
			if growTokens[model] ~= token or model.Parent == nil then
				return -- a newer upgrade took over, or the fish is gone
			end
			-- Ease out: fast at first, gentle at the end.
			local t = 1 - (1 - step / steps) ^ 2
			applySize(model, startSize + (targetSize - startSize) * t)
		end
		growTokens[model] = nil
	end)
end

-- Change a pet's level (UpgradeService calls this after taking the money).
function PetService.SetPetLevel(plot: Types.PlotInfo, padIndex: number, level: number)
	local item = getItems(plot)[padIndex]
	if item and item.Kind == "Pet" then
		item.Level = math.clamp(level, 1, Config.Upgrades.PetLevel.MaxLevel)
		refreshPet(plot, padIndex)
		local model = item.Instance
		if model:IsA("Model") then
			growTo(model, item.Rarity, Config.PetSizeAtLevel(item.Level))
		end
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
	local pet = Fish.roll(egg.Rarity, egg.Zone)
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
			print(`[{Config.GameName}] {owner.Name} hatched {pet.Rarity} {pet.Name} from a {egg.Rarity} Egg (zone {egg.Zone})`)
		end
		PetService.PetHatched:Fire(owner, pet.Id, pet.Rarity)
	end
end

-- How much bigger (in studs, from its middle) a fully grown egg reaches.
local function eggReach(rarity: string): number
	local grow = Config.Eggs.GrowByRarity[rarity] or 1
	return (grow - 1) * math.max(Config.Eggs.Size.X, Config.Eggs.Size.Y)
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
	local light = Instance.new("PointLight")
	light.Name = "ReadyGlow"
	light.Color = Rarity.color(item.Rarity)
	light.Range = 12
	light.Brightness = 3
	light.Parent = egg

	local prompt = Instance.new("ProximityPrompt")
	prompt.Name = "HatchPrompt"
	prompt.ActionText = "Hatch"
	prompt.ObjectText = `{item.Rarity} Egg`
	prompt.HoldDuration = Config.Eggs.HatchHoldDuration
	-- The egg has grown (up to Config.Eggs.GrowByRarity), so the prompt
	-- reaches farther: you can hatch it standing next to it.
	prompt.MaxActivationDistance = 10 + eggReach(item.Rarity)
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
		if not (root and root:IsA("BasePart")) or (root.Position - egg.Position).Magnitude > 15 + eggReach(item.Rarity) then
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
	Rarity: string?, -- eggs and pets
	Zone: number?, -- eggs: zone it was stolen from; pets: the fish's zone
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
				Zone = item.Zone,
				SecondsLeft = math.max(0, (item.HatchEndsAt or now) - now),
			})
		elseif item.PetName then
			table.insert(result, {
				Pad = padIndex,
				Kind = "Pet",
				Name = item.PetName,
				Rarity = item.Rarity,
				Zone = item.Zone,
				Level = item.Level,
			})
		end
	end
	return result
end

local function isKnownRarity(name: string): boolean
	return Rarity.rank(name) > 0
end

-- The fish for a saved pet. If that fish doesn't exist anymore (a pet from
-- the old pet list, or a fish renamed in Config), pick a random fish of the
-- same rarity (from the same zone if possible), so nobody loses a pet.
local function findSavedFish(entry: SavedPadItem): Config.FishConfig?
	local name = entry.Name or ""
	local fish = Fish.byName(name)
	if fish then
		return fish
	end
	local rarity = entry.Rarity
	if not (rarity and isKnownRarity(rarity)) then
		rarity = Fish.legacyRarity(name)
	end
	if not rarity then
		return nil
	end
	local candidates: { Config.FishConfig } = {}
	for _, option in Fish.ofRarity(rarity) do
		if entry.Zone == nil or option.Zone == entry.Zone then
			table.insert(candidates, option)
		end
	end
	if #candidates == 0 then
		candidates = Fish.ofRarity(rarity)
	end
	if #candidates == 0 then
		return nil
	end
	local replacement = candidates[rng:NextInteger(1, #candidates)]
	print(`[{Config.GameName}] Saved pet "{name}" no longer exists: converted to {replacement.Rarity} {replacement.Name}.`)
	return replacement
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
			-- Old saves don't know the egg's zone: use the zone where that
			-- rarity is most common.
			local zoneIndex = if entry.Zone and Config.Zones[entry.Zone] then entry.Zone else Fish.likelyZone(entry.Rarity)
			placeEgg(player, plot, padIndex, entry.Rarity, zoneIndex, entry.SecondsLeft or 0)
		elseif entry.Kind == "Pet" and entry.Name then
			local pet = findSavedFish(entry)
			if pet then
				placePet(plot, padIndex, pet, math.clamp(entry.Level or 1, 1, Config.Upgrades.PetLevel.MaxLevel))
			else
				warn(`[{Config.GameName}] Saved pet "{entry.Name}" is not in Config.Fish; skipped.`)
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
	if Config.Hatching.PrintOddsTable then
		print(Fish.oddsTable())
	end

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
