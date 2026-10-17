--!strict
--[[
	Kit
	===
	Building blocks for the game's UI, so every window and button looks the
	same: bright colors, thick dark outlines, bold white text with a black
	outline (the "Steal an Egg" style).

	  - Kit.label(...)        bold outlined text
	  - Kit.button(...)       a chunky outlined button (click sound + press bounce)
	                          Kit.setText(button, text) changes its text
	  - Kit.badge(button)     a small red number bubble on a button (returns a setter)
	  - Kit.window(...)       a window with a colored title bar and a red ✕;
	                          only one window is open at a time. Side = "Right"
	                          makes it a panel on the right side of the screen.
	  - Kit.autoScale(obj)    scales something to fit the screen (phones to big monitors)
	  - Kit.corner / Kit.stroke / Kit.screenGui  small helpers

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
	Panel = Color3.fromRGB(30, 36, 58),
	Card = Color3.fromRGB(48, 58, 90),
	Outline = Color3.fromRGB(18, 20, 30),
	Accent = Color3.fromRGB(60, 180, 245),
	Green = Color3.fromRGB(95, 205, 50),
	Blue = Color3.fromRGB(40, 165, 240),
	Orange = Color3.fromRGB(245, 150, 40),
	Grey = Color3.fromRGB(110, 115, 130),
	Red = Color3.fromRGB(230, 60, 60),
	Gold = Color3.fromRGB(245, 185, 40),
	Text = Color3.new(1, 1, 1),
	SubText = Color3.fromRGB(200, 215, 240),
}

local FONT = Enum.Font.FredokaOne
local player = Players.LocalPlayer

-- True on phones/tablets (touch screen, no keyboard).
function Kit.isTouch(): boolean
	return UserInputService.TouchEnabled and not UserInputService.KeyboardEnabled
end

---------------------------------------------------------------------------
-- Small helpers
---------------------------------------------------------------------------

function Kit.corner(parent: GuiObject, radius: number?)
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, radius or 12)
	corner.Parent = parent
end

-- An outline around a frame/button.
function Kit.stroke(parent: GuiObject, color: Color3?, thickness: number?): UIStroke
	local stroke = Instance.new("UIStroke")
	stroke.Color = color or Kit.Colors.Outline
	stroke.Thickness = thickness or 3
	stroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	stroke.LineJoinMode = Enum.LineJoinMode.Round
	stroke.Parent = parent
	return stroke
end

-- A black outline around the letters of a text label.
function Kit.textStroke(label: TextLabel | TextButton, thickness: number?): UIStroke
	local stroke = Instance.new("UIStroke")
	stroke.Color = Kit.Colors.Outline
	stroke.Thickness = thickness or 2
	stroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Contextual
	stroke.LineJoinMode = Enum.LineJoinMode.Round
	stroke.Parent = label
	return stroke
end

function Kit.label(parent: Instance, text: string, size: UDim2, position: UDim2, color: Color3?, strokeThickness: number?): TextLabel
	local label = Instance.new("TextLabel")
	label.BackgroundTransparency = 1
	label.Font = FONT
	label.TextScaled = true
	label.TextXAlignment = Enum.TextXAlignment.Left
	label.TextColor3 = color or Kit.Colors.Text
	label.Text = text
	label.Size = size
	label.Position = position
	label.Parent = parent
	Kit.textStroke(label, strokeThickness)
	return label
end

-- A chunky button: colored, thick dark outline, a lighter top half (shine)
-- and outlined text. Change its text with Kit.setText.
function Kit.button(parent: Instance, text: string, color: Color3, size: UDim2, position: UDim2?): TextButton
	local button = Instance.new("TextButton")
	button.Size = size
	button.Position = position or UDim2.new()
	button.BackgroundColor3 = color
	button.AutoButtonColor = true
	button.Text = ""
	button.Parent = parent
	Kit.corner(button, 10)
	Kit.stroke(button, Kit.Colors.Outline, 3)

	-- Shine on the top half.
	local shine = Instance.new("Frame")
	shine.Name = "Shine"
	shine.Size = UDim2.new(1, -8, 0.42, 0)
	shine.Position = UDim2.fromOffset(4, 3)
	shine.BackgroundColor3 = Color3.new(1, 1, 1)
	shine.BackgroundTransparency = 0.82
	shine.BorderSizePixel = 0
	shine.Parent = button
	Kit.corner(shine, 8)

	local label = Kit.label(button, text, UDim2.new(1, -12, 1, -10), UDim2.fromOffset(6, 5), Kit.Colors.Text, 2)
	label.Name = "Label"
	label.TextXAlignment = Enum.TextXAlignment.Center
	label.ZIndex = 2

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

function Kit.setText(button: TextButton, text: string)
	local label = button:FindFirstChild("Label")
	if label and label:IsA("TextLabel") then
		label.Text = text
	end
end

-- Recolor a Kit.button (for example grey when you can't afford it).
function Kit.setColor(button: TextButton, color: Color3)
	button.BackgroundColor3 = color
end

-- A small red bubble with a number in the top-right corner of `button`.
-- Returns a function to set the number (0 = hidden).
function Kit.badge(button: GuiObject): (number) -> ()
	local bubble = Instance.new("Frame")
	bubble.Name = "Badge"
	bubble.AnchorPoint = Vector2.new(0.5, 0.5)
	bubble.Position = UDim2.new(1, -4, 0, 4)
	bubble.Size = UDim2.fromOffset(30, 30)
	bubble.BackgroundColor3 = Kit.Colors.Red
	bubble.Visible = false
	bubble.ZIndex = 5
	bubble.Parent = button
	Kit.corner(bubble, 15)
	local outline = Kit.stroke(bubble, Color3.new(1, 1, 1), 2)
	outline.Color = Color3.new(1, 1, 1)
	local text = Kit.label(bubble, "", UDim2.new(1, -6, 1, -6), UDim2.fromOffset(3, 3))
	text.TextXAlignment = Enum.TextXAlignment.Center
	text.ZIndex = 6
	local popScale = Instance.new("UIScale")
	popScale.Parent = bubble
	local shown = 0
	return function(count: number)
		bubble.Visible = count > 0
		text.Text = if count > 99 then "99+" else tostring(count)
		if count > shown then
			-- A little pop when something new arrives.
			popScale.Scale = 1.6
			TweenService:Create(popScale, TweenInfo.new(0.35, Enum.EasingStyle.Back, Enum.EasingDirection.Out), { Scale = 1 }):Play()
		end
		shown = count
	end
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

-- A vertical list layout inside `parent`.
function Kit.list(parent: Instance, padding: number?, horizontal: boolean?): UIListLayout
	local layout = Instance.new("UIListLayout")
	layout.Padding = UDim.new(0, padding or 8)
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	if horizontal then
		layout.FillDirection = Enum.FillDirection.Horizontal
	end
	layout.Parent = parent
	return layout
end

-- A scrolling area that grows with its content.
function Kit.scroll(parent: Instance, size: UDim2, position: UDim2): ScrollingFrame
	local scroll = Instance.new("ScrollingFrame")
	scroll.Size = size
	scroll.Position = position
	scroll.BackgroundTransparency = 1
	scroll.BorderSizePixel = 0
	scroll.ScrollBarThickness = 8
	scroll.ScrollBarImageColor3 = Kit.Colors.Accent
	scroll.AutomaticCanvasSize = Enum.AutomaticSize.Y
	scroll.CanvasSize = UDim2.new()
	scroll.Parent = parent
	return scroll
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
	if Kit.isTouch() then
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
-- Windows (only one open at a time)
---------------------------------------------------------------------------

export type Window = {
	Frame: Frame,
	Content: Frame, -- put the window's content in here
	Open: () -> (),
	Close: () -> (),
	Toggle: () -> (),
	IsOpen: () -> boolean,
	Opened: BindableEvent, -- fires every time the window opens
}

export type WindowOptions = {
	Color: Color3?, -- title bar color
	Side: string?, -- "Center" (default) or "Right"
}

local openWindow: Window? = nil
local windowGui: ScreenGui? = nil

function Kit.window(title: string, size: Vector2, options: WindowOptions?): Window
	local o: WindowOptions = options or {}
	if not windowGui then
		windowGui = Kit.screenGui("Windows", 15)
	end
	local barColor = o.Color or Kit.Colors.Blue
	local right = o.Side == "Right"

	local frame = Instance.new("Frame")
	frame.Name = title
	if right then
		frame.AnchorPoint = Vector2.new(1, 0.5)
		frame.Position = UDim2.new(1, -110, 0.5, 0)
	else
		frame.AnchorPoint = Vector2.new(0.5, 0.5)
		frame.Position = UDim2.fromScale(0.5, 0.5)
	end
	frame.Size = UDim2.fromOffset(size.X, size.Y)
	frame.BackgroundColor3 = Kit.Colors.Panel
	frame.Visible = false
	frame.Parent = windowGui
	Kit.corner(frame, 14)
	Kit.stroke(frame, Kit.Colors.Outline, 4)
	local scale = Kit.autoScale(frame, size + Vector2.new(if right then 120 else 0, 0))

	-- Title bar with diagonal stripes, like a sticker.
	local bar = Instance.new("Frame")
	bar.Name = "TitleBar"
	bar.Size = UDim2.new(1, 0, 0, 58)
	bar.BackgroundColor3 = barColor
	bar.ClipsDescendants = true
	bar.Parent = frame
	Kit.corner(bar, 14)
	for i = 0, 2 do
		local stripe = Instance.new("Frame")
		stripe.AnchorPoint = Vector2.new(0.5, 0.5)
		stripe.Position = UDim2.new(0.55 + i * 0.09, 0, 0.5, 0)
		stripe.Size = UDim2.new(0, 22, 2, 0)
		stripe.Rotation = 25
		stripe.BackgroundColor3 = Color3.new(1, 1, 1)
		stripe.BackgroundTransparency = 0.8
		stripe.BorderSizePixel = 0
		stripe.Parent = bar
	end
	Kit.label(bar, title, UDim2.new(1, -90, 0, 42), UDim2.fromOffset(16, 8), Kit.Colors.Text, 3)
	local close = Kit.button(frame, "X", Kit.Colors.Red, UDim2.fromOffset(46, 46), UDim2.new(1, -54, 0, 6))
	close.ZIndex = 3

	local content = Instance.new("Frame")
	content.Name = "Content"
	content.Position = UDim2.fromOffset(14, 70)
	content.Size = UDim2.new(1, -28, 1, -84)
	content.BackgroundTransparency = 1
	content.Parent = frame

	local opened = Instance.new("BindableEvent")
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
		opened:Fire()
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
		Opened = opened,
	}
	close.Activated:Connect(closeWindow)
	return window
end

return Kit
