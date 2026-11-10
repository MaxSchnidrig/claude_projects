--!strict
-- Client mirror of the server's survival state (food, saturation, air, sprint permission) and
-- the actions the client sends (sprinting, eating, respawn). Health comes from the Humanoid.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Remotes = require(Shared.Net.Remotes)
local SurvivalRules = require(Shared.Gameplay.SurvivalRules)

local SurvivalClient = {}
SurvivalClient.food = SurvivalRules.MAX_FOOD
SurvivalClient.saturation = SurvivalRules.START_SATURATION
SurvivalClient.air = SurvivalRules.MAX_AIR
SurvivalClient.maxAir = SurvivalRules.MAX_AIR
SurvivalClient.canSprint = true
SurvivalClient.dead = false
SurvivalClient.deathCause = ""

local changed = Instance.new("BindableEvent")
SurvivalClient.Changed = changed.Event -- fires (event: string?) with "hurt" | "died" | "spawned" | nil

function SurvivalClient.init()
	Remotes.get("SurvivalSync").OnClientEvent:Connect(function(d: any)
		if typeof(d) ~= "table" then
			return
		end
		if typeof(d.food) == "number" then
			SurvivalClient.food = d.food
		end
		if typeof(d.saturation) == "number" then
			SurvivalClient.saturation = d.saturation
		end
		if typeof(d.air) == "number" then
			SurvivalClient.air = d.air
		end
		if typeof(d.maxAir) == "number" then
			SurvivalClient.maxAir = d.maxAir
		end
		SurvivalClient.canSprint = d.canSprint ~= false
		if d.event == "died" then
			SurvivalClient.dead = true
			SurvivalClient.deathCause = if typeof(d.cause) == "string" then d.cause else "died"
		elseif d.event == "spawned" then
			SurvivalClient.dead = false
		end
		changed:Fire(d.event)
	end)
end

local function send(a: { [string]: any })
	Remotes.get("SurvivalAction"):FireServer(a)
end

function SurvivalClient.setSprinting(on: boolean)
	send({ type = "sprint", on = on })
end

function SurvivalClient.setSneaking(on: boolean)
	send({ type = "sneak", on = on })
end

function SurvivalClient.eatStart(offhand: boolean?)
	send({ type = "eatStart", hand = if offhand then "off" else "main" })
end

function SurvivalClient.eatFinish()
	send({ type = "eatFinish" })
end

function SurvivalClient.eatCancel()
	send({ type = "eatCancel" })
end

-- Landed after a fall of `blocks` blocks (only sent for falls over 3 blocks).
function SurvivalClient.reportFall(blocks: number)
	send({ type = "fall", blocks = blocks })
end

function SurvivalClient.respawn()
	send({ type = "respawn" })
end

return SurvivalClient
