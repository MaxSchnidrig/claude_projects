--!strict
--[[
	DataService
	===========
	Saves and loads each player's progress with DataStoreService.

	What is saved (one record per player, key "Player_<UserId>"):
	  Money (wallet + money waiting on the collect pad), Speed stat, treadmill
	  tier, pads bought, every egg/pet on the pads, the eggs in the hotbar
	  inventory, and (for the Robux
	  milestone) the IDs of processed purchases.

	How it stays safe:
	  - SESSION LOCK: when you join, your record is marked "open on server X".
	    Another server won't load it while that lock is fresh, so two servers
	    can never overwrite each other. Every save refreshes the lock; leaving
	    removes it. A lock older than Config.Data.LockStaleSeconds belongs to a
	    crashed server and may be taken over.
	  - NEVER OVERWRITE ON FAILED LOAD: if loading fails (after retries), the
	    player is kicked with a friendly message and nothing is written.
	    Data is only collected from the game after it was loaded and applied.
	  - RETRIES with growing waits for every DataStore call.
	  - SAVES: every Config.Data.AutoSaveInterval seconds, when a player
	    leaves, and for everyone when the server shuts down (BindToClose).
	  - Studio uses a separate DataStore (Config.Data.StudioStoreName).
	  - If DataStores aren't available in Studio (API access off), the game
	    still runs, without saving, and says so in Output.

	Studio-only test commands:
		!save     save your data right now
		!wipe     reset your progress to a brand-new player (and save that)
		!tutorial show the new-player tutorial again

	Public interface:
		DataService.GetData(player) -> SaveData?    -- the live record (nil until loaded)
		DataService.IsLoaded(player) -> boolean
		DataService.SaveNow(player) -> boolean      -- yields; true if saved (for purchases later)
]]

local DataStoreService = game:GetService("DataStoreService")
local HttpService = game:GetService("HttpService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Config = require(ReplicatedStorage.Shared.Config)
local Constants = require(ReplicatedStorage.Shared.Constants)
local Net = require(ReplicatedStorage.Shared.Net)
local Notify = require(script.Parent.Parent.Util.Notify)
local DebugCommands = require(script.Parent.Parent.Util.DebugCommands)
local PlayerLifecycle = require(script.Parent.Parent.Util.PlayerLifecycle)
local EconomyService = require(script.Parent.EconomyService)
local EggService = require(script.Parent.EggService)
local Fish = require(ReplicatedStorage.Shared.Fish)
local PetService = require(script.Parent.PetService)
local PlotService = require(script.Parent.PlotService)
local RewardService = require(script.Parent.RewardService)
local SpeedService = require(script.Parent.SpeedService)
local UpgradeService = require(script.Parent.UpgradeService)

-- 2: eggs remember their zone (EggInventory entries are { Rarity, Zone }),
--    pets are fish from Config.Fish (old pets are converted when loading).
-- 3: walk speed became a straight line of the Speed stat (1,000 Speed = +1
--    walk speed). Old Speed stats are converted so you keep your walk speed.
local DATA_VERSION = 3

-- The walk speed formula before version 3: 16 + 0.18 * stat ^ 0.4 (cap 140).
local function convertOldSpeedStat(oldStat: number): number
	local walk = math.min(16 + 0.18 * math.max(oldStat, 0) ^ 0.4, 140)
	return math.max(0, math.floor((walk - Config.Speed.BaseWalkSpeed) / Config.Speed.Factor))
end

export type SaveData = {
	Version: number,
	Money: number,
	SpeedStat: number,
	TreadmillTier: number,
	PadsBought: number,
	Pads: { PetService.SavedPadItem },
	EggInventory: { EggService.InventoryEgg }, -- eggs in the hotbar: { Rarity, Zone }
	ProcessedPurchases: { [string]: boolean },
	Rewards: RewardService.SavedRewards, -- Index (found fish, claimed rewards) and the Daily Gift
	TutorialDone: boolean,
	LastSave: number, -- os.time() of the last save (0 = never saved)
	Lock: { Session: string, Time: number }?,
}

type Profile = {
	Key: string,
	Data: SaveData,
	Applied: boolean, -- true once the data was put into the game
	Saving: boolean, -- a save is running right now
	Released: boolean, -- lock removed; never save this profile again
}

local DataService = {}
DataService.Name = "DataService"

-- A unique ID for THIS server (game.JobId is empty in Studio).
local SESSION_ID = HttpService:GenerateGUID(false)

local store: DataStore? = nil
local enabled = true
local profiles: { [Player]: Profile } = {}
local activeSaves = 0 -- saves running right now (shutdown waits for these)

local function log(message: string)
	if Config.Debug then
		print(`[{Config.GameName}] [Data] {message}`)
	end
end

local function notify(player: Player, message: string, kind: string?)
	Notify.send(player, message, kind)
end

---------------------------------------------------------------------------
-- The data record
---------------------------------------------------------------------------

local function defaultData(): SaveData
	return {
		Version = DATA_VERSION,
		Money = Config.Economy.StartingMoney,
		SpeedStat = Config.Speed.StartingStat,
		TreadmillTier = 1,
		PadsBought = 0,
		Pads = {},
		EggInventory = {},
		ProcessedPurchases = {},
		Rewards = { Found = {}, Claimed = {}, ZonesClaimed = {}, LastDailyGift = 0 },
		TutorialDone = false,
		LastSave = 0,
		Lock = nil,
	}
end

-- A finite number >= 0, or the default.
local function cleanNumber(value: unknown, default: number): number
	if typeof(value) == "number" and value == value and value ~= math.huge and value >= 0 then
		return value
	end
	return default
end

-- Turn whatever is stored (maybe nil, maybe an old version, maybe broken)
-- into a complete, valid record. Missing fields get their default value.
local function reconcile(raw: unknown): SaveData
	local data = defaultData()
	if typeof(raw) ~= "table" then
		return data
	end
	local old = raw :: any
	data.Money = cleanNumber(old.Money, data.Money)
	data.SpeedStat = cleanNumber(old.SpeedStat, data.SpeedStat)
	if cleanNumber(old.Version, 0) < 3 and cleanNumber(old.LastSave, 0) > 0 then
		data.SpeedStat = convertOldSpeedStat(data.SpeedStat)
	end
	data.TreadmillTier = math.clamp(math.floor(cleanNumber(old.TreadmillTier, 1)), 1, #Config.Treadmill.Tiers)
	data.PadsBought = math.floor(cleanNumber(old.PadsBought, 0))
	data.LastSave = cleanNumber(old.LastSave, 0)
	-- Players who saved before the tutorial existed don't need it.
	data.TutorialDone = old.TutorialDone == true or (old.TutorialDone == nil and data.LastSave > 0)

	if typeof(old.Pads) == "table" then
		for _, entry in old.Pads do
			if typeof(entry) == "table" and typeof(entry.Pad) == "number" and typeof(entry.Kind) == "string" then
				table.insert(data.Pads, {
					Pad = entry.Pad,
					Kind = entry.Kind,
					Rarity = if typeof(entry.Rarity) == "string" then entry.Rarity else nil,
					Zone = if typeof(entry.Zone) == "number" then entry.Zone else nil,
					SecondsLeft = if typeof(entry.SecondsLeft) == "number" then entry.SecondsLeft else nil,
					Name = if typeof(entry.Name) == "string" then entry.Name else nil,
					Level = if typeof(entry.Level) == "number" then entry.Level else nil,
				})
			end
		end
	end
	if typeof(old.EggInventory) == "table" then
		for _, egg in old.EggInventory do
			if #data.EggInventory >= Config.Eggs.MaxInventory then
				break
			end
			if typeof(egg) == "table" and typeof(egg.Rarity) == "string" and typeof(egg.Zone) == "number" then
				table.insert(data.EggInventory, { Rarity = egg.Rarity, Zone = egg.Zone })
			elseif typeof(egg) == "string" then
				-- Version 1 saved only the rarity: give it the zone where
				-- that rarity is most common.
				table.insert(data.EggInventory, { Rarity = egg, Zone = Fish.likelyZone(egg) })
			end
		end
	end
	if typeof(old.Rewards) == "table" then
		local rewards = old.Rewards
		for _, field in { "Found", "Claimed" } do
			if typeof(rewards[field]) == "table" then
				for _, name in rewards[field] do
					if typeof(name) == "string" then
						table.insert((data.Rewards :: any)[field], name)
					end
				end
			end
		end
		if typeof(rewards.ZonesClaimed) == "table" then
			for _, zoneIndex in rewards.ZonesClaimed do
				if typeof(zoneIndex) == "number" then
					table.insert(data.Rewards.ZonesClaimed, zoneIndex)
				end
			end
		end
		data.Rewards.LastDailyGift = cleanNumber(rewards.LastDailyGift, 0)
	end
	if typeof(old.ProcessedPurchases) == "table" then
		for id, value in old.ProcessedPurchases do
			if typeof(id) == "string" and value == true then
				data.ProcessedPurchases[id] = true
			end
		end
	end
	if typeof(old.Lock) == "table" and typeof(old.Lock.Session) == "string" and typeof(old.Lock.Time) == "number" then
		data.Lock = { Session = old.Lock.Session, Time = old.Lock.Time }
	end
	return data
end

---------------------------------------------------------------------------
-- DataStore helpers
---------------------------------------------------------------------------

-- Wait until Roblox allows another UpdateAsync request (at most 10 seconds).
local function waitForBudget()
	local waited = 0
	while
		DataStoreService:GetRequestBudgetForRequestType(Enum.DataStoreRequestType.UpdateAsync) < 1
		and waited < 10
	do
		waited += task.wait(0.5)
	end
end

-- Run `call` until it works, waiting longer after each failure.
local function withRetries(label: string, call: () -> ()): boolean
	local delay = Config.Data.RetryDelay
	for attempt = 1, Config.Data.MaxRetries do
		waitForBudget()
		local errorText = ""
		local ok = xpcall(call, function(err)
			errorText = tostring(err)
		end)
		if ok then
			return true
		end
		warn(`[{Config.GameName}] [Data] {label} failed (try {attempt}/{Config.Data.MaxRetries}): {errorText}`)
		if attempt < Config.Data.MaxRetries then
			task.wait(delay)
			delay *= 2
		end
	end
	return false
end

-- Load a record and lock it to this server. Returns nil if it failed or is
-- still locked by another (live) server.
local function loadAndLock(key: string): (SaveData?, string?)
	local activeStore = store :: DataStore
	for _ = 1, Config.Data.LockRetries do
		local result: SaveData? = nil
		local lockedElsewhere = false
		local ok = withRetries(`Loading {key}`, function()
			activeStore:UpdateAsync(key, function(old: unknown)
				local data = reconcile(old)
				local lock = data.Lock
				local now = os.time()
				if lock and lock.Session ~= SESSION_ID and now - lock.Time < Config.Data.LockStaleSeconds then
					lockedElsewhere = true
					result = nil
					return nil -- don't change anything
				end
				lockedElsewhere = false
				data.Lock = { Session = SESSION_ID, Time = now }
				result = data
				return data
			end)
		end)
		if not ok then
			return nil, "error"
		end
		if result then
			return result, nil
		end
		if lockedElsewhere then
			log(`{key} is still open on another server, waiting...`)
			task.wait(Config.Data.LockRetryDelay)
		end
	end
	return nil, "locked"
end

---------------------------------------------------------------------------
-- Moving data between the record and the game
---------------------------------------------------------------------------

-- Put loaded data into the game (money, speed, treadmill, pads, pets).
local function apply(player: Player, data: SaveData)
	EconomyService.SetMoney(player, data.Money)
	SpeedService.SetStat(player, data.SpeedStat)
	SpeedService.SetTreadmillTier(player, data.TreadmillTier)

	-- Pets need the player's plot. It's normally assigned right away.
	local waited = 0
	while not PlotService.GetPlot(player) and player.Parent and waited < 10 do
		waited += task.wait(0.2)
	end
	UpgradeService.SetPadsBought(player, data.PadsBought)
	PetService.ImportPads(player, data.Pads)
	EggService.SetInventory(player, data.EggInventory)
	-- After the pads: fish already on them count as found in the Index.
	RewardService.Import(player, data.Rewards)
	-- New players get the tutorial (the client runs it).
	player:SetAttribute(Constants.Attributes.ShowTutorial, not data.TutorialDone)
end

-- Copy the player's current progress from the game into the record.
local function collect(player: Player, profile: Profile)
	if not profile.Applied then
		return -- never save something we didn't load first
	end
	local data = profile.Data
	data.Money = EconomyService.GetMoneyForSave(player)
	data.SpeedStat = SpeedService.GetStat(player)
	data.TreadmillTier = SpeedService.GetTreadmillTier(player)
	data.PadsBought = UpgradeService.GetPadsBought(player)
	data.Pads = PetService.ExportPads(player)
	data.EggInventory = EggService.GetInventory(player)
	data.Rewards = RewardService.Export(player)
end

-- Write the record. release = true also removes the session lock (leaving).
local function save(player: Player, profile: Profile, release: boolean): boolean
	if profile.Released then
		return true
	end
	-- One save at a time per player.
	while profile.Saving do
		task.wait(0.1)
	end
	if profile.Released then
		return true
	end
	profile.Saving = true
	activeSaves += 1

	local activeStore = store :: DataStore
	local snapshot = table.clone(profile.Data)
	local stolen = false
	local ok = withRetries(`Saving {profile.Key}`, function()
		activeStore:UpdateAsync(profile.Key, function(old: unknown)
			local current = reconcile(old)
			local lock = current.Lock
			if lock and lock.Session ~= SESSION_ID then
				-- Another server took over (we were probably frozen for a long
				-- time). Its data is newer, so we must NOT overwrite it.
				stolen = true
				return nil
			end
			stolen = false
			snapshot.Version = DATA_VERSION
			snapshot.LastSave = os.time()
			snapshot.Lock = if release then nil else { Session = SESSION_ID, Time = os.time() }
			return snapshot
		end)
	end)

	profile.Saving = false
	activeSaves -= 1
	if release or stolen then
		profile.Released = true
	end
	if stolen then
		warn(`[{Config.GameName}] [Data] {profile.Key} was opened on another server; not overwriting it.`)
		if player.Parent then
			player:Kick("Your game was opened on another server. Please rejoin!")
		end
		return false
	end
	if ok then
		log(`Saved {player.Name}{if release then " (left)" else ""}`)
	end
	return ok
end

---------------------------------------------------------------------------
-- Joining and leaving
---------------------------------------------------------------------------

local function onPlayerAdded(player: Player)
	local key = `Player_{player.UserId}`

	if not enabled then
		-- Studio without API access: play with fresh, unsaved data.
		local profile: Profile = { Key = key, Data = defaultData(), Applied = false, Saving = false, Released = true }
		profiles[player] = profile
		apply(player, profile.Data)
		profile.Applied = true
		notify(player, "⚠ Saving is OFF in Studio (see Output for how to turn it on).", "warning")
		return
	end

	local data, problem = loadAndLock(key)
	if not data then
		if player.Parent then
			if problem == "locked" then
				player:Kick("Your progress is still being saved on another server. Please rejoin in a minute!")
			else
				player:Kick("We couldn't load your progress right now (Roblox data problem). Please rejoin in a minute!")
			end
		end
		return
	end

	local profile: Profile = { Key = key, Data = data, Applied = false, Saving = false, Released = false }
	profiles[player] = profile

	if not player.Parent then
		-- Left while loading: just remove our lock, nothing changed.
		save(player, profile, true)
		profiles[player] = nil
		return
	end

	apply(player, data)
	profile.Applied = true
	log(`Loaded {player.Name} (money {data.Money}, speed {data.SpeedStat}, {#data.Pads} pad items)`)
	if data.LastSave > 0 then
		notify(player, "💾 Welcome back! Your progress was loaded.", "success")
	end
end

local function onBeforeLeave(player: Player)
	local profile = profiles[player]
	if not profile then
		return
	end
	-- Read everything NOW, before the other services forget this player.
	collect(player, profile)
	profiles[player] = nil
	if enabled and not profile.Released then
		task.spawn(save, player, profile, true)
	end
end

---------------------------------------------------------------------------
-- Public
---------------------------------------------------------------------------

function DataService.GetData(player: Player): SaveData?
	local profile = profiles[player]
	return if profile and profile.Applied then profile.Data else nil
end

function DataService.IsLoaded(player: Player): boolean
	local profile = profiles[player]
	return profile ~= nil and profile.Applied
end

function DataService.SaveNow(player: Player): boolean
	local profile = profiles[player]
	if not (profile and profile.Applied) then
		return false
	end
	if not enabled then
		return true
	end
	collect(player, profile)
	return save(player, profile, false)
end

---------------------------------------------------------------------------
-- Lifecycle
---------------------------------------------------------------------------

local function checkAvailability()
	local name = if RunService:IsStudio() then Config.Data.StudioStoreName else Config.Data.StoreName
	local ok, err = pcall(function()
		local candidate = DataStoreService:GetDataStore(name)
		candidate:GetAsync("__availability_check")
		store = candidate
	end)
	if ok then
		log(`Using DataStore "{name}"`)
		return
	end
	if RunService:IsStudio() then
		enabled = false
		warn(
			`[{Config.GameName}] [Data] SAVING IS OFF: DataStores aren't available in Studio ({err}).\n`
				.. "  To turn saving on: publish the place (File > Publish to Roblox), then\n"
				.. "  Home > Game Settings > Security > turn ON 'Enable Studio Access to API Services' > Save."
		)
	else
		-- A live server: keep trying per player (loads retry and kick on failure).
		warn(`[{Config.GameName}] [Data] DataStore check failed: {err}`)
		store = DataStoreService:GetDataStore(name)
	end
end

local function registerDebugCommands()
	DebugCommands.register("save", function(player, _args)
		local ok = DataService.SaveNow(player)
		notify(player, if ok then "[Studio] 💾 Saved!" else "[Studio] Save failed (see Output)")
	end)
	DebugCommands.register("tutorial", function(player, _args)
		local profile = profiles[player]
		if profile then
			profile.Data.TutorialDone = false
		end
		player:SetAttribute(Constants.Attributes.ShowTutorial, false)
		task.wait(0.1)
		player:SetAttribute(Constants.Attributes.ShowTutorial, true)
	end)
	DebugCommands.register("wipe", function(player, _args)
		local profile = profiles[player]
		if not profile then
			return
		end
		PetService.ClearPlayerPads(player)
		EconomyService.ClearWaiting(player)
		local fresh = defaultData()
		fresh.ProcessedPurchases = profile.Data.ProcessedPurchases -- never forget purchases
		profile.Data = fresh
		apply(player, fresh)
		if enabled then
			save(player, profile, false)
		end
		notify(player, "[Studio] 🧹 Your progress was reset to a brand-new player.")
	end)
end

function DataService.Init()
end

function DataService.Start()
	checkAvailability()
	registerDebugCommands()

	Players.PlayerAdded:Connect(onPlayerAdded)
	for _, player in Players:GetPlayers() do
		task.spawn(onPlayerAdded, player)
	end
	PlayerLifecycle.onBeforeLeave(onBeforeLeave)

	-- The client says the tutorial is done. Harmless if faked: it only hides
	-- the tutorial for that player.
	Net.event(Net.Names.TutorialFinished).OnServerEvent:Connect(function(player: Player)
		local profile = profiles[player]
		if profile then
			profile.Data.TutorialDone = true
		end
		player:SetAttribute(Constants.Attributes.ShowTutorial, false)
	end)

	-- Autosave everyone, spread out a little so requests don't all hit at once.
	task.spawn(function()
		while true do
			task.wait(Config.Data.AutoSaveInterval)
			if enabled then
				for player, profile in profiles do
					if profile.Applied and not profile.Released and player.Parent then
						collect(player, profile)
						task.spawn(save, player, profile, false)
						task.wait(0.5)
					end
				end
			end
		end
	end)

	-- Server shutting down: save everyone and wait (Roblox allows ~30 s).
	game:BindToClose(function()
		if not enabled then
			return
		end
		for player, profile in profiles do
			collect(player, profile)
			task.spawn(save, player, profile, true)
		end
		-- Wait for EVERY running save, including those started by players
		-- leaving just now.
		task.wait(0.1)
		local waited = 0
		while activeSaves > 0 and waited < 25 do
			waited += task.wait(0.2)
		end
		log(`Shutdown save finished ({activeSaves} still running)`)
	end)
end

return DataService
