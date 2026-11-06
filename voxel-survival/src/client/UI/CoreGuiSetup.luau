--!strict
-- Turns off Roblox's default UI pieces that this game replaces or can't use:
--   Backpack   -> our Hotbar (phase 3: our inventory)
--   Health     -> our survival HUD (phase 4)
--   EmotesMenu -> emotes are R15-only; our avatars are R6
-- Chat and the player list stay on.

local StarterGui = game:GetService("StarterGui")

local CoreGuiSetup = {}

function CoreGuiSetup.init()
	task.spawn(function()
		-- SetCoreGuiEnabled can fail if called before the core scripts are ready; retry briefly.
		for _ = 1, 20 do
			local ok = pcall(function()
				StarterGui:SetCoreGuiEnabled(Enum.CoreGuiType.Backpack, false)
				StarterGui:SetCoreGuiEnabled(Enum.CoreGuiType.Health, false)
				StarterGui:SetCoreGuiEnabled(Enum.CoreGuiType.EmotesMenu, false)
			end)
			if ok then
				return
			end
			task.wait(0.25)
		end
	end)
end

return CoreGuiSetup
