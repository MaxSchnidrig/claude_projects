--!strict
local Players = game:GetService("Players")
local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local Remotes = require(Shared.Net.Remotes)
local RunService = game:GetService("RunService")
local Items = require(script.Parent.Parent.Render.ItemMeshes)
local BS = require(Shared.Config).BLOCK_SIZE

-- A local catch animation follows the angler as they move. Inventory ownership stays on the server.
local function reelVisual(key: string, origin: Vector3)
	local pixel = BS * 0.6 / 16
	local part = Items.make(key, pixel, BS / 3) or Items.standIn(key, pixel, BS / 3)
	part.CFrame = CFrame.new(origin)
	part.Parent = workspace
	local elapsed = 0
	local connection: RBXScriptConnection
	connection = RunService.RenderStepped:Connect(function(dt)
		elapsed += dt
		local alpha = math.min(1, elapsed / 0.48)
		local character = Players.LocalPlayer.Character
		local root = character and character:FindFirstChild("HumanoidRootPart") :: BasePart?
		if not root or alpha >= 1 then
			connection:Disconnect()
			part:Destroy()
			return
		end
		local point = origin:Lerp(root.Position, alpha) + Vector3.new(0, 6 * BS * alpha * (1 - alpha), 0)
		local camera = workspace.CurrentCamera
		local facing = if camera then camera.CFrame.Rotation else CFrame.identity
		part.CFrame = CFrame.new(point) * facing * CFrame.Angles(0, 0, alpha * math.pi)
	end)
end

local FishingHUD = {}
function FishingHUD.init()
	local gui = Instance.new("ScreenGui")
	gui.Name = "FishingHUD"
	gui.ResetOnSpawn = false
	gui.Parent = Players.LocalPlayer:WaitForChild("PlayerGui")
	local label = Instance.new("TextLabel")
	label.AnchorPoint = Vector2.new(0.5, 0.5)
	label.Position = UDim2.fromScale(0.5, 0.64)
	label.Size = UDim2.new(0.85, 0, 0, 38)
	label.BackgroundTransparency = 1
	label.TextWrapped = true
	label.Font = Enum.Font.GothamBold
	label.TextSize = 16
	label.TextStrokeTransparency = 0.2
	label.Visible = false
	label.Parent = gui
	local revision = 0
	Remotes.get("Fishing").OnClientEvent:Connect(function(message: string, active: boolean, item: string?, origin: Vector3?)
		if item and origin then reelVisual(item, origin) end
		revision += 1
		local current = revision
		label.Text = message
		label.TextColor3 = if message == "Bite! Reel in!" then Color3.fromRGB(255, 215, 100) else Color3.fromRGB(234, 247, 244)
		label.Visible = true
		if not active then
			task.delay(3, function()
				if current == revision then label.Visible = false end
			end)
		end
	end)
end
return FishingHUD
