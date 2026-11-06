--!strict
-- Starts systems one by one so that one failing system can't take the others down.
--
-- Each step requires and initialises its module inside xpcall. A failure (including an error
-- while the module itself loads) is printed to Output with a traceback and, on the client, listed
-- on screen in red, naming the system. Steps run in order; a step that yields (waits) delays the
-- ones after it, so long waits belong inside the system (e.g. task.spawn), not in init.

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

local Startup = {}

export type Step = { name: string, run: () -> () }

local failures: { string } = {}
local banner: TextLabel? = nil

local function showOnScreen()
	if not RunService:IsClient() or #failures == 0 then
		return
	end
	if not banner then
		local gui = Instance.new("ScreenGui")
		gui.Name = "StartupErrors"
		gui.ResetOnSpawn = false
		gui.DisplayOrder = 1000
		local label = Instance.new("TextLabel")
		label.BackgroundColor3 = Color3.fromRGB(60, 0, 0)
		label.BackgroundTransparency = 0.2
		label.TextColor3 = Color3.fromRGB(255, 200, 200)
		label.Font = Enum.Font.Code
		label.TextSize = 14
		label.TextXAlignment = Enum.TextXAlignment.Left
		label.TextYAlignment = Enum.TextYAlignment.Top
		label.AutomaticSize = Enum.AutomaticSize.XY
		label.Position = UDim2.fromOffset(8, 8)
		label.Parent = gui
		gui.Parent = Players.LocalPlayer:WaitForChild("PlayerGui")
		banner = label
	end
	(banner :: TextLabel).Text = "Startup errors (see Output for details):\n" .. table.concat(failures, "\n")
end

function Startup.run(side: string, steps: { Step })
	for _, step in steps do
		local t = os.clock()
		local ok, err = xpcall(step.run, debug.traceback)
		if not ok then
			local msg = `[Startup:{side}] {step.name} FAILED: {err}`
			warn(msg) -- full traceback in Output
			table.insert(failures, `{step.name}: {string.split(tostring(err), "\n")[1]}`)
			showOnScreen()
		elseif os.clock() - t > 5 then
			warn(string.format("[Startup:%s] %s took %.1f s to start", side, step.name, os.clock() - t))
		end
	end
end

return Startup
