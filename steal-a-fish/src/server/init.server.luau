--!strict
--[[
	Server bootstrap
	================
	This is the ONE server Script. It lives in ServerScriptService.Server, and
	Rojo builds it from src/server/init.server.luau. Every other server file is
	a ModuleScript under it.

	Start-up order:
	  1. require every service (just loads the code)
	  2. call Init() on every service (set up state)
	  3. call Start() on every service (connect events, start loops)

	The SERVICES list below sets the order. Services that others depend on come
	first (for example, data must be ready before money).
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = require(ReplicatedStorage.Shared.Config)
local Types = require(ReplicatedStorage.Shared.Types)

local Net = require(ReplicatedStorage.Shared.Net)

-- Create every RemoteEvent before anything else, so clients never wait for
-- a remote that the server only creates later.
Net.createAll()

local Services = script.Services

local SERVICES: { Types.Service } = {
	require(Services.WorldService),
	require(Services.EconomyService),
	require(Services.PlotService),
	require(Services.SpeedService),
	require(Services.UpgradeService),
	require(Services.PetService),
	require(Services.EggService),
	require(Services.BotService),
	require(Services.RewardService), -- Index rewards and the Daily Gift
	require(Services.MonetizationService), -- Robux passes, boosts and products
	require(Services.ShowcaseService), -- Studio-only preview commands
	-- Last: it loads saved data INTO the services above.
	require(Services.DataService),
}

-- Run one step of one service. If it errors, print a clear message with the
-- full error and keep going, so one broken service doesn't stop the others.
local function runStep(service: Types.Service, stepName: string, step: () -> ()): boolean
	local errorText = ""
	local ok = xpcall(step, function(err)
		errorText = debug.traceback(tostring(err))
	end)
	if not ok then
		warn(`[{Config.GameName}] {service.Name}.{stepName}() FAILED:\n{errorText}`)
	end
	return ok
end

local failures = 0

for _, service in SERVICES do
	if not runStep(service, "Init", service.Init) then
		failures += 1
	end
end

for _, service in SERVICES do
	if not runStep(service, "Start", service.Start) then
		failures += 1
	end
	if Config.Debug then
		print(`[{Config.GameName}] started {service.Name}`)
	end
end

if failures == 0 then
	print(`[{Config.GameName}] Server ready: all {#SERVICES} services started.`)
else
	warn(`[{Config.GameName}] Server started with {failures} error(s). Look at the red/orange messages above.`)
end

-- Say hello to every player, so we can see the server -> client link works.
local Players = game:GetService("Players")
local notify = Net.event(Net.Names.Notify)

local function welcome(player: Player)
	notify:FireClient(player, `Welcome to {Config.GameName}, {player.DisplayName}!`)
end

Players.PlayerAdded:Connect(welcome)
-- In Studio, your player can join before this script runs, so greet them too.
for _, player in Players:GetPlayers() do
	welcome(player)
end
