--!strict
--[[
	UIController
	============
	Builds and updates the on-screen UI (HUD, windows, notifications).
	Built mostly in Milestone 7. For now it only listens for the server's
	"Notify" messages and prints them, which proves the client and server can
	talk to each other.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = require(ReplicatedStorage.Shared.Config)
local Net = require(ReplicatedStorage.Shared.Net)

local UIController = {}
UIController.Name = "UIController"

function UIController.Init()
end

function UIController.Start()
	Net.event(Net.Names.Notify).OnClientEvent:Connect(function(message: unknown)
		-- Even messages from the server get a type check before we use them.
		if typeof(message) == "string" then
			print(`[{Config.GameName}] Notification: {message}`)
		end
	end)
end

return UIController
