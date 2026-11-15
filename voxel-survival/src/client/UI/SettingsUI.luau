--!strict
-- The Options screen (title screen and pause menu): video, controls and sound, one page.
-- Every change applies at once and is saved for your account (Player/Settings).

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local SettingsSchema = require(Shared.Gameplay.SettingsSchema)
local MenuKit = require(script.Parent.MenuKit)
local Settings = require(script.Parent.Parent.Player.Settings)

local SettingsUI = {}

local function pct(v: number): string
	return `{v}%`
end

-- Builds the page inside `gui`; `onBack` runs when "Done" is pressed. Returns the page.
function SettingsUI.build(gui: Instance, onBack: () -> ()): Frame
	local page, list = MenuKit.page(gui, "Options")
	local refreshers: { () -> () } = {}
	local function slider(label: string, key: string, format: ((number) -> string)?)
		local d = SettingsSchema.byKey[key]
		local _, show = MenuKit.slider(list, label, d.min :: number, d.max :: number, d.step :: number, function()
			return Settings.get(key)
		end, function(v: number)
			Settings.set(key, v)
		end, format)
		table.insert(refreshers, show)
	end

	MenuKit.label(list, "Video")
	slider("FOV", "fov", SettingsSchema.fovText)
	slider("FOV Effects", "fovEffects", pct)
	do
		-- 0 = the device's default (phones load fewer chunks)
		local d = SettingsSchema.byKey.renderDistance
		local _, show = MenuKit.slider(list, "Render Distance", (d.min :: number) - 1, d.max :: number, 1, function()
			local v = Settings.get("renderDistance")
			return if v == 0 then (d.min :: number) - 1 else v
		end, function(v: number)
			Settings.set("renderDistance", if v < (d.min :: number) then 0 else v)
		end, function(v: number): string
			return if v < (d.min :: number) then "Device default" else `{v} chunks`
		end)
		table.insert(refreshers, show)
	end
	slider("Brightness", "brightness", SettingsSchema.brightnessText)
	local _, refreshBob = MenuKit.toggle(list, "View Bobbing", function()
		return Settings.get("bobbing")
	end, function(v)
		Settings.set("bobbing", v)
	end)
	table.insert(refreshers, refreshBob)

	MenuKit.label(list, "Controls")
	slider("Mouse Sensitivity", "sensitivity", pct)
	if UserInputService.TouchEnabled then
		slider("Touch Sensitivity", "touchSensitivity", pct)
		local _, refreshLayout = MenuKit.cycle(list, "Movement Controls", { { "dpad", "Arrow Buttons" }, { "joystick", "Joystick" } }, function()
			return Settings.get("touchLayout")
		end, function(v)
			Settings.set("touchLayout", v)
		end)
		table.insert(refreshers, refreshLayout)
	end

	MenuKit.label(list, "Sound")
	slider("Master Volume", "master", pct)
	slider("Music", "music", pct)
	slider("Blocks", "blocks", pct)
	slider("Hostile Creatures", "hostile", pct)
	slider("Friendly Creatures", "friendly", pct)
	slider("Players", "players", pct)
	slider("Ambient / Environment", "ambient", pct)

	local done = MenuKit.button(list, "Done", "primary")
	done.Activated:Connect(onBack)

	-- show the loaded values whenever the page opens
	page:GetPropertyChangedSignal("Visible"):Connect(function()
		if page.Visible then
			for _, r in refreshers do
				r()
			end
		end
	end)
	return page
end

return SettingsUI
