--!strict
-- The title screen's server side (every public server is a lobby; Studio opens one first too).
-- A player has a list of worlds (Java's world list) and can:
--   * play one: each world has its own reserved server (created on first play; its access code is
--     in the world meta, and srv:<PrivateServerId> records owner + world key)
--   * create one: name, game mode (Survival / Hardcore), difficulty, seed
--   * delete one (its saved data is removed)
--   * let friends join a world, and join a friend's world that is running now
--
-- In Studio there is no teleporting: `open(owner, world)` (Main.server) starts the chosen world in
-- this same server instead.
--
-- Remote "Lobby":
--   C -> S { type = "state" } | { type = "play", world } | { type = "create", name, hardcore,
--          difficulty, seed } | { type = "delete", world } | { type = "setFriends", world, on }
--          | { type = "join", ownerId }
--   S -> C { type = "state", worlds = { WorldInfo }, friendsWorlds = { { userId, name, players } },
--            saving, max, studio }
--          { type = "status", text, error? }  |  { type = "created", world }

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TeleportService = game:GetService("TeleportService")
local MemoryStoreService = game:GetService("MemoryStoreService")
local TextService = game:GetService("TextService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared.Config)
local Remotes = require(Shared.Net.Remotes)
local SaveFormat = require(Shared.Persistence.SaveFormat)
local Difficulty = require(Shared.Gameplay.Difficulty)
local Persistence = require(script.Parent.Parent.Persistence.Persistence)

local LobbyService = {}
local busy: { [Player]: boolean } = {}
local openHook: ((Player, number, string) -> ())? = nil
local opened = false

export type WorldInfo = {
	key: string,
	name: string,
	created: number,
	played: number,
	hardcore: boolean,
	difficulty: string,
	friends: boolean,
	seed: number,
}

local function remote(): RemoteEvent
	return Remotes.get("Lobby")
end

local function status(p: Player, text: string, isError: boolean?)
	remote():FireClient(p, { type = "status", text = text, error = isError == true })
end

-- Whose worlds this player manages (Studio can share one test owner, Config.STUDIO_OWNER_ID).
local function ownerFor(p: Player): number
	if RunService:IsStudio() and Config.STUDIO_OWNER_ID ~= 0 then
		return Config.STUDIO_OWNER_ID
	end
	return p.UserId
end

local function readMeta(world: string): (boolean, Persistence.Meta?)
	local ok, v = Persistence.queue():get(SaveFormat.metaKey(world))
	return ok, if ok then Persistence.decodeMeta(v) else nil
end

-- The owner's world list (a first world saved before lists existed joins it). ok = readable.
local function readList(owner: number): (boolean, SaveFormat.WorldList?)
	local ok, v = Persistence.queue():get(SaveFormat.worldsKey(owner))
	if not ok then
		return false, nil
	end
	local hasMain = false
	if v == nil then
		local okM, m = readMeta(SaveFormat.mainWorld(owner))
		if not okM then
			return false, nil
		end
		hasMain = m ~= nil
	end
	return true, SaveFormat.decodeWorldList(v, owner, hasMain)
end

local function writeList(owner: number, list: SaveFormat.WorldList): boolean
	local encoded = SaveFormat.encodeWorldList(list)
	return Persistence.queue():write(SaveFormat.worldsKey(owner), function(): any
		return encoded
	end)
end

local function activeWorld(ownerId: number): { players: number, world: string }?
	local result = nil
	pcall(function()
		local v = MemoryStoreService:GetSortedMap(Config.ACTIVE_WORLDS_MAP):GetAsync(tostring(ownerId))
		if typeof(v) == "table" then
			result = {
				players = tonumber(v.players) or 0,
				world = if typeof(v.world) == "string" then v.world else SaveFormat.mainWorld(ownerId),
			}
		end
	end)
	return result
end

local function info(key: string, m: Persistence.Meta): WorldInfo
	return {
		key = key,
		-- (the first world, saved before worlds had names, is "My World")
		name = m.name or (if key == tostring(SaveFormat.ownerOf(key)) then "My World" else "New World"),
		created = m.created or 0,
		played = m.played or m.created or 0,
		hardcore = m.hardcore == true,
		difficulty = if m.hardcore then "hard" else Difficulty.sanitize(m.difficulty),
		friends = m.friends,
		seed = m.seed,
	}
end

local function friendsWorlds(p: Player): { any }
	local worlds = {}
	if RunService:IsStudio() then
		return worlds
	end
	local okFriends, pages = pcall(function()
		return Players:GetFriendsAsync(p.UserId)
	end)
	if not okFriends or not pages then
		return worlds
	end
	local checked = 0
	while checked < 200 do
		for _, f in (pages :: FriendPages):GetCurrentPage() do
			checked += 1
			if f.IsOnline and #worlds < 30 then
				local active = activeWorld(f.Id)
				if active then
					local _, fm = readMeta(active.world)
					if fm and fm.friends and fm.code then
						table.insert(worlds, { userId = f.Id, name = f.DisplayName or f.Username, players = active.players })
					end
				end
			end
		end
		if (pages :: FriendPages).IsFinished then
			break
		end
		local okNext = pcall(function()
			(pages :: FriendPages):AdvanceToNextPageAsync()
		end)
		if not okNext then
			break
		end
	end
	return worlds
end

local function sendState(p: Player)
	local owner = ownerFor(p)
	local ok, list = readList(owner)
	local worlds: { WorldInfo } = {}
	if ok and list then
		for _, key in list.worlds do
			local okM, m = readMeta(key)
			if okM and m then
				table.insert(worlds, info(key, m))
			end
		end
		-- Java: most recently played first
		table.sort(worlds, function(a, b)
			return a.played > b.played
		end)
	end
	remote():FireClient(p, {
		type = "state",
		worlds = worlds,
		listOk = ok,
		friendsWorlds = friendsWorlds(p),
		saving = Persistence.queue():isPersistent(),
		max = SaveFormat.MAX_WORLDS,
		studio = RunService:IsStudio(),
	})
end

local function teleport(p: Player, code: string)
	local options = Instance.new("TeleportOptions")
	options.ReservedServerAccessCode = code
	local ok, err = pcall(function()
		TeleportService:TeleportAsync(game.PlaceId, { p }, options)
	end)
	if not ok then
		status(p, `Teleport failed: {err}`, true)
	end
end

-- The world's reserved server access code (created on first use).
local function ensureReserved(p: Player, owner: number, world: string): string?
	local ok, m = readMeta(world)
	if not ok then
		status(p, "The saving service is unavailable, try again in a minute.", true)
		return nil
	end
	if m and m.code then
		return m.code
	end
	local okR, code, psid = pcall(function()
		return TeleportService:ReserveServer(game.PlaceId)
	end)
	if not okR or typeof(code) ~= "string" then
		status(p, `Couldn't create the world's server: {code}`, true)
		return nil
	end
	local q = Persistence.queue()
	local wrote = q:write(SaveFormat.metaKey(world), function(old: any): any
		local prev = Persistence.decodeMeta(old)
		if prev and prev.code then
			return nil -- another lobby was faster: keep theirs
		end
		local base: Persistence.Meta = prev or {
			seed = Persistence.newSeed(),
			friends = true,
			regions = {},
			created = os.time(),
		}
		base.code, base.psid = code, psid
		return Persistence.encodeMeta(base)
	end)
	q:write(SaveFormat.serverKey(psid :: string), function(): any
		return { owner = owner, world = world }
	end)
	if not wrote then
		status(p, "Couldn't save the world's server, try again.", true)
		return nil
	end
	local _, final = readMeta(world)
	return if final then final.code else code
end

local function play(p: Player, owner: number, world: string)
	if openHook then
		if opened then
			status(p, "A world is already open in this test session.", true)
			return
		end
		opened = true
		status(p, "Opening the world...")
		local hook = openHook :: (Player, number, string) -> ()
		hook(p, owner, world)
		return
	end
	status(p, "Opening the world...")
	local code = ensureReserved(p, owner, world)
	if code then
		teleport(p, code)
	end
end

local function filterName(p: Player, name: string): string?
	local ok, result = pcall(function()
		local f = TextService:FilterStringAsync(name, p.UserId, Enum.TextFilterContext.PrivateChat)
		return f:GetNonChatStringForUserAsync(p.UserId)
	end)
	if ok and typeof(result) == "string" then
		return SaveFormat.cleanName(result)
	end
	return nil
end

local function create(p: Player, a: any)
	local owner = ownerFor(p)
	local ok, list = readList(owner)
	if not ok or not list then
		status(p, "The saving service is unavailable, try again in a minute.", true)
		return
	end
	if #list.worlds >= SaveFormat.MAX_WORLDS then
		status(p, `You already have {SaveFormat.MAX_WORLDS} worlds. Delete one to make room.`, true)
		return
	end
	local typed = SaveFormat.cleanName(a.name)
	local name = if typed then (filterName(p, typed) or "New World") else "New World"
	local hardcore = a.hardcore == true
	local difficulty = if hardcore then "hard" else Difficulty.sanitize(a.difficulty)
	local seed = SaveFormat.seedFromText(a.seed) or Random.new():NextInteger(0, 2 ^ 31 - 1)
	local key = SaveFormat.newWorldKey(list, owner)
	-- the world's record first: a list entry never points at nothing
	local meta: Persistence.Meta = {
		seed = seed,
		friends = true,
		regions = {},
		created = os.time(),
		played = os.time(),
		name = name,
		difficulty = difficulty,
		hardcore = hardcore,
	}
	local encoded = Persistence.encodeMeta(meta)
	local q = Persistence.queue()
	if not q:write(SaveFormat.metaKey(key), function(): any
		return encoded
	end) then
		status(p, "Couldn't save the new world, try again.", true)
		return
	end
	table.insert(list.worlds, 1, key)
	if not writeList(owner, list) then
		status(p, "Couldn't save the world list, try again.", true)
		return
	end
	remote():FireClient(p, { type = "created", world = key })
	sendState(p)
	play(p, owner, key)
end

local function delete(p: Player, world: string)
	local owner = ownerFor(p)
	if not SaveFormat.isOwnWorld(owner, world) then
		return
	end
	local active = activeWorld(owner)
	if active and active.world == world then
		status(p, "That world is still open on a server. Try again in a minute.", true)
		return
	end
	local ok, list = readList(owner)
	if not ok or not list then
		status(p, "The saving service is unavailable, try again in a minute.", true)
		return
	end
	local i = table.find(list.worlds, world)
	if not i then
		sendState(p)
		return
	end
	local okM, m = readMeta(world)
	table.remove(list.worlds, i)
	if not writeList(owner, list) then
		status(p, "Couldn't delete the world, try again.", true)
		return
	end
	status(p, "World deleted.")
	sendState(p)
	-- remove its saved data in the background (best effort: the world is already off the list)
	task.spawn(function()
		local q = Persistence.queue()
		if okM and m then
			for _, rid in m.regions do
				local rx, rz = string.match(rid, "^(%-?%d+),(%-?%d+)$")
				if rx and rz then
					q:remove(SaveFormat.regionKey(world, tonumber(rx) :: number, tonumber(rz) :: number))
				end
			end
			if m.psid then
				q:remove(SaveFormat.serverKey(m.psid))
			end
		end
		q:remove(SaveFormat.playerKey(world, owner))
		q:remove(SaveFormat.metaKey(world))
	end)
end

local function setFriends(p: Player, world: string, on: boolean)
	local owner = ownerFor(p)
	if not SaveFormat.isOwnWorld(owner, world) then
		return
	end
	local wrote = Persistence.queue():write(SaveFormat.metaKey(world), function(old: any): any
		local m = Persistence.decodeMeta(old)
		if not m then
			return nil
		end
		m.friends = on
		m.friendsAt = os.time()
		return Persistence.encodeMeta(m)
	end)
	status(p, if wrote then (if on then "Friends can join that world." else "That world is private now.") else "Couldn't save the setting.", not wrote)
	sendState(p)
end

local function join(p: Player, ownerId: number)
	local isFriend = false
	pcall(function()
		isFriend = p:IsFriendsWith(ownerId)
	end)
	local active = activeWorld(ownerId)
	if not isFriend then
		status(p, "You can only join your friends' worlds.", true)
		return
	elseif not active then
		status(p, "That world isn't running right now.", true)
		return
	end
	local okM, m = readMeta(active.world)
	if not okM or not m or not m.code or not m.friends then
		status(p, "That world isn't open to friends.", true)
		return
	end
	status(p, "Joining...")
	teleport(p, m.code)
end

local function onLobby(p: Player, a: any)
	if typeof(a) ~= "table" or busy[p] then
		return
	end
	busy[p] = true
	local ok, err = pcall(function()
		if a.type == "state" then
			sendState(p)
		elseif a.type == "play" and typeof(a.world) == "string" then
			local owner = ownerFor(p)
			if SaveFormat.isOwnWorld(owner, a.world) then
				play(p, owner, a.world)
			end
		elseif a.type == "create" then
			create(p, a)
		elseif a.type == "delete" and typeof(a.world) == "string" then
			delete(p, a.world)
		elseif a.type == "setFriends" and typeof(a.world) == "string" and typeof(a.on) == "boolean" then
			setFriends(p, a.world, a.on)
		elseif a.type == "join" and typeof(a.ownerId) == "number" then
			join(p, a.ownerId)
		end
	end)
	if not ok then
		warn(`[LobbyService] {err}`)
		status(p, "Something went wrong, try again.", true)
	end
	busy[p] = nil
end

-- `open`: Studio only, start the chosen world in this server instead of teleporting there.
function LobbyService.init(open: ((Player, number, string) -> ())?)
	openHook = open
	Players.CharacterAutoLoads = false
	remote().OnServerEvent:Connect(onLobby)
	TeleportService.TeleportInitFailed:Connect(function(p: Player, _result: Enum.TeleportResult, message: string)
		status(p, `Teleport failed: {message}`, true)
	end)
	Players.PlayerRemoving:Connect(function(p)
		busy[p] = nil
	end)
end

-- Studio: after the world opened, the lobby remote stops answering.
function LobbyService.close()
	openHook = nil
	opened = true
end

return LobbyService
