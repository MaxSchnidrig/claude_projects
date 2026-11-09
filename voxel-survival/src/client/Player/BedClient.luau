--!strict
-- Sleeping and bed messages (server: Player/BedService).
--   * "sleep": the screen darkens over the 5 s it takes to skip the night, the view drops to
--     the pillow, and a "Leave Bed" button appears (Java)
--   * "wake": back to normal
--   * "message": Java's status line above the hotbar ("Respawn point set", "You can only sleep
--     at night and during thunderstorms", ...)

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Remotes = require(Shared.Net.Remotes)
local InventoryClient = require(script.Parent.InventoryClient)
local CameraController = require(script.Parent.CameraController)
local MovementController = require(script.Parent.MovementController)

local BedClient = {}
BedClient.sleeping = false

local gui: ScreenGui
local dim: Frame
local leave: TextButton
local toast: TextLabel
local toastUntil = 0
local sleepStart = 0

function BedClient.message(text: string)
	toast.Text = text
	toast.Visible = true
	toastUntil = os.clock() + 3
end

local function setSleeping(on: boolean)
	BedClient.sleeping = on
	MovementController.sleeping = on
	dim.Visible = on
	leave.Visible = on
	InventoryClient.uiOpen = on
	CameraController.mouseUnlocked = on
	sleepStart = os.clock()
end

function BedClient.init()
	gui = Instance.new("ScreenGui")
	gui.Name = "Bed"
	gui.ResetOnSpawn = false
	gui.IgnoreGuiInset = true
	gui.DisplayOrder = 15
	dim = Instance.new("Frame")
	dim.Size = UDim2.fromScale(1, 1)
	dim.BackgroundColor3 = Color3.new(0, 0, 0)
	dim.BackgroundTransparency = 1
	dim.BorderSizePixel = 0
	dim.Visible = false
	dim.Parent = gui
	leave = Instance.new("TextButton")
	leave.AnchorPoint = Vector2.new(0.5, 1)
	leave.Position = UDim2.new(0.5, 0, 1, -110)
	leave.Size = UDim2.fromOffset(220, 44)
	leave.BackgroundColor3 = Color3.fromRGB(70, 70, 76)
	leave.BorderSizePixel = 0
	leave.Font = Enum.Font.GothamBold
	leave.TextSize = 20
	leave.TextColor3 = Color3.new(1, 1, 1)
	leave.Text = "Leave Bed"
	leave.Visible = false
	leave.ZIndex = 2
	leave.Parent = gui
	leave.Activated:Connect(function()
		Remotes.get("Bed"):FireServer({ type = "leave" })
	end)
	toast = Instance.new("TextLabel")
	toast.AnchorPoint = Vector2.new(0.5, 1)
	toast.Position = UDim2.new(0.5, 0, 1, -150)
	toast.Size = UDim2.fromOffset(600, 28)
	toast.BackgroundTransparency = 1
	toast.Font = Enum.Font.GothamBold
	toast.TextSize = 18
	toast.TextColor3 = Color3.new(1, 1, 1)
	toast.TextStrokeTransparency = 0.3
	toast.Visible = false
	toast.ZIndex = 3
	toast.Parent = gui
	gui.Parent = Players.LocalPlayer:WaitForChild("PlayerGui")

	Remotes.get("Bed").OnClientEvent:Connect(function(m: any)
		if typeof(m) ~= "table" then
			return
		end
		if m.type == "sleep" then
			setSleeping(true)
		elseif m.type == "wake" then
			setSleeping(false)
		elseif m.type == "message" and typeof(m.text) == "string" then
			BedClient.message(m.text)
		end
	end)
	RunService.RenderStepped:Connect(function()
		if BedClient.sleeping then
			-- Java: the screen fades to dark while you fall asleep
			dim.BackgroundTransparency = 1 - math.clamp((os.clock() - sleepStart) / 5, 0, 1) * 0.85
		end
		if toast.Visible and os.clock() > toastUntil then
			toast.Visible = false
		end
	end)
	Players.LocalPlayer.CharacterAdded:Connect(function()
		if BedClient.sleeping then
			setSleeping(false)
		end
	end)
end

return BedClient
