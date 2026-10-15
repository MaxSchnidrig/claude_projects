--!strict
--[[
	Signal
	======
	A tiny event system, so one service can say "this happened" and others can
	react without being tightly linked.

	Usage:
		local Signal = require(ReplicatedStorage.Shared.Signal)
		local PlotAssigned = Signal.new()                  -- create
		PlotAssigned:Connect(function(player, plot) end)   -- listen
		PlotAssigned:Fire(player, plot)                    -- announce

	Each listener runs in its own thread (task.spawn), so an error in one
	listener can't break the code that fired the signal.
]]

export type Connection = {
	Disconnect: (self: Connection) -> (),
}

export type Signal = {
	Connect: (self: Signal, handler: (...any) -> ()) -> Connection,
	Fire: (self: Signal, ...any) -> (),
}

local Signal = {}

function Signal.new(): Signal
	local handlers: { (...any) -> () } = {}

	local function connect(_self: Signal, handler: (...any) -> ()): Connection
		table.insert(handlers, handler)
		local function disconnect(_c: Connection)
			local index = table.find(handlers, handler)
			if index then
				table.remove(handlers, index)
			end
		end
		return { Disconnect = disconnect }
	end

	local function fire(_self: Signal, ...: any)
		-- Copy the list first, so a listener that disconnects mid-loop is safe.
		for _, handler in table.clone(handlers) do
			task.spawn(handler, ...)
		end
	end

	return { Connect = connect, Fire = fire }
end

return Signal
