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
SurvivalClient.exhaustion = 0 -- (F3: Java's foodExhaustionLevel and foodTickTimer)
SurvivalClient.foodTimer = 0
SurvivalClient.dead = false
SurvivalClient.deathCause = ""
SurvivalClient.speedLevel = 0
SurvivalClient.absorption = 0 -- extra (gold) health from the absorption effect
-- status effects from the server: { id, level (0 = I), seconds left } in display order
SurvivalClient.effects = {} :: { { any } }

local changed = Instance.new("BindableEvent")
SurvivalClient.Changed = changed.Event -- fires (event: string?) with "hurt" | "died" | "spawned" | nil

-- Does the player have this effect right now?
function SurvivalClient.hasEffect(id: string): boolean
	for _, e in SurvivalClient.effects do
		if e[1] == id then
			return true
		end
	end
	return false
end

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
		if typeof(d.exhaustion) == "number" then
			SurvivalClient.exhaustion = d.exhaustion
		end
		if typeof(d.foodTimer) == "number" then
			SurvivalClient.foodTimer = d.foodTimer
		end
		if typeof(d.air) == "number" then
			SurvivalClient.air = d.air
		end
		if typeof(d.maxAir) == "number" then
			SurvivalClient.maxAir = d.maxAir
		end
		SurvivalClient.canSprint = d.canSprint ~= false
		if typeof(d.absorption) == "number" then
			SurvivalClient.absorption = d.absorption
		end
		if typeof(d.effects) == "table" then
			local list = {}
			for _, e in d.effects do
				if typeof(e) == "table" and typeof(e[1]) == "string" and typeof(e[2]) == "number" and typeof(e[3]) == "number" then
					table.insert(list, { e[1], e[2], e[3] })
				end
			end
			SurvivalClient.effects = list
			SurvivalClient.speedLevel = 0
			for _, effect in list do
				if effect[1] == "speed" then
					SurvivalClient.speedLevel = effect[2] + 1
				end
			end
		end
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

-- Landed on farmland at (x, y, z) after falling `blocks` (the server rolls the trample chance).
function SurvivalClient.trample(x: number, y: number, z: number, blocks: number)
	send({ type = "trample", x = x, y = y, z = z, fall = blocks })
end

-- Exhaustion from movement the client's Java physics measured (sprinting, swimming, jumps).
function SurvivalClient.exhaust(amount: number)
	send({ type = "exhaust", amount = amount })
end

function SurvivalClient.respawn()
	send({ type = "respawn" })
end

return SurvivalClient
