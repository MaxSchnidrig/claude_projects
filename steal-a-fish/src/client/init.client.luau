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

	Start-up: require every controller -> Init() all -> Start() all.

	Robustness: every controller is loaded, initialized and started on its
	own. If one errors, or gets stuck waiting (yielding), you get a clear
	warning in Output naming it, and ALL the other controllers still work.
	A controller whose Init() failed is not started.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = require(ReplicatedStorage.Shared.Config)
local Types = require(ReplicatedStorage.Shared.Types)

local Controllers = script.Controllers

-- Add new controllers here.
local CONTROLLER_MODULES: { Instance } = {
	Controllers.UIController,
	Controllers.ShiftLockController,
	Controllers.EggController,
	Controllers.TreadmillController,
	Controllers.TrainingController,
	Controllers.PetController,
	Controllers.EffectsController,
}

-- How long a step may take before we warn that it's stuck. The other
-- controllers don't wait for it.
local STEP_TIMEOUT = 5

local failures = 0

local function fail(message: string)
	failures += 1
	warn(`[{Config.GameName}] {message}`)
end

-- 1) Load every controller module. A broken module is skipped.
local controllers: { Types.Controller } = {}
for _, module in CONTROLLER_MODULES do
	local ok, result = pcall(require, module :: ModuleScript)
	if ok and typeof(result) == "table" then
		table.insert(controllers, result :: Types.Controller)
	else
		fail(`Could not load controller {module.Name}:\n{result}`)
	end
end

-- 2) Run one step (Init or Start) of every controller, each in its own
-- thread. Returns the set of controllers whose step finished without error.
local function runPhase(stepName: string, list: { Types.Controller }): { [Types.Controller]: boolean }
	local succeeded: { [Types.Controller]: boolean } = {}
	local finished: { [Types.Controller]: boolean } = {}

	for _, controller in list do
		local step = if stepName == "Init" then controller.Init else controller.Start
		task.spawn(function()
			local errorText = ""
			local ok = xpcall(step, function(err)
				errorText = debug.traceback(tostring(err))
			end)
			finished[controller] = true
			if ok then
				succeeded[controller] = true
			else
				fail(`{controller.Name}.{stepName}() FAILED:\n{errorText}`)
			end
		end)
	end

	-- Wait until every step is done, but never longer than STEP_TIMEOUT.
	local waited = 0
	while waited < STEP_TIMEOUT do
		local allDone = true
		for _, controller in list do
			if not finished[controller] then
				allDone = false
				break
			end
		end
		if allDone then
			break
		end
		waited += task.wait(0.05)
	end
	for _, controller in list do
		if not finished[controller] then
			fail(
				`{controller.Name}.{stepName}() is still waiting after {STEP_TIMEOUT}s (it yields). `
					.. "The other controllers keep working."
			)
		end
	end
	return succeeded
end

local initialized = runPhase("Init", controllers)

-- Only start controllers whose Init() worked.
local startable: { Types.Controller } = {}
for _, controller in controllers do
	if initialized[controller] then
		table.insert(startable, controller)
	end
end
local started = runPhase("Start", startable)

local startedCount = 0
for _ in started do
	startedCount += 1
end

if failures == 0 then
	print(`[{Config.GameName}] Client ready: all {startedCount} controllers started.`)
else
	warn(
		`[{Config.GameName}] Client started {startedCount} of {#CONTROLLER_MODULES} controllers with {failures} problem(s). See the messages above.`
	)
end
