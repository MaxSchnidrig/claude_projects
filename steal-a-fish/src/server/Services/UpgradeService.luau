--!strict
--[[
	UpgradeService
	==============
	Everything you can BUY or SELL with money. The server checks every request
	(right player, real upgrade, not maxed, enough money, not spamming) and
	only then takes the money and applies the upgrade.

	Upgrades are bought IN THE WORLD with prompts (PlotService fires
	UpgradePromptTriggered): "Upgrade Plot" on the board in front of your plot and
	"Upgrade Treadmill" on the board next to your treadmill. The Fish panel
	can also ask with the "BuyUpgrade" remote:
	  - "Pads": plot space, unlocks the next pad on your plot.
	      Price = Config.UpgradePrice(Upgrades.Pads.Base, .Growth, pads bought so far)
	  - "Treadmill": the next tier in Config.Treadmill.Tiers, at that tier's Price.

	Pets (prompts on your own pets, or the buttons in the Pets window):
	  - Upgrade (E): +1 level, more income. Price = Config.PetUpgradePrice.
	  - Sell (hold F): money = Config.PetSellValue. The pad becomes free.

	Public interface:
		UpgradeService.GetPadsBought(player) -> number
		UpgradeService.SetPadsBought(player, count)   -- used by saving later
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = require(ReplicatedStorage.Shared.Config)
local Constants = require(ReplicatedStorage.Shared.Constants)
local Format = require(ReplicatedStorage.Shared.Format)
local Net = require(ReplicatedStorage.Shared.Net)
local Types = require(ReplicatedStorage.Shared.Types)
local Notify = require(script.Parent.Parent.Util.Notify)
local RateLimiter = require(script.Parent.Parent.Util.RateLimiter)
local PlayerLifecycle = require(script.Parent.Parent.Util.PlayerLifecycle)
local EconomyService = require(script.Parent.EconomyService)
local PetService = require(script.Parent.PetService)
local PlotService = require(script.Parent.PlotService)
local SpeedService = require(script.Parent.SpeedService)

local UpgradeService = {}
UpgradeService.Name = "UpgradeService"

local PET_PROMPT_RANGE = 15 -- studs; the prompt itself allows 10, plus lag slack

local padsBought: { [Player]: number } = {}
local buyLimiter = RateLimiter.new(4, 1)
local petLimiter = RateLimiter.new(6, 1)

local function notify(player: Player, message: string, kind: string?)
	Notify.send(player, message, kind)
end

local function money(amount: number): string
	return `${Format.short(amount)}`
end

-- Take the money, or tell the player how much they're missing.
local function pay(player: Player, price: number): boolean
	if EconomyService.TrySpend(player, price) then
		return true
	end
	local missing = price - EconomyService.GetMoney(player)
	notify(player, `Not enough money! You need {money(missing)} more.`, "warning")
	return false
end

---------------------------------------------------------------------------
-- Plot space (pads)
---------------------------------------------------------------------------

-- padsBought[player] = the plot LEVEL (it started as "pads bought", and the
-- first 4 levels still are exactly that, so old saves keep their pads).
local function plotLevel(player: Player): number
	return math.clamp(padsBought[player] or 0, 0, Config.MaxPlotLevel())
end

local function applyPads(player: Player, animate: boolean?)
	local level = plotLevel(player)
	player:SetAttribute(Constants.Attributes.PadsUnlocked, Config.PadsAtPlotLevel(level))
	player:SetAttribute("PlotLevel", level)
	local plot = PlotService.GetPlot(player)
	if plot then
		PlotService.SetPlotLevel(plot, level, animate)
	end
end

function UpgradeService.GetPadsBought(player: Player): number
	return plotLevel(player)
end

function UpgradeService.SetPadsBought(player: Player, count: number)
	padsBought[player] = math.max(0, math.floor(count))
	applyPads(player)
end

-- Buy the next plot level: +1 pad, or the second floor.
local function buyPlotLevel(player: Player)
	local level = plotLevel(player)
	local price = Config.NextPlotPrice(level)
	if not price then
		notify(player, "Your plot is already at MAX level!", "warning")
		return
	end
	if pay(player, price) then
		padsBought[player] = level + 1
		applyPads(player, true)
		if level + 1 == Config.Upgrades.SecondFloorLevel then
			notify(player, "🏗 Second floor built! Upgrade again for pads upstairs.", "purchase")
		else
			notify(player, `🟩 New pad! ({Config.PadsAtPlotLevel(level + 1)}/{Config.MaxPads()})`, "purchase")
		end
	end
end

---------------------------------------------------------------------------
-- Treadmill tiers
---------------------------------------------------------------------------

local function buyTreadmill(player: Player)
	local nextTier = SpeedService.GetTreadmillTier(player) + 1
	local tier = Config.Treadmill.Tiers[nextTier]
	if not tier then
		notify(player, "You already have the best treadmill!", "warning")
		return
	end
	if pay(player, tier.Price) then
		SpeedService.SetTreadmillTier(player, nextTier)
		notify(player, `🏃 {tier.Name} Treadmill unlocked! +{Format.short(tier.Gain)} Speed/sec`, "purchase")
	end
end

---------------------------------------------------------------------------
-- Pets
---------------------------------------------------------------------------

-- Upgrade or sell one pet. From a prompt (mustBeNear = true: the player has
-- to stand next to the pet) or from the Pets window (anywhere).
local function handlePetAction(player: Player, plot: Types.PlotInfo, padIndex: number, action: string, mustBeNear: boolean)
	if not petLimiter.allow(player) then
		return
	end
	-- Only the owner may touch their pets.
	if plot.Owner ~= player then
		return
	end
	local item = PetService.GetPadItem(plot, padIndex)
	if not (item and item.Kind == "Pet") then
		return
	end
	if mustBeNear then
		-- Close enough? (Don't trust that the prompt was really used up close.)
		local character = player.Character
		local root = character and character:FindFirstChild("HumanoidRootPart")
		local pet = item.Instance
		if not (root and root:IsA("BasePart") and pet:IsA("Model")) then
			return
		end
		if (root.Position - pet:GetPivot().Position).Magnitude > PET_PROMPT_RANGE then
			return
		end
	end

	if action == "Upgrade" then
		if item.Level >= Config.Upgrades.PetLevel.MaxLevel then
			notify(player, `{item.PetName} is already at max level!`, "warning")
			return
		end
		local price = Config.PetUpgradePrice(item.Income, item.Level)
		if pay(player, price) then
			PetService.SetPetLevel(plot, padIndex, item.Level + 1)
			local income = Config.PetIncome(item.Income, item.Level)
			notify(player, `⬆ {item.PetName} is now level {item.Level}! ({money(income)}/s)`, "purchase")
		end
	elseif action == "Sell" then
		local value = Config.PetSellValue(item.Income, item.Level)
		local name = item.PetName or "pet"
		PetService.RemovePet(plot, padIndex)
		EconomyService.AddMoney(player, value)
		notify(player, `💰 Sold {name} for {money(value)}`, "purchase")
	end
end

---------------------------------------------------------------------------
-- Lifecycle
---------------------------------------------------------------------------

function UpgradeService.Init()
end

function UpgradeService.Start()
	-- The client only sends the NAME of the upgrade. Everything else (price,
	-- max level, money) is decided here.
	Net.event(Net.Names.BuyUpgrade).OnServerEvent:Connect(function(player: Player, upgradeName: unknown)
		if not buyLimiter.allow(player) or typeof(upgradeName) ~= "string" then
			return
		end
		if not PlotService.GetPlot(player) then
			return
		end
		if upgradeName == "Pads" or upgradeName == "Plot" then
			buyPlotLevel(player)
		elseif upgradeName == "Treadmill" then
			buyTreadmill(player)
		end
	end)

	PetService.PetPromptTriggered:Connect(function(player: Player, plot: Types.PlotInfo, padIndex: number, action: string)
		handlePetAction(player, plot, padIndex, action, true)
	end)

	-- Buttons in the Pets window. Check every value the client sent.
	Net.event(Net.Names.PetAction).OnServerEvent:Connect(function(player: Player, padIndex: unknown, action: unknown)
		if typeof(padIndex) ~= "number" or padIndex ~= math.floor(padIndex) then
			return
		end
		if action ~= "Upgrade" and action ~= "Sell" then
			return
		end
		local plot = PlotService.GetPlot(player)
		if plot and padIndex >= 1 and padIndex <= #plot.Pads then
			handlePetAction(player, plot, padIndex, action :: string, false)
		end
	end)

	-- Prompts in the world. Check owner and distance (prompts can be faked).
	PlotService.UpgradePromptTriggered:Connect(function(player: Player, plot: Types.PlotInfo, kind: string)
		if plot.Owner ~= player or not buyLimiter.allow(player) then
			return
		end
		local character = player.Character
		local root = character and character:FindFirstChild("HumanoidRootPart")
		local target: BasePart? = if kind == "Treadmill" then plot.UpgradeSign else plot.PlotSign
		if not (root and root:IsA("BasePart") and target) or (root.Position - target.Position).Magnitude > 16 then
			return
		end
		if kind == "Plot" then
			buyPlotLevel(player)
		elseif kind == "Treadmill" then
			buyTreadmill(player)
		end
	end)

	-- A (new) plot gets the owner's plot level.
	PlotService.PlotAssigned:Connect(function(player: Player)
		applyPads(player)
	end)
	for _, player in Players:GetPlayers() do
		applyPads(player)
	end
	Players.PlayerAdded:Connect(applyPads)
	PlayerLifecycle.onLeave(function(player)
		padsBought[player] = nil
	end)
end

return UpgradeService
