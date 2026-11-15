--!strict
-- The player's options on this client (Shared/Gameplay/SettingsSchema): loaded from the server
-- when you join, saved back a moment after a change. Systems that use an option subscribe with
-- Settings.onChange(fn): fn(key, value) runs at once for every option and again on each change.
-- Works on the title screen too (nothing there needs applying except the screen itself).

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Remotes = require(Shared.Net.Remotes)
local SettingsSchema = require(Shared.Gameplay.SettingsSchema)

local Settings = {}
Settings.values = SettingsSchema.defaults()
Settings.loaded = false

local listeners: { (string, any) -> () } = {}
local saveQueued = false
local started = false

local function notify(key: string, value: any)
	for _, fn in listeners do
		local ok, err = pcall(fn, key, value)
		if not ok then
			warn(`[Settings] applying {key} failed: {err}`)
		end
	end
end

function Settings.get(key: string): any
	return Settings.values[key]
end

-- fn(key, value): called now for every option, then on every change.
function Settings.onChange(fn: (string, any) -> ())
	table.insert(listeners, fn)
	for _, d in SettingsSchema.DEFS do
		local ok, err = pcall(fn, d.key, Settings.values[d.key])
		if not ok then
			warn(`[Settings] applying {d.key} failed: {err}`)
		end
	end
end

function Settings.set(key: string, value: any)
	local v = SettingsSchema.clean(key, value)
	if v == nil or v == Settings.values[key] then
		return
	end
	Settings.values[key] = v
	notify(key, v)
	if not saveQueued then
		saveQueued = true
		task.delay(1, function()
			saveQueued = false
			Remotes.get("Settings"):FireServer({ type = "save", settings = Settings.values })
		end)
	end
end

function Settings.init()
	if started then
		return
	end
	started = true
	Remotes.get("Settings").OnClientEvent:Connect(function(m: any)
		if typeof(m) ~= "table" or m.type ~= "load" then
			return
		end
		local incoming = SettingsSchema.sanitize(m.settings)
		Settings.loaded = true
		for _, d in SettingsSchema.DEFS do
			if incoming[d.key] ~= Settings.values[d.key] then
				Settings.values[d.key] = incoming[d.key]
				notify(d.key, incoming[d.key])
			end
		end
	end)
	Remotes.get("Settings"):FireServer({ type = "request" })
end

return Settings
