--!strict
--[[
	PlayerLifecycle
	===============
	Makes "a player is leaving" happen in a FIXED order. (Roblox doesn't
	promise which PlayerRemoving handler runs first, and saving must read the
	player's money, pets, etc. BEFORE the services clean them up.)

	When a player leaves:
	  1. every "before leave" handler runs (DataService takes its snapshot)
	  2. then every "leave" handler runs (services free the plot, forget the
	     player's money, stop training, ...)
	Each handler runs protected: one error doesn't stop the others.

	Usage (in a service's Start):
		PlayerLifecycle.onBeforeLeave(function(player) ... end)  -- read data here
		PlayerLifecycle.onLeave(function(player) ... end)        -- clean up here
]]

local Players = game:GetService("Players")

type Handler = (player: Player) -> ()

local PlayerLifecycle = {}

local beforeLeave: { Handler } = {}
local leave: { Handler } = {}

local function runAll(handlers: { Handler }, player: Player, phase: string)
	for _, handler in handlers do
		local errorText = ""
		local ok = xpcall(handler, function(err)
			errorText = debug.traceback(tostring(err))
		end, player)
		if not ok then
			warn(`[PlayerLifecycle] A {phase} handler failed for {player.Name}: {errorText}`)
		end
	end
end

function PlayerLifecycle.onBeforeLeave(handler: Handler)
	table.insert(beforeLeave, handler)
end

function PlayerLifecycle.onLeave(handler: Handler)
	table.insert(leave, handler)
end

Players.PlayerRemoving:Connect(function(player)
	runAll(beforeLeave, player, "before-leave")
	runAll(leave, player, "leave")
end)

return PlayerLifecycle
