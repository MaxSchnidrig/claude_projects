--!strict
-- Turns off Roblox's default UI pieces listed in Config.CORE_GUI_DISABLE (default below):
--   Backpack   -> our Hotbar (phase 3: our inventory)
--   Health     -> our survival HUD (phase 4)
--   EmotesMenu -> emotes are R15-only; our avatars are R6
-- Chat and the player list stay on. T opens the chat box (Java's key; "/" needs Shift+7 on
-- German keyboards). With the old chat system this setting doesn't exist and "/" stays.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local StarterGui = game:GetService("StarterGui")

local Config = require(ReplicatedStorage:WaitForChild("Shared").Config)

local CoreGuiSetup = {}

function CoreGuiSetup.init()
	task.spawn(function()
		for _ = 1, 40 do
			local done = false
			pcall(function()
				local tcs = game:GetService("TextChatService")
				local bar = tcs:FindFirstChildOfClass("ChatInputBarConfiguration")
				if bar then
					(bar :: any).KeyboardKeyCode = Enum.KeyCode.T
					done = true
				end
			end)
			if done then
				return
			end
			task.wait(0.25)
		end
	end)
	task.spawn(function()
		-- SetCoreGuiEnabled can fail if called before the core scripts are ready; retry briefly.
		for _ = 1, 20 do
			local ok = pcall(function()
				for _, name in Config.CORE_GUI_DISABLE do
					StarterGui:SetCoreGuiEnabled((Enum.CoreGuiType :: any)[name], false)
				end
			end)
			if ok then
				return
			end
			task.wait(0.25)
		end
	end)
end

return CoreGuiSetup
