--!strict
-- The lobby: every public server is a lobby. From here a player teleports to
--   * their own world: a reserved server created once per owner (ReserveServer); its access code
--     is stored in the world meta, and srv:<PrivateServerId> records the owner so the world
--     server knows whose world it is
--   * a friend's world that is running now (MemoryStore registry) and allows friends
-- The friends setting of your own world is changed here.
--
-- Remote "Lobby" (both directions):
--   C -> S { type = "state" } | { type = "play" } | { type = "join", ownerId } | { type = "setFriends", on }
--   S -> C { type = "state", hasWorld, friends, worlds = { { userId, name, players } } }
--          { type = "status", text }

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TeleportService = game:GetService("TeleportService")
local MemoryStoreService = game:GetService("MemoryStoreService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared.Config)
local Remotes = require(Shared.Net.Remotes)
local SaveFormat = require(Shared.Persistence.SaveFormat)
local Persistence = require(script.Parent.Parent.Persistence.Persistence)

local LobbyService = {}
local busy: { [Player]: boolean } = {}

local function status(p: Player, text: string)
	Remotes.get("Lobby"):FireClient(p, { type = "status", text = text })
end

local function readMeta(ownerId: number): (boolean, Persistence.Meta?)
	local ok, v = Persistence.queue():get(SaveFormat.metaKey(ownerId))
	return ok, if ok then Persistence.decodeMeta(v) else nil
end

local function activeWorld(ownerId: number): { players: number }?
	local result = nil
	pcall(function()
		local v = MemoryStoreService:GetSortedMap(Config.ACTIVE_WORLDS_MAP):GetAsync(tostring(ownerId))
		if typeof(v) == "table" then
			result = { players = tonumber(v.players) or 0 }
		end
	end)
	return result
end

local function sendState(p: Player)
	local ok, m = readMeta(p.UserId)
	local worlds = {}
	local okFriends, pages = pcall(function()
		return Players:GetFriendsAsync(p.UserId)
	end)
	if okFriends and pages then
		local checked = 0
		while checked < 200 do
			for _, f in (pages :: FriendPages):GetCurrentPage() do
				checked += 1
				if f.IsOnline and #worlds < 30 then
					local active = activeWorld(f.Id)
					if active then
						local _, fm = readMeta(f.Id)
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
	end
	Remotes.get("Lobby"):FireClient(p, {
		type = "state",
		hasWorld = ok and m ~= nil,
		friends = if m then m.friends else true,
		worlds = worlds,
		saving = Persistence.queue():isPersistent(),
	})
end

local function teleport(p: Player, code: string)
	local options = Instance.new("TeleportOptions")
	options.ReservedServerAccessCode = code
	local ok, err = pcall(function()
		TeleportService:TeleportAsync(game.PlaceId, { p }, options)
	end)
	if not ok then
		status(p, `Teleport failed: {err}`)
	end
end

-- Create the owner's world record and reserved server on first use.
local function ensureWorld(p: Player): string?
	local ok, m = readMeta(p.UserId)
	if not ok then
		status(p, "The saving service is unavailable, try again in a minute.")
		return nil
	end
	if m and m.code then
		return m.code
	end
	local okR, code, psid = pcall(function()
		return TeleportService:ReserveServer(game.PlaceId)
	end)
	if not okR or typeof(code) ~= "string" then
		status(p, `Couldn't create your world server: {code}`)
		return nil
	end
	local q = Persistence.queue()
	local seed = if m then m.seed else Persistence.newSeed()
	local wrote = q:write(SaveFormat.metaKey(p.UserId), function(old: any): any
		local prev = Persistence.decodeMeta(old)
		if prev and prev.code then
			return nil -- someone else (another lobby) was faster: keep theirs
		end
		return {
			v = SaveFormat.VERSION,
			seed = if prev then prev.seed else seed,
			friends = if prev then prev.friends else true,
			code = code,
			psid = psid,
			regions = if prev then prev.regions else {},
			ticks = if prev then prev.ticks else nil,
			created = (prev and prev.created) or os.time(),
		}
	end)
	q:write(SaveFormat.serverKey(psid :: string), function(): any
		return p.UserId
	end)
	if not wrote then
		status(p, "Couldn't save your new world, try again.")
		return nil
	end
	local _, final = readMeta(p.UserId)
	return if final then final.code else code
end

local function onLobby(p: Player, a: any)
	if typeof(a) ~= "table" or busy[p] then
		return
	end
	busy[p] = true
	local ok, err = pcall(function()
		if a.type == "state" then
			sendState(p)
		elseif a.type == "play" then
			status(p, "Opening your world...")
			local code = ensureWorld(p)
			if code then
				teleport(p, code)
			end
		elseif a.type == "join" and typeof(a.ownerId) == "number" then
			local ownerId = a.ownerId
			local isFriend = false
			pcall(function()
				isFriend = p:IsFriendsWith(ownerId)
			end)
			local okM, m = readMeta(ownerId)
			if not isFriend then
				status(p, "You can only join your friends' worlds.")
			elseif not okM or not m or not m.code or not m.friends then
				status(p, "That world isn't open to friends.")
			elseif not activeWorld(ownerId) then
				status(p, "That world isn't running right now.")
			else
				status(p, "Joining...")
				teleport(p, m.code)
			end
		elseif a.type == "setFriends" and typeof(a.on) == "boolean" then
			local on = a.on
			local wrote = Persistence.queue():write(SaveFormat.metaKey(p.UserId), function(old: any): any
				if typeof(old) ~= "table" then
					return {
						v = SaveFormat.VERSION,
						seed = Persistence.newSeed(),
						friends = on,
						regions = {},
						created = os.time(),
					}
				end
				old.friends = on
				return old
			end)
			status(p, if wrote then (if on then "Friends can join your world." else "Your world is private.") else "Couldn't save the setting.")
			sendState(p)
		end
	end)
	if not ok then
		warn(`[LobbyService] {err}`)
		status(p, "Something went wrong, try again.")
	end
	busy[p] = nil
end

function LobbyService.init()
	Players.CharacterAutoLoads = false
	Remotes.get("Lobby").OnServerEvent:Connect(onLobby)
	TeleportService.TeleportInitFailed:Connect(function(p: Player, _result: Enum.TeleportResult, message: string)
		status(p, `Teleport failed: {message}`)
	end)
	Players.PlayerRemoving:Connect(function(p)
		busy[p] = nil
	end)
end

return LobbyService
