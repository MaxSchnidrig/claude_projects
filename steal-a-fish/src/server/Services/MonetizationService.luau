--!strict
--[[
	MonetizationService
	===================
	Everything bought with Robux (the items are listed in Config.Shop, and
	what they do is in Config.Monetization).

	GAME PASSES (buy once, forever): 2x Money, 2x Speed, VIP, Lucky,
	Faster Hatching, Auto Collect.
	  - Ownership is checked with Roblox every time you join
	    (UserOwnsGamePassAsync), and granted right away when you buy one
	    in the game (PromptGamePassPurchaseFinished).

	DEVELOPER PRODUCTS (buy again and again): 2x Money/Speed/Luck boosts,
	Instant Hatch, Server Luck, Shark Freeze and cash.
	  - Roblox calls ProcessReceipt. We give the item, remember the
	    purchase ID in the player's save (ProcessedPurchases) and SAVE. Only
	    then do we tell Roblox "granted". If anything fails, Roblox asks
	    again later, and the remembered ID makes sure nobody gets an item
	    twice.
	  - Boost timers (Money, Speed, Luck) stack, only count down while you
	    play, and are saved (DataService record "Boosts").

	THE BUY BUTTON only ASKS the server ("ShopBuy"). The server checks the
	item, then opens Roblox's purchase window. Some items are refused before
	you pay (a pass you own, Instant Hatch with no eggs hatching).

	ITEMS WITHOUT AN ID (Id = 0 in Config.Shop):
	  - Studio: clicking buy SIMULATES the purchase (free) so you can test.
	  - Live game: "Coming soon!" (nothing happens).

	Player attributes for the client:
	  "Pass_<Key>" = true            owned passes (Shop shows OWNED, VIP chat tag)
	  "Boost<Name>EndsAt" = time     when a boost ends (server time; HUD timers)
	  "Luck" = number                current luck (1 = normal)
	Workspace attribute "ServerLuckEndsAt" = when Server Luck ends.

	Studio-only test commands:
		!buy <Key>      simulate buying an item (e.g. !buy DoubleMoney, !buy BotFreeze)
		!unbuy          remove the passes you simulated in this session
]]

local MarketplaceService = game:GetService("MarketplaceService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local Config = require(ReplicatedStorage.Shared.Config)
local Format = require(ReplicatedStorage.Shared.Format)
local Net = require(ReplicatedStorage.Shared.Net)
local DebugCommands = require(script.Parent.Parent.Util.DebugCommands)
local Notify = require(script.Parent.Parent.Util.Notify)
local PlayerLifecycle = require(script.Parent.Parent.Util.PlayerLifecycle)
local RateLimiter = require(script.Parent.Parent.Util.RateLimiter)
local BotService = require(script.Parent.BotService)
local DataService = require(script.Parent.DataService)
local EconomyService = require(script.Parent.EconomyService)
local PetService = require(script.Parent.PetService)
local SpeedService = require(script.Parent.SpeedService)

local MonetizationService = {}
MonetizationService.Name = "MonetizationService"

type PlayerState = {
	Passes: { [string]: boolean }, -- owned passes (by Key)
	Simulated: { [string]: boolean }, -- passes simulated in Studio (not real)
	Boosts: { [string]: number }, -- seconds left: "Money", "Speed", "Luck"
	Loaded: boolean, -- saved boosts restored (only then do we write them back)
}

-- Which product adds time to which boost.
local BOOST_OF: { [string]: string } = { Money15 = "Money", Speed15 = "Speed", Luck15 = "Luck" }
local BOOST_NAMES = { "Money", "Speed", "Luck" }
local BOOST_LABELS: { [string]: string } = { Money = "2x Money", Speed = "2x Speed", Luck = "2x Luck" }

local states: { [Player]: PlayerState } = {}
local serverLuckLeft = 0 -- seconds
local buyLimiter = RateLimiter.new(3, 1)
local isStudio = RunService:IsStudio()

local function notify(player: Player, message: string, kind: string?)
	Notify.send(player, message, kind)
end

local function itemById(kind: string, id: number): Config.ShopItem?
	for _, item in Config.Shop.Items do
		if item.Kind == kind and item.Id == id and id ~= 0 then
			return item
		end
	end
	return nil
end

local function hasPass(player: Player, key: string): boolean
	local state = states[player]
	return state ~= nil and state.Passes[key] == true
end

---------------------------------------------------------------------------
-- Applying passes and boosts to the game
---------------------------------------------------------------------------

local function currentLuck(player: Player): number
	local state = states[player]
	local m = Config.Monetization
	local luck = 1
	if hasPass(player, "Lucky") then
		luck += m.LuckyPassLuck
	end
	if state and (state.Boosts.Luck or 0) > 0 then
		luck += m.BoostLuck
	end
	if serverLuckLeft > 0 then
		luck += m.ServerLuck
	end
	return luck
end

-- "👑 VIP" over the head of VIP players.
local function updateVipTag(player: Player)
	local character = player.Character
	local head = character and character:FindFirstChild("Head")
	if not head then
		return
	end
	local existing = head:FindFirstChild("VipTag")
	if not hasPass(player, "VIP") then
		if existing then
			existing:Destroy()
		end
		return
	end
	if existing then
		return
	end
	local tag = Instance.new("BillboardGui")
	tag.Name = "VipTag"
	tag.Size = UDim2.fromOffset(110, 34)
	tag.StudsOffset = Vector3.new(0, 2.6, 0)
	tag.MaxDistance = 120
	tag.AlwaysOnTop = false
	local label = Instance.new("TextLabel")
	label.Size = UDim2.fromScale(1, 1)
	label.BackgroundTransparency = 1
	label.Font = Enum.Font.FredokaOne
	label.TextScaled = true
	label.Text = "👑 VIP"
	label.TextColor3 = Color3.fromRGB(255, 205, 60)
	label.TextStrokeTransparency = 0
	label.TextStrokeColor3 = Color3.fromRGB(60, 40, 0)
	label.Parent = tag
	tag.Parent = head
end

local function setBoostAttributes(player: Player, state: PlayerState)
	local now = Workspace:GetServerTimeNow()
	for _, name in BOOST_NAMES do
		local left = state.Boosts[name] or 0
		player:SetAttribute(`Boost{name}EndsAt`, if left > 0 then now + left else nil)
	end
end

-- Put every pass and boost into the game (call after anything changes).
local function applyPerks(player: Player)
	local state = states[player]
	if not state then
		return
	end
	local m = Config.Monetization
	local boosts = state.Boosts
	EconomyService.SetIncomeMultiplier(player, "DoubleMoney", if hasPass(player, "DoubleMoney") then m.DoubleMoney else nil)
	EconomyService.SetIncomeMultiplier(player, "VIP", if hasPass(player, "VIP") then m.VipMoney else nil)
	EconomyService.SetIncomeMultiplier(player, "BoostMoney", if (boosts.Money or 0) > 0 then m.BoostMoney else nil)
	SpeedService.SetGainMultiplier(player, "DoubleSpeed", if hasPass(player, "DoubleSpeed") then m.DoubleSpeed else nil)
	SpeedService.SetGainMultiplier(player, "VIP", if hasPass(player, "VIP") then m.VipSpeed else nil)
	SpeedService.SetGainMultiplier(player, "BoostSpeed", if (boosts.Speed or 0) > 0 then m.BoostSpeed else nil)
	PetService.SetHatchTimeMultiplier(player, if hasPass(player, "FastHatch") then m.FastHatchMultiplier else 1)
	EconomyService.SetAutoCollect(player, hasPass(player, "AutoCollect"))
	local luck = currentLuck(player)
	PetService.SetLuck(player, luck)
	player:SetAttribute("Luck", luck)
	for _, item in Config.Shop.Items do
		if item.Kind == "Pass" then
			player:SetAttribute(`Pass_{item.Key}`, if hasPass(player, item.Key) then true else nil)
		end
	end
	setBoostAttributes(player, state)
	updateVipTag(player)
end

-- Copy the boost timers into the save record.
local function storeBoosts(player: Player, state: PlayerState)
	local data = DataService.GetData(player)
	if data and state.Loaded then
		data.Boosts = table.clone(state.Boosts)
	end
end

---------------------------------------------------------------------------
-- Giving items
---------------------------------------------------------------------------

local function thank(player: Player, item: Config.ShopItem, text: string)
	notify(player, text, "purchase")
	Net.event(Net.Names.PurchaseThanks):FireClient(player, item.Icon, item.Name)
end

local function grantPass(player: Player, item: Config.ShopItem, simulated: boolean)
	local state = states[player]
	if not state or state.Passes[item.Key] then
		return
	end
	state.Passes[item.Key] = true
	if simulated then
		state.Simulated[item.Key] = true
	end
	applyPerks(player)
	thank(player, item, `🎉 Thank you! {item.Icon} {item.Name} is yours forever!`)
end

-- Give a developer product. Returns true if it was given.
local function grantProduct(player: Player, item: Config.ShopItem): boolean
	local state = states[player]
	if not state then
		return false
	end
	local m = Config.Monetization
	local boost = BOOST_OF[item.Key]
	if boost then
		local left = state.Boosts[boost] or 0
		state.Boosts[boost] = math.min(left + m.BoostMinutes * 60, m.MaxBoostMinutes * 60)
		applyPerks(player)
		storeBoosts(player, state)
		local minutes = math.ceil(state.Boosts[boost] / 60)
		thank(player, item, `{item.Icon} {BOOST_LABELS[boost]} is ON! {minutes} minutes left.`)
	elseif item.Key == "InstantHatch" then
		PetService.FinishHatching(player)
		thank(player, item, "🥚 All your eggs are ready! Hold E on them to hatch.")
	elseif item.Key == "ServerLuck" then
		serverLuckLeft = math.min(serverLuckLeft + m.ServerLuckMinutes * 60, m.MaxBoostMinutes * 60)
		Workspace:SetAttribute("ServerLuckEndsAt", Workspace:GetServerTimeNow() + serverLuckLeft)
		for other in states do
			applyPerks(other)
		end
		thank(player, item, "🌟 Thank you! Server Luck is ON for everyone!")
		Notify.all(`🌟 {player.DisplayName} bought SERVER LUCK! 2x luck for everyone for {m.ServerLuckMinutes} minutes!`, "epic")
	elseif item.Key == "BotFreeze" then
		BotService.Freeze(m.FreezeSeconds)
		thank(player, item, "🧊 Every shark is frozen! Go grab those eggs!")
		Notify.all(`🧊 {player.DisplayName} froze every shark for {m.FreezeSeconds} seconds!`, "epic")
	elseif m.CashMinutes[item.Key] then
		local income = EconomyService.GetIncomePerSecond(player)
		local cash = math.floor(math.max(income * m.CashMinutes[item.Key] * 60, m.CashMinimum[item.Key] or 0))
		EconomyService.AddMoney(player, cash)
		thank(player, item, `{item.Icon} +${Format.short(cash)}! Thank you!`)
	else
		warn(`[{Config.GameName}] [Shop] No code for product "{item.Key}"`)
		return false
	end
	return true
end

---------------------------------------------------------------------------
-- Roblox purchase callbacks
---------------------------------------------------------------------------

local function processReceipt(receipt: { [string]: any }): Enum.ProductPurchaseDecision
	local player = Players:GetPlayerByUserId(receipt.PlayerId)
	if not player then
		return Enum.ProductPurchaseDecision.NotProcessedYet -- Roblox will ask again when they're back
	end
	-- Wait (a little) for their save to load.
	local waited = 0
	while not DataService.IsLoaded(player) and player.Parent and waited < 15 do
		waited += task.wait(0.5)
	end
	local data = DataService.GetData(player)
	if not data or not states[player] then
		return Enum.ProductPurchaseDecision.NotProcessedYet
	end
	local purchaseId = tostring(receipt.PurchaseId)
	if data.ProcessedPurchases[purchaseId] then
		return Enum.ProductPurchaseDecision.PurchaseGranted -- already given
	end
	local item = itemById("Product", receipt.ProductId)
	if not item then
		warn(`[{Config.GameName}] [Shop] Unknown product ID {receipt.ProductId}. Is it in Config.Shop?`)
		return Enum.ProductPurchaseDecision.NotProcessedYet
	end
	local ok, given = pcall(grantProduct, player, item)
	if not (ok and given) then
		warn(`[{Config.GameName}] [Shop] Giving {item.Key} failed: {given}`)
		return Enum.ProductPurchaseDecision.NotProcessedYet
	end
	data.ProcessedPurchases[purchaseId] = true
	if not DataService.SaveNow(player) then
		-- Not saved yet: Roblox asks again later; the ID above stops a
		-- second gift, and the next save stores it.
		return Enum.ProductPurchaseDecision.NotProcessedYet
	end
	return Enum.ProductPurchaseDecision.PurchaseGranted
end

local function checkOwnedPasses(player: Player)
	for _, item in Config.Shop.Items do
		if item.Kind == "Pass" and item.Id ~= 0 then
			for _ = 1, 3 do
				local ok, owns = pcall(MarketplaceService.UserOwnsGamePassAsync, MarketplaceService, player.UserId, item.Id)
				if ok then
					local state = states[player]
					if owns and state then
						state.Passes[item.Key] = true
					end
					break
				end
				task.wait(1)
			end
		end
	end
	applyPerks(player)
end

---------------------------------------------------------------------------
-- The buy button
---------------------------------------------------------------------------

local function onShopBuy(player: Player, key: unknown)
	if typeof(key) ~= "string" or not buyLimiter.allow(player) then
		return
	end
	local item = Config.ShopItem(key)
	local state = states[player]
	if not (item and state) or not DataService.IsLoaded(player) then
		return
	end
	if item.Kind == "Pass" and state.Passes[item.Key] then
		notify(player, `You already own {item.Name}!`, "info")
		return
	end
	if item.Key == "InstantHatch" and PetService.CountHatchingEggs(player) == 0 then
		notify(player, "No eggs are hatching on your pads right now. Place some eggs first!", "warning")
		return
	end
	if item.Id == 0 then
		if isStudio then
			notify(player, `[Studio] Simulated purchase of {item.Name} (no Robux, no real purchase).`, "info")
			if item.Kind == "Pass" then
				grantPass(player, item, true)
			else
				grantProduct(player, item)
			end
		else
			notify(player, `🛠 {item.Name} is coming soon!`, "info")
		end
		return
	end
	if item.Kind == "Pass" then
		MarketplaceService:PromptGamePassPurchase(player, item.Id)
	else
		MarketplaceService:PromptProductPurchase(player, item.Id)
	end
end

---------------------------------------------------------------------------
-- Lifecycle
---------------------------------------------------------------------------

local function onPlayerAdded(player: Player)
	states[player] = { Passes = {}, Simulated = {}, Boosts = {}, Loaded = false }
	player.CharacterAdded:Connect(function(character)
		character:WaitForChild("Head", 10)
		updateVipTag(player)
	end)
	task.spawn(checkOwnedPasses, player)
end

-- Count boosts down (only while playing) and end them.
local function tick(dt: number)
	if serverLuckLeft > 0 then
		serverLuckLeft = math.max(serverLuckLeft - dt, 0)
		if serverLuckLeft <= 0 then
			Workspace:SetAttribute("ServerLuckEndsAt", nil)
			Notify.all("🌟 Server Luck has ended.", "info")
			for player in states do
				applyPerks(player)
			end
		end
	end
	for player, state in states do
		local ended = false
		for name, left in state.Boosts do
			left -= dt
			if left <= 0 then
				state.Boosts[name] = nil
				ended = true
				notify(player, `⏰ Your {BOOST_LABELS[name] or name} boost has ended.`, "info")
			else
				state.Boosts[name] = left
			end
		end
		if ended then
			applyPerks(player)
		end
		storeBoosts(player, state)
	end
end

function MonetizationService.Init()
end

function MonetizationService.Start()
	MarketplaceService.ProcessReceipt = processReceipt
	MarketplaceService.PromptGamePassPurchaseFinished:Connect(function(player: Player, passId: number, purchased: boolean)
		local item = itemById("Pass", passId)
		if purchased and item then
			grantPass(player, item, false)
		end
	end)
	Net.event(Net.Names.ShopBuy).OnServerEvent:Connect(onShopBuy)

	Players.PlayerAdded:Connect(onPlayerAdded)
	for _, player in Players:GetPlayers() do
		task.spawn(onPlayerAdded, player)
	end
	-- Saved boost timers come back once the save is loaded.
	DataService.PlayerLoaded:Connect(function(player: Player, data)
		local state = states[player]
		if state and not state.Loaded then
			state.Loaded = true
			for name, seconds in data.Boosts do
				if BOOST_LABELS[name] and seconds > 0 then
					-- (+ anything bought while the save was loading)
					state.Boosts[name] = math.min((state.Boosts[name] or 0) + seconds, Config.Monetization.MaxBoostMinutes * 60)
				end
			end
			storeBoosts(player, state)
			applyPerks(player)
		end
	end)
	PlayerLifecycle.onLeave(function(player)
		states[player] = nil
	end)

	task.spawn(function()
		local last = os.clock()
		while true do
			task.wait(1)
			local now = os.clock()
			tick(now - last)
			last = now
		end
	end)

	DebugCommands.register("buy", function(player, args)
		local key = args[1]
		local found: Config.ShopItem? = nil
		for _, item in Config.Shop.Items do
			if key and string.lower(item.Key) == string.lower(key) then
				found = item
			end
		end
		if not found then
			local keys = {}
			for _, item in Config.Shop.Items do
				table.insert(keys, item.Key)
			end
			notify(player, `[Studio] Usage: !buy <{table.concat(keys, " | ")}>`, "info")
			return
		end
		notify(player, `[Studio] Simulated purchase of {found.Name}.`, "info")
		if found.Kind == "Pass" then
			grantPass(player, found, true)
		else
			grantProduct(player, found)
		end
	end)
	DebugCommands.register("unbuy", function(player, _args)
		local state = states[player]
		if state then
			for key in state.Simulated do
				state.Passes[key] = nil
			end
			state.Simulated = {}
			state.Boosts = {}
			applyPerks(player)
			storeBoosts(player, state)
			notify(player, "[Studio] Simulated passes and your boosts were removed.", "info")
		end
	end)
end

return MonetizationService
