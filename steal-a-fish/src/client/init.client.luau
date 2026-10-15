--!strict
--[[
	Client bootstrap
	================
	This is the ONE client LocalScript. It lives in
	StarterPlayer.StarterPlayerScripts.Client, and Rojo builds it from
	src/client/init.client.luau. It runs on each player's own computer.

	Controllers are the client-side version of services: each one handles one
	area (UI, input, effects). They only show things and send requests; the
	server decides everything that matters.

	The same pattern as the server: require -> Init() all -> Start() all.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = require(ReplicatedStorage.Shared.Config)
local Types = require(ReplicatedStorage.Shared.Types)

local Controllers = script.Controllers

local CONTROLLERS: { Types.Controller } = {
	require(Controllers.UIController),
	require(Controllers.EggController),
	require(Controllers.TreadmillController),
	require(Controllers.ShiftLockController),
}

local failures = 0

-- Run one step; if it errors, print the error and keep going.
local function runStep(controller: Types.Controller, stepName: string, step: () -> ())
	local errorText = ""
	local ok = xpcall(step, function(err)
		errorText = debug.traceback(tostring(err))
	end)
	if not ok then
		failures += 1
		warn(`[{Config.GameName}] {controller.Name}.{stepName}() FAILED:\n{errorText}`)
	end
end

for _, controller in CONTROLLERS do
	runStep(controller, "Init", controller.Init)
end

for _, controller in CONTROLLERS do
	runStep(controller, "Start", controller.Start)
end

if failures == 0 then
	print(`[{Config.GameName}] Client ready: all {#CONTROLLERS} controllers started.`)
end
