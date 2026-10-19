--!strict
--[[
	RewardService
	=============
	Free rewards:

	INDEX (📖 Index window)
	  - Every fish you hatch is "found" (saved). A newly found fish has a
	    reward to claim: minutes of YOUR current income + minutes of YOUR
	    treadmill, so it always feels big (Config.IndexFishReward).
	  - LOCKED IN: a reward's value is calculated the moment the fish is
	    found (or the zone is completed) and saved ("Locked"), so waiting to
	    claim later never gives more. Fish found before this existed get
	    their value locked when the player joins.
	  - Finding all 8 fish of a zone unlocks a zone reward: lots of cash and
	    Speed, a free egg from that zone, and a PERMANENT income bonus
	    (+10% per completed zone, Config.IndexZoneReward). The bonus is an
	    income multiplier ("Index") in EconomyService; the player attribute
	    "IndexBonus" (e.g. 0.3 = +30%) shows it in the Index window.
	  - The player attribute "TrainingPerSecond" (Speed per second on your
	    treadmill) lets the Index window show the exact reward amounts.
	  - After a claim the server fires "IndexRewarded" so the client can
	    play the coin burst + popup.
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
local RunService = game:GetService("RunService")

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
	Locked: { SavedLock }, -- unclaimed rewards, value locked in when earned
	LastDailyGift: number, -- os.time() of the last daily gift (0 = never)
}

-- Key = the fish's Id, or "Zone3" for zone 3's completion reward.
-- EggCash = cash given instead of the zone egg if the hotbar is full.
export type SavedLock = { Key: string, Cash: number, Speed: number, EggCash: number }

type Lock = { Cash: number, Speed: number, EggCash: number }

type State = {
	Found: { [string]: boolean },
	Claimed: { [string]: boolean },
	ZonesClaimed: { [number]: boolean },
	Locked: { [string]: Lock },
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
	local locked: { [string]: { Cash: number, Speed: number } } = {}
	for key, lock in state.Locked do
		locked[key] = { Cash = lock.Cash, Speed = lock.Speed }
	end
	Net.event(Net.Names.IndexSync):FireClient(player, {
		Found = keys(state.Found),
		Claimed = keys(state.Claimed),
		ZonesClaimed = zones,
		Locked = locked,
	})
end

local function updateGiftAttribute(player: Player, state: State)
	player:SetAttribute("DailyGiftAt", state.LastDailyGift + Config.DailyGift.Cooldown)
end

---------------------------------------------------------------------------
-- Index
---------------------------------------------------------------------------

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

-- The player's current progress: (money per second, treadmill Speed per
-- second, Speed stat).
local function rates(player: Player): (number, number, number)
	local income = EconomyService.GetIncomePerSecond(player)
	local speedPerSecond = SpeedService.GetGainPerTick(player) / Config.Treadmill.GainInterval
	return income, speedPerSecond, SpeedService.GetStat(player)
end

local function countZones(state: State): number
	local count = 0
	for _ in state.ZonesClaimed do
		count += 1
	end
	return count
end

-- The permanent income bonus from completed zones.
local function applyIndexBonus(player: Player, state: State)
	local zones = countZones(state)
	EconomyService.SetIncomeMultiplier(player, "Index", if zones > 0 then Config.IndexIncomeMultiplier(zones) else nil)
	player:SetAttribute("IndexBonus", Config.IndexIncomeMultiplier(zones) - 1)
end

local function zoneKey(zoneIndex: number): string
	return `Zone{zoneIndex}`
end

-- Lock in the value of every reward that is earned but not claimed and has
-- no value yet, using the player's progress RIGHT NOW.
local function lockRewards(player: Player, state: State)
	local income, speedPerSecond, speedStat = rates(player)
	for fishId in state.Found do
		local fish = Fish.byId(fishId)
		if fish and not state.Claimed[fishId] and not state.Locked[fishId] then
			local cash, speed = Config.IndexFishReward(fish, income, speedPerSecond, speedStat)
			state.Locked[fishId] = { Cash = cash, Speed = speed, EggCash = 0 }
		end
	end
	for zoneIndex in Config.Zones do
		local key = zoneKey(zoneIndex)
		if not state.ZonesClaimed[zoneIndex] and not state.Locked[key] and zoneComplete(state, zoneIndex) then
			local cash, speed = Config.IndexZoneReward(zoneIndex, income, speedPerSecond, speedStat)
			local eggCash = math.floor(income * Config.Index.FullHotbarEggCashMinutes * 60 + 0.5)
			state.Locked[key] = { Cash = cash, Speed = speed, EggCash = eggCash }
		end
	end
end

local function discover(player: Player, fishKey: string, quiet: boolean?)
	local state = states[player]
	local fish = Fish.byName(fishKey)
	if not (state and fish) or state.Found[fish.Id] then
		return
	end
	state.Found[fish.Id] = true
	lockRewards(player, state)
	if not quiet then
		notify(player, `📖 New fish in your Index: {fish.Name}! Open the Index to claim a reward.`, "epic")
		sync(player)
	end
end

-- Returns (claimed?, cash, speed).
local function claimFish(player: Player, state: State, fishKey: string): (boolean, number, number)
	local fish = Fish.byName(fishKey)
	if not (fish and state.Found[fish.Id]) or state.Claimed[fish.Id] then
		return false, 0, 0
	end
	lockRewards(player, state) -- (only fills in a value if one is missing)
	local lock = state.Locked[fish.Id]
	state.Claimed[fish.Id] = true
	state.Locked[fish.Id] = nil
	local cash, speed = lock.Cash, lock.Speed
	pay(player, cash, speed)
	return true, cash, speed
end

-- Returns (claimed?, cash, speed, egg rarity or nil if the hotbar was full).
local function claimZone(player: Player, state: State, zoneIndex: number): (boolean, number, number, string?)
	if not Config.Zones[zoneIndex] or state.ZonesClaimed[zoneIndex] or not zoneComplete(state, zoneIndex) then
		return false, 0, 0, nil
	end
	lockRewards(player, state) -- (only fills in a value if one is missing)
	local key = zoneKey(zoneIndex)
	local lock = state.Locked[key]
	state.ZonesClaimed[zoneIndex] = true
	state.Locked[key] = nil
	local cash, speed = lock.Cash, lock.Speed
	local eggRarity = Config.IndexZoneEggRarity(zoneIndex)
	local egg: string? = eggRarity
	if not EggService.AddToInventory(player, eggRarity, zoneIndex) then
		-- Hotbar full: extra cash instead of the egg.
		egg = nil
		cash += lock.EggCash
		notify(player, "Your hotbar is full, so you got cash instead of the egg.", "warning")
	end
	pay(player, cash, speed)
	applyIndexBonus(player, state)
	local bonus = math.floor(countZones(state) * Config.Index.ZoneIncomeBonus * 100 + 0.5)
	local eggText = if egg then ` + a {egg} Egg` else ""
	notify(player, `🏆 {Config.Zones[zoneIndex].Name} complete! +${Format.short(cash)}, +⚡{Format.short(speed)}{eggText}. Income bonus is now +{bonus}%!`, "purchase")
	return true, cash, speed, egg
end

-- Tell the client what was just won (for the coin burst + popup).
local function celebrate(player: Player, cash: number, speed: number, eggs: { string }, zonesDone: number)
	if cash <= 0 and speed <= 0 then
		return
	end
	Net.event(Net.Names.IndexRewarded):FireClient(player, cash, speed, eggs, zonesDone * Config.Index.ZoneIncomeBonus)
end

local function onClaim(player: Player, kind: unknown, value: unknown)
	local state = states[player]
	if not state or not claimLimiter.allow(player) then
		return
	end
	if kind == "Sync" then
		sync(player)
		return
	end
	if kind == "Fish" and typeof(value) == "string" then
		local ok, cash, speed = claimFish(player, state, value)
		if ok then
			local fish = Fish.byName(value) :: Config.FishConfig
			notify(player, `📖 {fish.Name}: +${Format.short(cash)} and +⚡{Format.short(speed)}`, "purchase")
			celebrate(player, cash, speed, {}, 0)
		end
	elseif kind == "Zone" and typeof(value) == "number" then
		local ok, cash, speed, egg = claimZone(player, state, math.floor(value))
		if ok then
			celebrate(player, cash, speed, if egg then { egg } else {}, 1)
		end
	elseif kind == "All" then
		local totalCash, totalSpeed, count = 0, 0, 0
		local fishKeys: { string } = {}
		for name in state.Found do
			if not state.Claimed[name] then
				table.insert(fishKeys, name)
			end
		end
		for _, name in fishKeys do
			local ok, cash, speed = claimFish(player, state, name)
			if ok then
				totalCash += cash
				totalSpeed += speed
				count += 1
			end
		end
		if count > 0 then
			notify(player, `📖 Claimed {count} rewards: +${Format.short(totalCash)} and +⚡{Format.short(totalSpeed)}`, "purchase")
		end
		local eggs: { string } = {}
		local zonesDone = 0
		for zoneIndex in Config.Zones do
			local ok, cash, speed, egg = claimZone(player, state, zoneIndex)
			if ok then
				totalCash += cash
				totalSpeed += speed
				zonesDone += 1
				if egg then
					table.insert(eggs, egg)
				end
			end
		end
		celebrate(player, totalCash, totalSpeed, eggs, zonesDone)
	else
		return
	end
	sync(player)
end

---------------------------------------------------------------------------
-- Output summary (Studio only): example rewards at a few progress stages
---------------------------------------------------------------------------

local function printSummary()
	local stages = {
		{ Label = "Early (zone 1)", Zone = 1, Income = 15, Tier = 1 },
		{ Label = "Mid (zone 4)", Zone = 4, Income = 2_000, Tier = 4 },
		{ Label = "Late (zone 7)", Zone = 7, Income = 60_000, Tier = 7 },
		{ Label = "End (zone 10)", Zone = 10, Income = 3_000_000, Tier = 10 },
	}
	print("[Index] Example rewards (income/s and treadmill tier are example values):")
	for _, stage in stages do
		local tier = Config.Treadmill.Tiers[math.min(stage.Tier, #Config.Treadmill.Tiers)]
		local speedPerSecond = tier.Gain / Config.Treadmill.GainInterval
		-- Speed of a player who just reached this zone.
		local shark = Config.Sharks[stage.Zone]
		local speedStat = if shark then shark.SpeedStatNeeded or 0 else 0
		local list = Fish.inZone(stage.Zone)
		local fishParts: { string } = {}
		for _, fish in { list[1], list[#list] } do
			if fish then
				local cash, speed = Config.IndexFishReward(fish, stage.Income, speedPerSecond, speedStat)
				table.insert(fishParts, `{fish.Rarity} fish +${Format.short(cash)} +⚡{Format.short(speed)}`)
			end
		end
		local cash, speed, egg = Config.IndexZoneReward(stage.Zone, stage.Income, speedPerSecond, speedStat)
		print(
			`  {stage.Label}: income ${Format.short(stage.Income)}/s, Speed {Format.short(speedStat)} (zone gap {Format.short(Config.IndexSpeedGap(speedStat))}) | `
				.. table.concat(fishParts, ", ")
				.. ` | zone done +${Format.short(cash)} +⚡{Format.short(speed)} +1 {egg} Egg +{math.floor(Config.Index.ZoneIncomeBonus * 100 + 0.5)}% income`
		)
	end
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
		return { Found = {}, Claimed = {}, ZonesClaimed = {}, Locked = {}, LastDailyGift = 0 }
	end
	local zones: { number } = {}
	for zoneIndex in state.ZonesClaimed do
		table.insert(zones, zoneIndex)
	end
	local locked: { SavedLock } = {}
	for key, lock in state.Locked do
		table.insert(locked, { Key = key, Cash = lock.Cash, Speed = lock.Speed, EggCash = lock.EggCash })
	end
	return {
		Found = keys(state.Found),
		Claimed = keys(state.Claimed),
		ZonesClaimed = zones,
		Locked = locked,
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
		Locked = {},
		LastDailyGift = saved.LastDailyGift,
	}
	for _, entry in saved.Locked do
		-- Fish keys may be an old name: store them by Id.
		local fish = Fish.byName(entry.Key)
		local key = if fish then fish.Id else entry.Key
		state.Locked[key] = { Cash = entry.Cash, Speed = entry.Speed, EggCash = entry.EggCash }
	end
	states[player] = state
	-- The income bonus first, so values locked below include it.
	applyIndexBonus(player, state)
	-- Fish already on the pads count as found (older saves had no Index).
	for _, entry in PetService.ExportPads(player) do
		if entry.Kind == "Pet" and entry.Name then
			discover(player, entry.Name, true)
		end
	end
	-- Rewards earned before values were locked in get locked now.
	lockRewards(player, state)
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
	-- Keep "TrainingPerSecond" up to date so the Index shows exact rewards.
	task.spawn(function()
		while true do
			for player in states do
				local _, speedPerSecond = rates(player)
				if player:GetAttribute("TrainingPerSecond") ~= speedPerSecond then
					player:SetAttribute("TrainingPerSecond", speedPerSecond)
				end
			end
			task.wait(1)
		end
	end)
	if RunService:IsStudio() then
		printSummary()
	end

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
	DebugCommands.register("resetindex", function(player, _args)
		-- Un-claims every Index reward (found fish stay found), to test claiming again.
		local state = states[player]
		if state then
			state.Claimed = {}
			state.ZonesClaimed = {}
			state.Locked = {}
			applyIndexBonus(player, state)
			lockRewards(player, state)
			sync(player)
			notify(player, "[Studio] Index rewards can be claimed again.", "info")
		end
	end)

end

return RewardService
