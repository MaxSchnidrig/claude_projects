--!strict
--[[
	EconomyService
	==============
	Owns money. It is the ONLY place money is added or removed.

	  - Every Config.Economy.IncomeTickInterval seconds, each player's pets pay
	    out: PetService.GetIncomePerSecond(player) * income multipliers
	    (for example a 2x Money pass later).
	  - Config.Economy.CollectMode:
	      "Pad"  = the money piles up on the green collect pad of the plot.
	               Stand on it to collect (the label shows how much is waiting).
	      "Auto" = the money goes straight to the player (the pad is hidden).
	  - Money is shown on the leaderboard and in the HUD (player attributes
	    "Money" and "Income").

	Money is saved by DataService (wallet + whatever waits on the collect pad).

	Studio-only test command:
		!money 5000     set your money

	Public interface:
		EconomyService.GetMoney(player) -> number
		EconomyService.AddMoney(player, amount)
		EconomyService.TrySpend(player, amount) -> boolean   -- false if they can't afford it
		EconomyService.GetIncomePerSecond(player) -> number   -- after boosts
		EconomyService.SetIncomeMultiplier(player, key, value?)  -- e.g. "MoneyPass" = 2
		EconomyService.SetAutoCollect(player, on)          -- Auto Collect pass: money goes straight to the player
		EconomyService.SetMoney(player, amount)            -- loading saved data
		EconomyService.GetMoneyForSave(player) -> number   -- wallet + money waiting on the pad
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Config = require(ReplicatedStorage.Shared.Config)
local Constants = require(ReplicatedStorage.Shared.Constants)
local Format = require(ReplicatedStorage.Shared.Format)
local Net = require(ReplicatedStorage.Shared.Net)
local DebugCommands = require(script.Parent.Parent.Util.DebugCommands)
local Leaderstats = require(script.Parent.Parent.Util.Leaderstats)
local PlayerLifecycle = require(script.Parent.Parent.Util.PlayerLifecycle)
local PetService = require(script.Parent.PetService)
local PlotService = require(script.Parent.PlotService)

local EconomyService = {}
EconomyService.Name = "EconomyService"

local COLLECT_CHECK_INTERVAL = 0.2

local money: { [Player]: number } = {}
local waiting: { [Player]: number } = {} -- money waiting on the collect pad
local incomeMultipliers: { [Player]: { [string]: number } } = {}
local autoCollect: { [Player]: boolean? } = {} -- players with the Auto Collect pass

local function moneyText(amount: number): string
	return `${Format.short(amount)}`
end

local function refresh(player: Player)
	local amount = money[player] or 0
	player:SetAttribute(Constants.Attributes.Money, amount)
	Leaderstats.set(player, "Money", moneyText(amount))
end

function EconomyService.GetMoney(player: Player): number
	return money[player] or 0
end

function EconomyService.AddMoney(player: Player, amount: number)
	if amount ~= amount or amount == math.huge then
		return -- ignore NaN / infinity, just in case
	end
	money[player] = math.max(0, (money[player] or 0) + amount)
	refresh(player)
end

-- Set money directly (used when loading saved data).
function EconomyService.SetMoney(player: Player, amount: number)
	if amount ~= amount or amount == math.huge then
		amount = 0
	end
	money[player] = math.max(0, amount)
	refresh(player)
end

-- Money in the wallet PLUS money still waiting on the collect pad. Saving
-- stores this total, so nothing waiting on the pad is lost when you leave.
function EconomyService.GetMoneyForSave(player: Player): number
	return (money[player] or 0) + math.floor(waiting[player] or 0)
end

function EconomyService.TrySpend(player: Player, amount: number): boolean
	local current = money[player] or 0
	if amount < 0 or current < amount then
		return false
	end
	money[player] = current - amount
	refresh(player)
	return true
end

function EconomyService.SetIncomeMultiplier(player: Player, key: string, value: number?)
	local multipliers = incomeMultipliers[player]
	if not multipliers then
		multipliers = {}
		incomeMultipliers[player] = multipliers
	end
	if value then
		multipliers[key] = value
	else
		multipliers[key] = nil
	end
end

function EconomyService.GetIncomePerSecond(player: Player): number
	local income = PetService.GetIncomePerSecond(player)
	local multipliers = incomeMultipliers[player]
	if multipliers then
		for _, multiplier in multipliers do
			income *= multiplier
		end
	end
	return income
end

local function updateCollectLabel(player: Player)
	local plot = PlotService.GetPlot(player)
	if plot then
		plot.CollectLabel.Text = if autoCollect[player] then "🧲 AUTO COLLECT" else `💰 {moneyText(math.floor(waiting[player] or 0))}`
	end
end

-- Auto Collect: income goes straight into the wallet (and whatever is
-- waiting on the pad is paid out right away).
function EconomyService.SetAutoCollect(player: Player, on: boolean)
	autoCollect[player] = if on then true else nil
	if on then
		local amount = math.floor(waiting[player] or 0)
		if amount >= 1 then
			waiting[player] = (waiting[player] or 0) - amount
			EconomyService.AddMoney(player, amount)
		end
	end
	updateCollectLabel(player)
end

-- Remove everything waiting on the collect pad (used by the Studio !wipe command).
function EconomyService.ClearWaiting(player: Player)
	waiting[player] = 0
	updateCollectLabel(player)
end

---------------------------------------------------------------------------
-- Income and collecting
---------------------------------------------------------------------------

local function payIncome()
	local interval = Config.Economy.IncomeTickInterval
	for _, player in Players:GetPlayers() do
		local perSecond = EconomyService.GetIncomePerSecond(player)
		player:SetAttribute(Constants.Attributes.Income, perSecond)
		local earned = perSecond * interval
		if earned > 0 then
			if Config.Economy.CollectMode == "Auto" or autoCollect[player] then
				EconomyService.AddMoney(player, earned)
			else
				waiting[player] = (waiting[player] or 0) + earned
				updateCollectLabel(player)
			end
		end
	end
end

local function isOnPad(pad: BasePart, position: Vector3): boolean
	local localPos = pad.CFrame:PointToObjectSpace(position)
	return math.abs(localPos.X) <= pad.Size.X / 2 + 0.5
		and math.abs(localPos.Z) <= pad.Size.Z / 2 + 0.5
		and localPos.Y > 0
		and localPos.Y < 7
end

local function checkCollectPads()
	for _, player in Players:GetPlayers() do
		local amount = math.floor(waiting[player] or 0)
		if amount >= 1 then
			local plot = PlotService.GetPlot(player)
			local character = player.Character
			local root = character and character:FindFirstChild("HumanoidRootPart")
			if plot and root and root:IsA("BasePart") and isOnPad(plot.CollectPad, root.Position) then
				waiting[player] = (waiting[player] or 0) - amount
				EconomyService.AddMoney(player, amount)
				updateCollectLabel(player)
				Net.event(Net.Names.MoneyCollected):FireClient(player, amount)
			end
		end
	end
end

---------------------------------------------------------------------------
-- Lifecycle
---------------------------------------------------------------------------

local function watchPlayer(player: Player)
	money[player] = money[player] or Config.Economy.StartingMoney
	refresh(player)
	player:SetAttribute(Constants.Attributes.Income, 0)
end

function EconomyService.Init()
end

function EconomyService.Start()
	Players.PlayerAdded:Connect(watchPlayer)
	for _, player in Players:GetPlayers() do
		watchPlayer(player)
	end
	PlayerLifecycle.onLeave(function(player)
		money[player] = nil
		waiting[player] = nil
		incomeMultipliers[player] = nil
		autoCollect[player] = nil
	end)

	-- Fresh plot: empty collect pad. In "Auto" mode the pad isn't needed.
	PlotService.PlotAssigned:Connect(function(player: Player, plot)
		updateCollectLabel(player)
		if Config.Economy.CollectMode == "Auto" then
			plot.CollectPad.Parent = nil
		end
	end)
	PlotService.PlotReleased:Connect(function(_player: Player, plot)
		plot.CollectLabel.Text = "💰 $0"
	end)

	DebugCommands.register("money", function(player, args)
		local amount = tonumber(args[1])
		if amount then
			money[player] = math.max(0, amount)
			refresh(player)
		end
	end)

	local tickElapsed = 0
	local collectElapsed = 0
	RunService.Heartbeat:Connect(function(dt: number)
		tickElapsed += dt
		if tickElapsed >= Config.Economy.IncomeTickInterval then
			tickElapsed -= Config.Economy.IncomeTickInterval
			payIncome()
		end
		collectElapsed += dt
		if collectElapsed >= COLLECT_CHECK_INTERVAL then
			collectElapsed = 0
			checkCollectPads()
		end
	end)
end

return EconomyService
