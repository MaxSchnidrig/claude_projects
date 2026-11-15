--!strict
-- The pause menu's "Save and Quit to Title" (and the Hardcore death screen's "Title Screen"):
-- save the player now, then send them to a lobby server (the title screen). Studio can't
-- teleport: there the save happens and the player is told to stop the test.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TeleportService = game:GetService("TeleportService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Remotes = require(Shared.Net.Remotes)
local Persistence = require(script.Parent.Parent.Persistence.Persistence)

local MenuService = {}
local busy: { [Player]: boolean } = {}

local function status(p: Player, text: string)
	Remotes.get("Menu"):FireClient(p, { type = "status", text = text })
end

function MenuService.init()
	Remotes.get("Menu").OnServerEvent:Connect(function(p: Player, m: any)
		if typeof(m) ~= "table" or m.type ~= "quit" or busy[p] then
			return
		end
		busy[p] = true
		status(p, "Saving...")
		local saved = Persistence.saveNow(p)
		if RunService:IsStudio() then
			status(p, if saved then "Saved. Stop the test (the red square) to leave the world." else "Couldn't save just now; it will be saved when you leave.")
			busy[p] = nil
			return
		end
		status(p, "Going to the title screen...")
		local ok, err = pcall(function()
			-- a plain teleport to this place lands in a public server: the lobby
			TeleportService:TeleportAsync(game.PlaceId, { p })
		end)
		if not ok then
			status(p, `Couldn't go back to the title screen: {err}`)
		end
		busy[p] = nil
	end)
	Players.PlayerRemoving:Connect(function(p)
		busy[p] = nil
	end)
end

return MenuService
