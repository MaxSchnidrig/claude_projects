--!strict
--[[
	Kit
	===
	Building blocks for the game's UI, so every window and button looks and
	behaves the same:
	  - Kit.button(...)      a big rounded button with a click sound and a "press" bounce
	  - Kit.label(...)       a text label in the game's font
	  - Kit.leftColumn()     the column in the top-left (stats panel + menu buttons)
	  - Kit.menuButton(...)  adds a button to that column
	  - Kit.window(...)      a centered window with a title and ✕ button;
	                         only one window is open at a time
	  - Kit.autoScale(obj)   scales something to fit the screen (phones to big monitors)

	Scaling: everything is designed for a 1280x720 screen. On other screens
	it's scaled by Config.UI.MinScale..MaxScale (never below TouchMinScale on
	phones/tablets, so buttons stay big enough to tap).
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")

local Config = require(ReplicatedStorage.Shared.Config)
local Sounds = require(script.Parent.Sounds)

local Kit = {}

Kit.Colors = {
	Panel = Color3.fromRGB(20, 30, 50),
	Card = Color3.fromRGB(35, 50, 80),
	Accent = Color3.fromRGB(90, 200, 255),
	Green = Color3.fromRGB(70, 200, 100),
	Grey = Color3.fromRGB(110, 110, 125),
	Red = Color3.fromRGB(220, 70, 70),
	Gold = Color3.fromRGB(240, 180, 40),
	Text = Color3.new(1, 1, 1),
	SubText = Color3.fromRGB(190, 210, 240),
}

local player = Players.LocalPlayer

---------------------------------------------------------------------------
-- Small helpers
---------------------------------------------------------------------------

function Kit.corner(parent: GuiObject, radius: number?)
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, radius or 12)
	corner.Parent = parent
end

function Kit.stroke(parent: GuiObject, color: Color3, thickness: number?)
	local stroke = Instance.new("UIStroke")
	stroke.Color = color
	stroke.Thickness = thickness or 2
	stroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	stroke.Parent = parent
end

function Kit.label(parent: Instance, text: string, size: UDim2, position: UDim2, color: Color3?): TextLabel
	local label = Instance.new("TextLabel")
	label.BackgroundTransparency = 1
	label.Font = Enum.Font.FredokaOne
	label.TextScaled = true
	label.TextXAlignment = Enum.TextXAlignment.Left
	label.TextColor3 = color or Kit.Colors.Text
	label.Text = text
	label.Size = size
	label.Position = position
	label.Parent = parent
	return label
end

function Kit.button(parent: Instance, text: string, color: Color3, size: UDim2, position: UDim2?): TextButton
	local button = Instance.new("TextButton")
	button.Size = size
	button.Position = position or UDim2.new()
	button.BackgroundColor3 = color
	button.Font = Enum.Font.FredokaOne
	button.TextScaled = true
	button.TextColor3 = Kit.Colors.Text
	button.Text = text
	button.Parent = parent
	Kit.corner(button, 10)
	local padding = Instance.new("UIPadding")
	padding.PaddingTop = UDim.new(0, 7)
	padding.PaddingBottom = UDim.new(0, 7)
	padding.PaddingLeft = UDim.new(0, 6)
	padding.PaddingRight = UDim.new(0, 6)
	padding.Parent = button
	local scale = Instance.new("UIScale")
	scale.Parent = button

	-- A quick "press" bounce and click sound.
	button.Activated:Connect(function()
		Sounds.play("Click")
		scale.Scale = 0.92
		TweenService:Create(scale, TweenInfo.new(0.15, Enum.EasingStyle.Back, Enum.EasingDirection.Out), { Scale = 1 }):Play()
	end)
	return button
end

function Kit.screenGui(name: string, displayOrder: number?): ScreenGui
	local gui = Instance.new("ScreenGui")
	gui.Name = name
	gui.ResetOnSpawn = false
	gui.DisplayOrder = displayOrder or 0
	gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	gui.Parent = player:WaitForChild("PlayerGui")
	return gui
end

---------------------------------------------------------------------------
-- Screen-size scaling
---------------------------------------------------------------------------

local scalers: { { Scale: UIScale, Fit: Vector2? } } = {}

local function screenScale(): number
	local camera = Workspace.CurrentCamera
	local viewport = if camera then camera.ViewportSize else Vector2.new(1280, 720)
	local scale = math.min(viewport.X / 1280, viewport.Y / 720)
	local minimum = Config.UI.MinScale
	if UserInputService.TouchEnabled and not UserInputService.KeyboardEnabled then
		minimum = Config.UI.TouchMinScale
	end
	return math.clamp(scale, minimum, Config.UI.MaxScale)
end

local function updateScales()
	local camera = Workspace.CurrentCamera
	local viewport = if camera then camera.ViewportSize else Vector2.new(1280, 720)
	local scale = screenScale()
	for _, entry in scalers do
		local value = scale
		-- Windows must always fit on the screen, even on tiny ones.
		if entry.Fit then
			value = math.min(value, (viewport.X - 24) / entry.Fit.X, (viewport.Y - 24) / entry.Fit.Y)
		end
		entry.Scale.Scale = value
	end
end

-- Scale `object` with the screen. `fitSize`: the object's full size in
-- pixels; if given, it's also shrunk until it fits on the screen.
function Kit.autoScale(object: GuiObject, fitSize: Vector2?): UIScale
	local scale = Instance.new("UIScale")
	scale.Parent = object
	local entry = { Scale = scale, Fit = fitSize }
	table.insert(scalers, entry)
	-- Forget it again when the object is destroyed (popups, splashes).
	object.Destroying:Connect(function()
		local index = table.find(scalers, entry)
		if index then
			table.remove(scalers, index)
		end
	end)
	updateScales()
	return scale
end

local function watchViewport()
	local function hook()
		local camera = Workspace.CurrentCamera
		if camera then
			camera:GetPropertyChangedSignal("ViewportSize"):Connect(updateScales)
		end
		updateScales()
	end
	Workspace:GetPropertyChangedSignal("CurrentCamera"):Connect(hook)
	hook()
end
watchViewport()

---------------------------------------------------------------------------
-- Left column: stats panel + menu buttons
---------------------------------------------------------------------------

local column: Frame? = nil

function Kit.leftColumn(): Frame
	if column then
		return column
	end
	local gui = Kit.screenGui("Hud", 1)
	local frame = Instance.new("Frame")
	frame.Name = "LeftColumn"
	frame.Position = UDim2.fromOffset(16, 64)
	frame.Size = UDim2.fromOffset(210, 400)
	frame.BackgroundTransparency = 1
	frame.Parent = gui
	local layout = Instance.new("UIListLayout")
	layout.Padding = UDim.new(0, 8)
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Parent = frame
	Kit.autoScale(frame)
	column = frame
	return frame
end

-- A big button in the left column. Lower `order` = higher up.
function Kit.menuButton(text: string, color: Color3, order: number): TextButton
	local button = Kit.button(Kit.leftColumn(), text, color, UDim2.fromOffset(210, 50))
	button.LayoutOrder = order
	return button
end

---------------------------------------------------------------------------
-- Windows (only one open at a time)
---------------------------------------------------------------------------

export type Window = {
	Frame: Frame,
	Content: Frame, -- put the window's content in here
	Open: () -> (),
	Close: () -> (),
	Toggle: () -> (),
	IsOpen: () -> boolean,
}

local openWindow: Window? = nil
local windowGui: ScreenGui? = nil

function Kit.window(title: string, size: Vector2): Window
	if not windowGui then
		windowGui = Kit.screenGui("Windows", 15)
	end

	local frame = Instance.new("Frame")
	frame.Name = title
	frame.AnchorPoint = Vector2.new(0.5, 0.5)
	frame.Position = UDim2.fromScale(0.5, 0.5)
	frame.Size = UDim2.fromOffset(size.X, size.Y)
	frame.BackgroundColor3 = Kit.Colors.Panel
	frame.Visible = false
	frame.Parent = windowGui
	Kit.corner(frame, 16)
	Kit.stroke(frame, Kit.Colors.Accent, 3)
	local scale = Kit.autoScale(frame, size)

	Kit.label(frame, title, UDim2.new(1, -80, 0, 40), UDim2.fromOffset(16, 10))
	local close = Kit.button(frame, "✕", Kit.Colors.Red, UDim2.fromOffset(44, 44), UDim2.new(1, -54, 0, 8))

	local content = Instance.new("Frame")
	content.Name = "Content"
	content.Position = UDim2.fromOffset(16, 62)
	content.Size = UDim2.new(1, -32, 1, -76)
	content.BackgroundTransparency = 1
	content.Parent = frame

	local window: Window
	local function open()
		if openWindow and openWindow ~= window then
			openWindow.Close()
		end
		openWindow = window
		frame.Visible = true
		-- Pop in with a small bounce, on top of the screen-size scale.
		local target = scale.Scale
		scale.Scale = target * 0.8
		TweenService:Create(scale, TweenInfo.new(0.25, Enum.EasingStyle.Back, Enum.EasingDirection.Out), { Scale = target }):Play()
	end
	local function closeWindow()
		frame.Visible = false
		if openWindow == window then
			openWindow = nil
		end
		updateScales() -- undo any half-finished pop-in tween
	end
	window = {
		Frame = frame,
		Content = content,
		Open = open,
		Close = closeWindow,
		Toggle = function()
			if frame.Visible then
				closeWindow()
			else
				open()
			end
		end,
		IsOpen = function()
			return frame.Visible
		end,
	}
	close.Activated:Connect(closeWindow)
	return window
end

return Kit
