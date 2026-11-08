--!strict
-- Studio-only test menu (key C): every block and item in the game. Click an item for a full stack,
-- right-click for one. Type in the search box to filter by name. Esc or C closes it.
-- (Testing help only; the real creative inventory comes with Creative mode in phase 21.)

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared.Config)
local Remotes = require(Shared.Net.Remotes)
local ItemRegistry = require(Shared.Items.ItemRegistry)
local ItemIcon = require(script.Parent.ItemIcon)
local InventoryClient = require(script.Parent.Parent.Player.InventoryClient)
local CameraController = require(script.Parent.Parent.Player.CameraController)

local CreativeMenu = {}

function CreativeMenu.init()
	if not RunService:IsStudio() then
		return
	end
	local gui = Instance.new("ScreenGui")
	gui.Name = "CreativeMenu"
	gui.ResetOnSpawn = false
	gui.DisplayOrder = 50
	gui.Enabled = false

	local panel = Instance.new("Frame")
	panel.AnchorPoint = Vector2.new(0.5, 0.5)
	panel.Position = UDim2.fromScale(0.5, 0.5)
	panel.Size = UDim2.fromOffset(560, 420)
	panel.BackgroundColor3 = Color3.fromRGB(28, 30, 38)
	panel.BorderSizePixel = 0
	panel.Parent = gui
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 10)
	corner.Parent = panel
	local scale = Instance.new("UISizeConstraint")
	scale.MaxSize = Vector2.new(560, 420)
	scale.Parent = panel

	local title = Instance.new("TextLabel")
	title.BackgroundTransparency = 1
	title.Position = UDim2.fromOffset(14, 8)
	title.Size = UDim2.new(1, -28, 0, 24)
	title.Font = Enum.Font.GothamBold
	title.TextSize = 16
	title.TextColor3 = Color3.fromRGB(235, 235, 240)
	title.TextXAlignment = Enum.TextXAlignment.Left
	title.Text = "All items (Studio test menu)  -  click: full stack, right-click: one, C / Esc: close"
	title.Parent = panel

	local search = Instance.new("TextBox")
	search.Position = UDim2.fromOffset(14, 38)
	search.Size = UDim2.new(1, -28, 0, 28)
	search.BackgroundColor3 = Color3.fromRGB(44, 47, 58)
	search.BorderSizePixel = 0
	search.Font = Enum.Font.Gotham
	search.TextSize = 14
	search.TextColor3 = Color3.fromRGB(235, 235, 240)
	search.PlaceholderText = "Search..."
	search.Text = ""
	search.ClearTextOnFocus = false
	search.TextXAlignment = Enum.TextXAlignment.Left
	search.Parent = panel
	local sc = Instance.new("UICorner")
	sc.CornerRadius = UDim.new(0, 6)
	sc.Parent = search

	local list = Instance.new("ScrollingFrame")
	list.Position = UDim2.fromOffset(14, 74)
	list.Size = UDim2.new(1, -28, 1, -88)
	list.BackgroundTransparency = 1
	list.BorderSizePixel = 0
	list.ScrollBarThickness = 6
	list.AutomaticCanvasSize = Enum.AutomaticSize.Y
	list.CanvasSize = UDim2.new()
	list.Parent = panel
	local grid = Instance.new("UIGridLayout")
	grid.CellSize = UDim2.fromOffset(48, 48)
	grid.CellPadding = UDim2.fromOffset(6, 6)
	grid.SortOrder = Enum.SortOrder.Name
	grid.Parent = list

	local tooltip = Instance.new("TextLabel")
	tooltip.BackgroundColor3 = Color3.fromRGB(14, 15, 20)
	tooltip.BackgroundTransparency = 0.1
	tooltip.TextColor3 = Color3.fromRGB(240, 240, 245)
	tooltip.Font = Enum.Font.Gotham
	tooltip.TextSize = 13
	tooltip.AutomaticSize = Enum.AutomaticSize.XY
	tooltip.Visible = false
	tooltip.ZIndex = 10
	tooltip.Parent = gui

	local buttons: { { button: TextButton, name: string } } = {}
	local function give(key: string, count: number)
		Remotes.get("DebugAction"):FireServer({ type = "giveItem", item = key, count = count })
	end
	for _, def in ItemRegistry.list() do
		local b = Instance.new("TextButton")
		b.Name = def.name .. " " .. def.key
		b.Text = ""
		b.BackgroundColor3 = Color3.fromRGB(44, 47, 58)
		b.BorderSizePixel = 0
		b.AutoButtonColor = true
		local bc = Instance.new("UICorner")
		bc.CornerRadius = UDim.new(0, 6)
		bc.Parent = b
		local icon = Instance.new("Frame")
		icon.BackgroundTransparency = 1
		icon.AnchorPoint = Vector2.new(0.5, 0.5)
		icon.Position = UDim2.fromScale(0.5, 0.5)
		icon.Size = UDim2.fromOffset(36, 36)
		icon.Parent = b
		ItemIcon.draw(icon, def.key)
		local key, stack = def.key, def.stack
		b.MouseButton1Click:Connect(function()
			give(key, stack)
		end)
		b.MouseButton2Click:Connect(function()
			give(key, 1)
		end)
		b.MouseEnter:Connect(function()
			tooltip.Text = ` {def.name} `
			tooltip.Visible = true
		end)
		b.MouseLeave:Connect(function()
			tooltip.Visible = false
		end)
		b.Parent = list
		table.insert(buttons, { button = b, name = string.lower(def.name .. " " .. def.key) })
	end
	search:GetPropertyChangedSignal("Text"):Connect(function()
		local q = string.lower(search.Text)
		for _, e in buttons do
			e.button.Visible = q == "" or string.find(e.name, q, 1, true) ~= nil
		end
	end)
	RunService.RenderStepped:Connect(function()
		if tooltip.Visible then
			local m = UserInputService:GetMouseLocation()
			tooltip.Position = UDim2.fromOffset(m.X + 14, m.Y - 30)
		end
	end)

	local function setOpen(on: boolean)
		gui.Enabled = on
		InventoryClient.uiOpen = on
		CameraController.mouseUnlocked = on
		tooltip.Visible = false
		if not on then
			search:ReleaseFocus()
		end
	end
	UserInputService.InputBegan:Connect(function(input, processed)
		if input.KeyCode == Enum.KeyCode.Escape and gui.Enabled then
			setOpen(false)
			return
		end
		if processed or search:IsFocused() then
			return
		end
		if input.KeyCode == (Enum.KeyCode :: any)[Config.DEBUG_KEY_ITEM_MENU] then
			setOpen(not gui.Enabled)
		end
	end)
	gui.Parent = Players.LocalPlayer:WaitForChild("PlayerGui")
end

return CreativeMenu
