--!strict
--[[
	RewardService
	=============
	Free rewards:

	INDEX (📖 Index window)
	  - Every fish you hatch is "found" (saved). A newly found fish has a small
	    reward to claim (cash + Speed, Config.IndexFishReward).
	  - Finding all 8 fish of a zone unlocks a zone reward (Config.IndexZoneReward).
	  - The client gets the list with the "IndexSync" remote and asks to claim
	    with "IndexClaim". The server checks everything (found? already
	    claimed? not spamming?) before paying.
	  - Players who saved before the Index existed get the fish on their pads
	    counted as found.

	DAILY GIFT (🛒 Shop window)
	  - Claimable once every Config.DailyGift.Cooldown seconds ("DailyGiftClaim").
	  - One random reward from Config.DailyGift.Rewards: cash or Speed (both
	    grow with your progress) or a Rare egg in your hotbar.
	  - The player attribute "DailyGiftAt" = the time (seconds since 1970, like
	    os.time()) when the next gift is ready, so the Shop can show a countdown.

	Public interface:
		RewardService.Export(player) -> SavedRewards      -- saving (DataService)
		RewardService.Import(player, saved)               -- loading (after the pads are loaded)
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = require(ReplicatedStorage.Shared.Config)
local Fish = require(ReplicatedStorage.Shared.Fish)
local Format = require(ReplicatedStorage.Shared.Format)
local Net = require(ReplicatedStorage.Shared.Net)
local DebugCommands = require(script.Parent.Parent.Util.DebugCommands)
local Notify = require(script.Parent.Parent.Util.Notify)
local PlayerLifecycle = require(script.Parent.Parent.Util.PlayerLifecycle)
local RateLimiter = require(script.Parent.Parent.Util.RateLimiter)
local EconomyService = require(script.Parent.EconomyService)
local EggService = require(script.Parent.EggService)
local PetService = require(script.Parent.PetService)
local SpeedService = require(script.Parent.SpeedService)

export type SavedRewards = {
	Found: { string }, -- names of every fish ever hatched
	Claimed: { string }, -- fish whose Index reward was claimed
	ZonesClaimed: { number }, -- zones whose completion reward was claimed
	LastDailyGift: number, -- os.time() of the last daily gift (0 = never)
}

type State = {
	Found: { [string]: boolean },
	Claimed: { [string]: boolean },
	ZonesClaimed: { [number]: boolean },
	LastDailyGift: number,
}

local RewardService = {}
RewardService.Name = "RewardService"

local states: { [Player]: State } = {}
local claimLimiter = RateLimiter.new(6, 1)
local giftLimiter = RateLimiter.new(2, 1)
local rng = Random.new()

local function notify(player: Player, message: string, kind: string?)
	Notify.send(player, message, kind)
end

local function setKeys(list: { string }): { [string]: boolean }
	local result: { [string]: boolean } = {}
	for _, name in list do
		-- Stored by fish Id (old saves used the same text, so nothing changes).
		local fish = Fish.byName(name)
		if fish then
			result[fish.Id] = true
		end
	end
	return result
end

local function keys(map: { [string]: boolean }): { string }
	local result: { string } = {}
	for name in map do
		table.insert(result, name)
	end
	table.sort(result)
	return result
end

-- Send the player's Index to their screen.
local function sync(player: Player)
	local state = states[player]
	if not state then
		return
	end
	local zones: { number } = {}
	for zoneIndex in state.ZonesClaimed do
		table.insert(zones, zoneIndex)
	end
	Net.event(Net.Names.IndexSync):FireClient(player, {
		Found = keys(state.Found),
		Claimed = keys(state.Claimed),
		ZonesClaimed = zones,
	})
end

local function updateGiftAttribute(player: Player, state: State)
	player:SetAttribute("DailyGiftAt", state.LastDailyGift + Config.DailyGift.Cooldown)
end

---------------------------------------------------------------------------
-- Index
---------------------------------------------------------------------------

local function discover(player: Player, fishKey: string, quiet: boolean?)
	local state = states[player]
	local fish = Fish.byName(fishKey)
	if not (state and fish) or state.Found[fish.Id] then
		return
	end
	state.Found[fish.Id] = true
	if not quiet then
		notify(player, `📖 New fish in your Index: {fish.Name}! Open the Index to claim a reward.`, "epic")
		sync(player)
	end
end

local function zoneComplete(state: State, zoneIndex: number): boolean
	local list = Fish.inZone(zoneIndex)
	if #list == 0 then
		return false
	end
	for _, fish in list do
		if not state.Found[fish.Id] then
			return false
		end
	end
	return true
end

local function pay(player: Player, cash: number, speed: number)
	if cash > 0 then
		EconomyService.AddMoney(player, cash)
	end
	if speed > 0 then
		SpeedService.AddStat(player, speed)
	end
end

local function claimFish(player: Player, state: State, fishKey: string): boolean
	local fish = Fish.byName(fishKey)
	if not (fish and state.Found[fish.Id]) or state.Claimed[fish.Id] then
		return false
	end
	state.Claimed[fish.Id] = true
	local cash, speed = Config.IndexFishReward(fish)
	pay(player, cash, speed)
	return true
end

local function claimZone(player: Player, state: State, zoneIndex: number): boolean
	if not Config.Zones[zoneIndex] or state.ZonesClaimed[zoneIndex] or not zoneComplete(state, zoneIndex) then
		return false
	end
	state.ZonesClaimed[zoneIndex] = true
	local cash, speed = Config.IndexZoneReward(zoneIndex)
	pay(player, cash, speed)
	notify(player, `🏆 {Config.Zones[zoneIndex].Name} complete! +${Format.short(cash)} and +⚡{Format.short(speed)}`, "purchase")
	return true
end

local function onClaim(player: Player, kind: unknown, value: unknown)
	local state = states[player]
	if not state or not claimLimiter.allow(player) then
		return
	end
	if kind == "Sync" then
		sync(player)
		return
	elseif kind == "Fish" and typeof(value) == "string" then
		if claimFish(player, state, value) then
			local fish = Fish.byName(value) :: Config.FishConfig
			local cash, speed = Config.IndexFishReward(fish)
			notify(player, `📖 {fish.Name}: +${Format.short(cash)} and +⚡{Format.short(speed)}`, "purchase")
		end
	elseif kind == "Zone" and typeof(value) == "number" then
		claimZone(player, state, math.floor(value))
	elseif kind == "All" then
		local totalCash, totalSpeed, count = 0, 0, 0
		for name in state.Found do
			if not state.Claimed[name] then
				local fish = Fish.byName(name)
				if fish and claimFish(player, state, name) then
					local cash, speed = Config.IndexFishReward(fish)
					totalCash += cash
					totalSpeed += speed
					count += 1
				end
			end
		end
		if count > 0 then
			notify(player, `📖 Claimed {count} rewards: +${Format.short(totalCash)} and +⚡{Format.short(totalSpeed)}`, "purchase")
		end
		for zoneIndex in Config.Zones do
			claimZone(player, state, zoneIndex)
		end
	else
		return
	end
	sync(player)
end

---------------------------------------------------------------------------
-- Daily gift
---------------------------------------------------------------------------

local function pickReward(): Config.DailyReward
	local total = 0
	for _, reward in Config.DailyGift.Rewards do
		total += reward.Weight
	end
	local roll = rng:NextNumber() * total
	for _, reward in Config.DailyGift.Rewards do
		roll -= reward.Weight
		if roll < 0 then
			return reward
		end
	end
	return Config.DailyGift.Rewards[1]
end

local function giveCash(player: Player, reward: Config.DailyReward)
	local income = EconomyService.GetIncomePerSecond(player)
	local cash = math.floor(math.max(reward.Minimum or 0, income * (reward.Seconds or 0)))
	EconomyService.AddMoney(player, cash)
	notify(player, `🎁 Daily Gift: +${Format.short(cash)}!`, "purchase")
end

local function onDailyGift(player: Player)
	local state = states[player]
	if not state or not giftLimiter.allow(player) then
		return
	end
	local now = os.time()
	if now < state.LastDailyGift + Config.DailyGift.Cooldown then
		notify(player, "Your next Daily Gift isn't ready yet!", "warning")
		return
	end
	state.LastDailyGift = now
	updateGiftAttribute(player, state)

	local reward = pickReward()
	if reward.Kind == "Speed" then
		local perSecond = SpeedService.GetGainPerTick(player) / Config.Treadmill.GainInterval
		local speed = math.floor(math.max(reward.Minimum or 0, perSecond * (reward.Seconds or 0)))
		SpeedService.AddStat(player, speed)
		notify(player, `🎁 Daily Gift: +⚡{Format.short(speed)} Speed!`, "purchase")
	elseif reward.Kind == "Egg" then
		local rarity = reward.Rarity or "Rare"
		if EggService.AddToInventory(player, rarity, Fish.likelyZone(rarity)) then
			notify(player, `🎁 Daily Gift: a {rarity} Egg! It's in your hotbar.`, "purchase")
		else
			-- Hotbar full: cash instead.
			giveCash(player, { Kind = "Cash", Weight = 0, Seconds = 300, Minimum = 500 })
		end
	else
		giveCash(player, reward)
	end
end

---------------------------------------------------------------------------
-- Saving
---------------------------------------------------------------------------

function RewardService.Export(player: Player): SavedRewards
	local state = states[player]
	if not state then
		return { Found = {}, Claimed = {}, ZonesClaimed = {}, LastDailyGift = 0 }
	end
	local zones: { number } = {}
	for zoneIndex in state.ZonesClaimed do
		table.insert(zones, zoneIndex)
	end
	return {
		Found = keys(state.Found),
		Claimed = keys(state.Claimed),
		ZonesClaimed = zones,
		LastDailyGift = state.LastDailyGift,
	}
end

function RewardService.Import(player: Player, saved: SavedRewards)
	local zones: { [number]: boolean } = {}
	for _, zoneIndex in saved.ZonesClaimed do
		zones[zoneIndex] = true
	end
	local state: State = {
		Found = setKeys(saved.Found),
		Claimed = setKeys(saved.Claimed),
		ZonesClaimed = zones,
		LastDailyGift = saved.LastDailyGift,
	}
	states[player] = state
	-- Fish already on the pads count as found (older saves had no Index).
	for _, entry in PetService.ExportPads(player) do
		if entry.Kind == "Pet" and entry.Name then
			discover(player, entry.Name, true)
		end
	end
	updateGiftAttribute(player, state)
	sync(player)
end

---------------------------------------------------------------------------
-- Lifecycle
---------------------------------------------------------------------------

function RewardService.Init()
end

function RewardService.Start()
	PetService.PetHatched:Connect(function(player: Player, petName: string)
		discover(player, petName)
	end)
	Net.event(Net.Names.IndexClaim).OnServerEvent:Connect(onClaim)
	Net.event(Net.Names.DailyGiftClaim).OnServerEvent:Connect(onDailyGift)
	PlayerLifecycle.onLeave(function(player)
		states[player] = nil
	end)

	DebugCommands.register("gift", function(player, _args)
		local state = states[player]
		if state then
			state.LastDailyGift = 0
			updateGiftAttribute(player, state)
			notify(player, "[Studio] Your Daily Gift is ready again.", "info")
		end
	end)
	DebugCommands.register("findall", function(player, args)
		local zoneIndex = tonumber(args[1])
		for _, fish in Config.Fish do
			if zoneIndex == nil or fish.Zone == zoneIndex then
				discover(player, fish.Id, true)
			end
		end
		sync(player)
		notify(player, "[Studio] Fish added to your Index.", "info")
	end)

end

return RewardService
