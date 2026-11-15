--!strict
-- Each player's own options (Shared/Gameplay/SettingsSchema), saved per player across worlds
-- (u:<userId>:settings). Runs in the lobby and in worlds.
--   join  -> read the saved options, send { type = "load", settings }
--   "save" from the client -> checked against the schema, written a moment later (changes made
--   while dragging a slider merge into one write)

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Remotes = require(Shared.Net.Remotes)
local SaveFormat = require(Shared.Persistence.SaveFormat)
local SettingsSchema = require(Shared.Gameplay.SettingsSchema)
local Persistence = require(script.Parent.Parent.Persistence.Persistence)

local SettingsService = {}
local pending: { [Player]: { [string]: any } } = {}
local writing: { [Player]: boolean } = {}
local loaded: { [Player]: boolean } = {}

local function write(p: Player)
	if writing[p] then
		return
	end
	writing[p] = true
	task.delay(2, function()
		local s = pending[p]
		pending[p] = nil
		writing[p] = nil
		if s then
			local userId = p.UserId
			Persistence.queue():write(SaveFormat.settingsKey(userId), function(): any
				return s
			end)
		end
	end)
end

local function onPlayer(p: Player)
	local ok, v = Persistence.queue():get(SaveFormat.settingsKey(p.UserId))
	if not p.Parent then
		return
	end
	loaded[p] = true
	Remotes.get("Settings"):FireClient(p, { type = "load", settings = SettingsSchema.sanitize(if ok then v else nil), ok = ok })
end

function SettingsService.init()
	local remote = Remotes.get("Settings")
	remote.OnServerEvent:Connect(function(p: Player, m: any)
		if typeof(m) ~= "table" then
			return
		end
		if m.type == "save" and typeof(m.settings) == "table" and loaded[p] then
			pending[p] = SettingsSchema.sanitize(m.settings)
			write(p)
		elseif m.type == "request" and not loaded[p] then
			task.spawn(onPlayer, p) -- the client asked before our PlayerAdded ran (Studio)
		end
	end)
	Players.PlayerAdded:Connect(onPlayer)
	for _, p in Players:GetPlayers() do
		task.spawn(onPlayer, p)
	end
	Players.PlayerRemoving:Connect(function(p)
		local s = pending[p]
		if s then
			-- leaving before the delayed write: write now
			pending[p] = nil
			task.spawn(function()
				Persistence.queue():write(SaveFormat.settingsKey(p.UserId), function(): any
					return s
				end)
			end)
		end
		loaded[p] = nil
	end)
end

return SettingsService
