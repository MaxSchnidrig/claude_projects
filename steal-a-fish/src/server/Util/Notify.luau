--!strict
--[[
	Notify
	======
	Sends an on-screen notification to one player or everyone. The KIND
	decides the color, icon and sound on the client:
		"info"     (default) blue
		"success"  green      e.g. stole an egg, progress loaded
		"warning"  yellow     e.g. not enough money, pads full
		"danger"   red        e.g. caught by a shark
		"epic"     purple     e.g. someone hatched a Legendary
		"purchase" gold       e.g. bought an upgrade (plays the purchase sound)

	Usage:
		Notify.send(player, "All your pads are full!", "warning")
		Notify.all("🎉 Max hatched a Mythic Kraken!", "epic")
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Net = require(ReplicatedStorage.Shared.Net)

local Notify = {}

function Notify.send(player: Player, message: string, kind: string?)
	Net.event(Net.Names.Notify):FireClient(player, message, kind or "info")
end

function Notify.all(message: string, kind: string?)
	Net.event(Net.Names.Notify):FireAllClients(message, kind or "info")
end

return Notify
