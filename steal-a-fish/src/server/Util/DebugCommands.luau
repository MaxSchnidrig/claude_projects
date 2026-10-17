--!strict
--[[
	DebugCommands
	=============
	Test commands that ONLY work while play-testing in Roblox Studio (never in
	the real game). Services register their own commands here, and this is
	the ONLY place that listens for them, so this file is the only place the
	Studio check is needed. It is checked twice (look for "THE STUDIO
	CHECK"): when a command is registered, and again every time one runs.
	RunService:IsStudio() is false on every live Roblox server, for everyone,
	including the game's owner.

	How players use them (in Studio):
	  - type in chat, for example:  !speed 5000
	  - or, if chat doesn't reach the server, in the Command Bar (set to Server):
	      game.Players:GetPlayers()[1]:SetAttribute("DebugCommand", "!speed 5000")

	Usage (inside a service):
		DebugCommands.register("money", function(player, args)
			-- args = the words after the command, lowercased: { "1000" }
		end)
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

type Handler = (player: Player, args: { string }) -> ()

local DebugCommands = {}

local handlers: { [string]: Handler } = {}
local started = false

local function run(player: Player, message: string)
	-- THE STUDIO CHECK (second layer): even if a handler somehow got
	-- registered, nothing runs outside Roblox Studio. Not for the game owner,
	-- not for admins, not for anyone.
	if not RunService:IsStudio() then
		return
	end
	local words = string.split(string.lower(message), " ")
	local first = words[1]
	if string.sub(first, 1, 1) ~= "!" then
		return
	end
	local handler = handlers[string.sub(first, 2)]
	if handler then
		table.remove(words, 1)
		handler(player, words)
	end
end

local function watchPlayer(player: Player)
	player.Chatted:Connect(function(message)
		run(player, message)
	end)
	player:GetAttributeChangedSignal("DebugCommand"):Connect(function()
		local command = player:GetAttribute("DebugCommand")
		if typeof(command) == "string" then
			player:SetAttribute("DebugCommand", nil)
			run(player, command)
		end
	end)
end

-- Register "!name ..." for Studio play-tests. Does nothing in a live game.
function DebugCommands.register(name: string, handler: Handler)
	-- THE STUDIO CHECK (first layer): in a live game the command is never
	-- stored, and no chat listener is ever connected.
	if not RunService:IsStudio() then
		return
	end
	handlers[string.lower(name)] = handler
	if not started then
		started = true
		Players.PlayerAdded:Connect(watchPlayer)
		for _, player in Players:GetPlayers() do
			watchPlayer(player)
		end
	end
end

return DebugCommands
