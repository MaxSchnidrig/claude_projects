--!strict
-- Building blocks for our menus (title screen, pause menu, settings, world settings): one look,
-- and every control works with a mouse, a touch screen and a gamepad. Our own design: dark slate
-- panels, flat rounded buttons, a warm gold title.
--
-- Pages are centred panels that never get wider than the screen (16 px gutter) and scroll when
-- they are taller, so they fit a phone held sideways.

local Players = game:GetService("Players")
local UserInputService = game:GetService("UserInputService")

local MenuKit = {}

MenuKit.COLORS = {
	backdrop = Color3.fromRGB(12, 13, 18),
	panel = Color3.fromRGB(32, 35, 46),
	inset = Color3.fromRGB(24, 26, 34),
	button = Color3.fromRGB(60, 64, 80),
	buttonHover = Color3.fromRGB(76, 81, 100),
	primary = Color3.fromRGB(60, 140, 80),
	danger = Color3.fromRGB(160, 60, 60),
	text = Color3.fromRGB(238, 238, 244),
	muted = Color3.fromRGB(165, 168, 182),
	title = Color3.fromRGB(250, 220, 120),
	hardcore = Color3.fromRGB(220, 80, 80),
	accent = Color3.fromRGB(110, 170, 230),
}
local C = MenuKit.COLORS
local ROW = 44 -- button height (a comfortable touch target)

local function make(className: string, props: { [string]: any }, parent: Instance?): any
	local o = Instance.new(className)
	for k, v in props do
		(o :: any)[k] = v
	end
	if parent then
		o.Parent = parent
	end
	return o
end
MenuKit.make = make

local function corner(parent: Instance, r: number)
	make("UICorner", { CornerRadius = UDim.new(0, r) }, parent)
end
MenuKit.corner = corner

-- A full-screen ScreenGui for menus, above the game's HUD.
function MenuKit.screen(name: string, order: number): ScreenGui
	return make("ScreenGui", {
		Name = name,
		ResetOnSpawn = false,
		IgnoreGuiInset = true,
		DisplayOrder = order,
		ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
	}, nil)
end

-- A page: a dimmed backdrop (opaque on the title screen) with a centred panel, a title and a
-- scrolling list that holds the controls. Returns (backdrop, list).
function MenuKit.page(parent: Instance, title: string, opaque: boolean?): (Frame, ScrollingFrame)
	local backdrop = make("Frame", {
		Name = title,
		Size = UDim2.fromScale(1, 1),
		BackgroundColor3 = C.backdrop,
		BackgroundTransparency = if opaque then 0 else 0.35,
		BorderSizePixel = 0,
		Active = true, -- clicks don't fall through to the game
		Visible = false,
	}, parent)
	local panel = make("Frame", {
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.new(1, -32, 1, -32),
		BackgroundColor3 = C.panel,
		BorderSizePixel = 0,
	}, backdrop)
	corner(panel, 14)
	make("UISizeConstraint", { MaxSize = Vector2.new(520, 640) }, panel)
	make("TextLabel", {
		Position = UDim2.fromOffset(16, 10),
		Size = UDim2.new(1, -32, 0, 40),
		BackgroundTransparency = 1,
		Text = title,
		TextColor3 = C.title,
		Font = Enum.Font.GothamBlack,
		TextScaled = true,
	}, panel).Name = "Title"
	local list = make("ScrollingFrame", {
		Name = "List",
		Position = UDim2.fromOffset(16, 58),
		Size = UDim2.new(1, -32, 1, -70),
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		ScrollBarThickness = 6,
		ScrollingDirection = Enum.ScrollingDirection.Y,
		AutomaticCanvasSize = Enum.AutomaticSize.Y,
		CanvasSize = UDim2.new(),
	}, panel)
	make("UIListLayout", { Padding = UDim.new(0, 8), SortOrder = Enum.SortOrder.LayoutOrder }, list)
	make("UIPadding", { PaddingRight = UDim.new(0, 8), PaddingBottom = UDim.new(0, 4) }, list)
	return backdrop, list
end

local order = 0
local function nextOrder(): number
	order += 1
	return order
end

function MenuKit.button(parent: Instance, text: string, kind: string?): TextButton
	local base = if kind == "primary" then C.primary elseif kind == "danger" then C.danger else C.button
	local b = make("TextButton", {
		LayoutOrder = nextOrder(),
		Size = UDim2.new(1, 0, 0, ROW),
		BackgroundColor3 = base,
		TextColor3 = C.text,
		Font = Enum.Font.GothamBold,
		TextSize = 18,
		TextWrapped = true,
		Text = text,
		AutoButtonColor = true,
		Selectable = true,
	}, parent)
	corner(b, 8)
	return b
end

-- Buttons side by side; returns the row (put buttons in it with MenuKit.button).
function MenuKit.row(parent: Instance): Frame
	local r = make("Frame", {
		LayoutOrder = nextOrder(),
		Size = UDim2.new(1, 0, 0, ROW),
		BackgroundTransparency = 1,
	}, parent)
	make("UIListLayout", {
		FillDirection = Enum.FillDirection.Horizontal,
		Padding = UDim.new(0, 8),
		SortOrder = Enum.SortOrder.LayoutOrder,
	}, r)
	-- share the width equally between the buttons in the row
	local function spread()
		local items = {}
		for _, c in r:GetChildren() do
			if c:IsA("GuiObject") then
				table.insert(items, c)
			end
		end
		local n = #items
		for _, c in items do
			c.Size = UDim2.new(1 / n, -8 * (n - 1) / n, 1, 0)
		end
	end
	r.ChildAdded:Connect(function()
		task.defer(spread)
	end)
	return r
end

function MenuKit.label(parent: Instance, text: string, muted: boolean?, height: number?): TextLabel
	return make("TextLabel", {
		LayoutOrder = nextOrder(),
		Size = UDim2.new(1, 0, 0, height or 24),
		AutomaticSize = if height then Enum.AutomaticSize.None else Enum.AutomaticSize.Y,
		BackgroundTransparency = 1,
		Text = text,
		TextWrapped = true,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextColor3 = if muted then C.muted else C.text,
		Font = if muted then Enum.Font.Gotham else Enum.Font.GothamBold,
		TextSize = if muted then 14 else 16,
	}, parent)
end

-- A button that steps through `options` ({ value, text } pairs): "Difficulty: Normal".
function MenuKit.cycle(parent: Instance, label: string, options: { { any } }, get: () -> any, set: (any) -> ()): (TextButton, () -> ())
	local b = MenuKit.button(parent, "")
	local function refresh()
		local v = get()
		local text = tostring(v)
		for _, o in options do
			if o[1] == v then
				text = o[2]
			end
		end
		b.Text = `{label}: {text}`
	end
	b.Activated:Connect(function()
		local v = get()
		local i = 0
		for k, o in options do
			if o[1] == v then
				i = k
			end
		end
		set(options[i % #options + 1][1])
		refresh()
	end)
	refresh()
	return b, refresh
end

function MenuKit.toggle(parent: Instance, label: string, get: () -> boolean, set: (boolean) -> ()): (TextButton, () -> ())
	return MenuKit.cycle(parent, label, { { true, "ON" }, { false, "OFF" } }, get, set)
end

-- A slider: label and value on the bar, drag (mouse or touch) or use the gamepad's left / right.
function MenuKit.slider(parent: Instance, label: string, min: number, max: number, step: number,
	get: () -> number, set: (number) -> (), format: ((number) -> string)?): (Frame, () -> ())
	local bar = make("TextButton", {
		LayoutOrder = nextOrder(),
		Size = UDim2.new(1, 0, 0, ROW),
		BackgroundColor3 = C.inset,
		AutoButtonColor = false,
		Text = "",
		Selectable = true,
	}, parent)
	corner(bar, 8)
	local fill = make("Frame", {
		Size = UDim2.fromScale(0, 1),
		BackgroundColor3 = C.button,
		BorderSizePixel = 0,
	}, bar)
	corner(fill, 8)
	local text = make("TextLabel", {
		Size = UDim2.fromScale(1, 1),
		BackgroundTransparency = 1,
		TextColor3 = C.text,
		Font = Enum.Font.GothamBold,
		TextSize = 17,
		ZIndex = 2,
	}, bar)
	local function show()
		local v = get()
		fill.Size = UDim2.fromScale(math.clamp((v - min) / (max - min), 0, 1), 1)
		text.Text = `{label}: {if format then format(v) else tostring(v)}`
	end
	local function setFromX(x: number)
		local f = math.clamp((x - bar.AbsolutePosition.X) / math.max(1, bar.AbsoluteSize.X), 0, 1)
		local v = min + math.floor(f * (max - min) / step + 0.5) * step
		v = math.clamp(v, min, max)
		if v ~= get() then
			set(v)
		end
		show()
	end
	local dragging: InputObject? = nil
	bar.InputBegan:Connect(function(input: InputObject)
		local t = input.UserInputType
		if t == Enum.UserInputType.MouseButton1 or t == Enum.UserInputType.Touch then
			dragging = input
			setFromX(input.Position.X)
		elseif input.KeyCode == Enum.KeyCode.DPadLeft or input.KeyCode == Enum.KeyCode.Left then
			set(math.clamp(get() - step, min, max))
			show()
		elseif input.KeyCode == Enum.KeyCode.DPadRight or input.KeyCode == Enum.KeyCode.Right then
			set(math.clamp(get() + step, min, max))
			show()
		end
	end)
	UserInputService.InputChanged:Connect(function(input: InputObject)
		if dragging and (input == dragging or input.UserInputType == Enum.UserInputType.MouseMovement) then
			setFromX(input.Position.X)
		end
	end)
	UserInputService.InputEnded:Connect(function(input: InputObject)
		if dragging and (input == dragging or input.UserInputType == Enum.UserInputType.MouseButton1) then
			dragging = nil
		end
	end)
	show()
	return bar, show
end

function MenuKit.textbox(parent: Instance, placeholder: string, maxLength: number): TextBox
	local box = make("TextBox", {
		LayoutOrder = nextOrder(),
		Size = UDim2.new(1, 0, 0, ROW),
		BackgroundColor3 = C.inset,
		TextColor3 = C.text,
		PlaceholderText = placeholder,
		PlaceholderColor3 = C.muted,
		Font = Enum.Font.Gotham,
		TextSize = 17,
		Text = "",
		ClearTextOnFocus = false,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextTruncate = Enum.TextTruncate.AtEnd,
	}, parent)
	corner(box, 8)
	make("UIPadding", { PaddingLeft = UDim.new(0, 12), PaddingRight = UDim.new(0, 12) }, box)
	box:GetPropertyChangedSignal("Text"):Connect(function()
		if utf8.len(box.Text) and (utf8.len(box.Text) :: number) > maxLength then
			box.Text = string.sub(box.Text, 1, utf8.offset(box.Text, maxLength + 1) - 1)
		end
	end)
	return box
end

-- A yes / no question over everything in `gui`. `onYes` runs when confirmed.
function MenuKit.confirm(gui: Instance, question: string, detail: string?, yesText: string, onYes: () -> ())
	local backdrop, list = MenuKit.page(gui, question)
	backdrop.ZIndex = 50
	for _, d in backdrop:GetDescendants() do
		if d:IsA("GuiObject") then
			d.ZIndex += 50
		end
	end
	if detail then
		local l = MenuKit.label(list, detail, true)
		l.ZIndex = 51
	end
	local row = MenuKit.row(list)
	local yes = MenuKit.button(row, yesText, "danger")
	local no = MenuKit.button(row, "Cancel")
	yes.ZIndex, no.ZIndex = 52, 52
	local function close()
		backdrop:Destroy()
	end
	yes.Activated:Connect(function()
		close()
		onYes()
	end)
	no.Activated:Connect(close)
	backdrop.Visible = true
end

-- Show one page of a set, hide the others.
function MenuKit.show(pages: { [string]: GuiObject }, name: string?)
	for k, p in pages do
		p.Visible = k == name
	end
end

function MenuKit.playerGui(): PlayerGui
	return Players.LocalPlayer:WaitForChild("PlayerGui") :: PlayerGui
end

return MenuKit
