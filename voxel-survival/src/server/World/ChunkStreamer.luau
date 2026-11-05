--!strict
-- Answers client chunk requests with the server's diffs for those chunks, and remembers which
-- chunks each player has loaded (so block changes can be sent only to players who can see them).
--
-- Clients generate terrain themselves from the seed; the network only carries edits.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Remotes = require(Shared.Net.Remotes)
local WorldService = require(script.Parent.WorldService)

local MAX_KEYS_PER_REQUEST = 128
local MAX_REQUESTS_PER_SECOND = 20
local MAX_ABS_KEY = 2 ^ 42 -- ChunkData.key range

local ChunkStreamer = {}

type PlayerState = { loaded: { [number]: boolean }, tokens: number, lastRefill: number }
local states: { [Player]: PlayerState } = {}

local function state(player: Player): PlayerState
	local s = states[player]
	if not s then
		s = { loaded = {}, tokens = MAX_REQUESTS_PER_SECOND, lastRefill = os.clock() }
		states[player] = s
	end
	return s
end

-- Token bucket: refuse spammy clients instead of doing unbounded work for them.
local function allow(s: PlayerState): boolean
	local now = os.clock()
	s.tokens = math.min(MAX_REQUESTS_PER_SECOND, s.tokens + (now - s.lastRefill) * MAX_REQUESTS_PER_SECOND)
	s.lastRefill = now
	if s.tokens < 1 then
		return false
	end
	s.tokens -= 1
	return true
end

local function validKeyList(v: any): boolean
	if typeof(v) ~= "table" or #v > MAX_KEYS_PER_REQUEST then
		return false
	end
	for i, k in v do
		if typeof(i) ~= "number" or typeof(k) ~= "number" or k ~= k or k < 0 or k > MAX_ABS_KEY or k % 1 ~= 0 then
			return false
		end
	end
	return true
end

function ChunkStreamer.init()
	local request = Remotes.get("ChunkRequest")
	local reply = Remotes.get("ChunkDiffs")

	request.OnServerEvent:Connect(function(player: Player, payload: any)
		if typeof(payload) ~= "table" then
			return
		end
		local s = state(player)
		if not allow(s) then
			return
		end
		local load, unload = payload.load, payload.unload
		if load ~= nil and not validKeyList(load) then
			return
		end
		if unload ~= nil and not validKeyList(unload) then
			return
		end
		if unload then
			for _, key in unload do
				s.loaded[key] = nil
			end
		end
		if load and #load > 0 then
			local out = table.create(#load)
			for _, key in load do
				s.loaded[key] = true
				table.insert(out, { key, WorldService.getPackedDiffs(key) })
			end
			reply:FireClient(player, out)
		end
	end)

	Players.PlayerRemoving:Connect(function(player)
		states[player] = nil
	end)
end

-- Players who currently have this chunk loaded (phase 2: block change broadcasts).
function ChunkStreamer.playersWithChunk(key: number): { Player }
	local list = {}
	for player, s in states do
		if s.loaded[key] then
			table.insert(list, player)
		end
	end
	return list
end

return ChunkStreamer
