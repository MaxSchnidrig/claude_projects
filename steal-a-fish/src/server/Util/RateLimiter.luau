--!strict
--[[
	RateLimiter
	===========
	Stops a player from spamming a remote. Each limiter allows at most
	`maxCalls` requests per player within any `windowSeconds` window.

	Usage (inside a service):
		local RateLimiter = require(script.Parent.Parent.Util.RateLimiter)
		local limiter = RateLimiter.new(5, 1) -- 5 calls per second per player

		remote.OnServerEvent:Connect(function(player)
			if not limiter.allow(player) then
				return -- too many requests: ignore it
			end
			-- ... handle the request ...
		end)

	Data for players who leave is cleaned up automatically.
]]

local Players = game:GetService("Players")

export type Limiter = {
	-- Returns true if the request may go ahead (and counts it), false if spamming.
	allow: (player: Player) -> boolean,
}

local RateLimiter = {}

function RateLimiter.new(maxCalls: number, windowSeconds: number): Limiter
	-- For each player: the timestamps of their recent requests.
	local history: { [Player]: { number } } = {}

	local function allow(player: Player): boolean
		local now = os.clock()
		local times = history[player]
		if times == nil then
			times = {}
			history[player] = times
		end
		-- Throw away timestamps that are older than the window.
		local i = 1
		while i <= #times do
			if now - times[i] > windowSeconds then
				table.remove(times, i)
			else
				i += 1
			end
		end
		if #times >= maxCalls then
			return false
		end
		table.insert(times, now)
		return true
	end

	Players.PlayerRemoving:Connect(function(player)
		history[player] = nil
	end)

	return { allow = allow }
end

return RateLimiter
