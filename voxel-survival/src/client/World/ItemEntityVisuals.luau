--!strict
-- Client-side animation for dropped items (server parts in workspace.ItemEntities): a slow spin
-- and a gentle bob around the server-given resting point (attribute "Base"). Purely cosmetic and
-- local, so the server never has to replicate per-frame movement.

local RunService = game:GetService("RunService")

local ItemEntityVisuals = {}

function ItemEntityVisuals.init()
	local folder = workspace:WaitForChild("ItemEntities", 30)
	if not folder then
		warn("[ItemEntityVisuals] workspace.ItemEntities not found")
		return
	end
	RunService.RenderStepped:Connect(function()
		local t = os.clock()
		for _, part in folder:GetChildren() do
			if part:IsA("BasePart") then
				local base = part:GetAttribute("Base")
				if typeof(base) == "Vector3" then
					-- each item gets its own phase from its position so they don't move in sync
					local phase = (base.X * 0.37 + base.Z * 0.61) % 6.28
					local bob = math.sin(t * 2 + phase) * 0.15
					part.CFrame = CFrame.new(base + Vector3.new(0, bob, 0)) * CFrame.Angles(0, t * 1.2 + phase, 0)
				end
			end
		end
	end)
end

return ItemEntityVisuals
