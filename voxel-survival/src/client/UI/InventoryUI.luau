--!strict
-- Inventory / container screen (original look: dark panel, tiles like the hotbar).
--
--   E (Config.KEY_INVENTORY)  open/close the inventory (2x2 crafting)
--   right-click a Crafting Table / Furnace / Chest  -> the server opens that window (3x3 crafting,
--                                                     furnace, chest) and this UI follows
--   left click   pick up / put down / merge / swap       right click  take half / put one
--   shift-click  quick-move                              click outside the panel: drop the
--   result slot  craft once (shift: craft all)           carried stack (right: drop one)
--   touch        tap = left click; the "½" toggle makes taps act like right clicks
--
-- The server owns every slot; this module only draws InventoryClient state and sends clicks.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local GuiService = game:GetService("GuiService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared.Config)
local ItemRegistry = require(Shared.Items.ItemRegistry)
local Recipes = require(Shared.Items.Recipes)
local InventoryClient = require(script.Parent.Parent.Player.InventoryClient)
local CameraController = require(script.Parent.Parent.Player.CameraController)
local ItemIcon = require(script.Parent.ItemIcon)

local SLOT = 44
local GAP = 4
local PAD = 12
local COLS = 9
local PANEL_W = PAD * 2 + COLS * SLOT + (COLS - 1) * GAP

local InventoryUI = {}

type Widget = {
	container: string,
	index: number,
	button: TextButton,
	icon: Frame,
	count: TextLabel,
	durabilityBg: Frame,
	durability: Frame,
	shown: string?,
}

local gui: ScreenGui
local panel: Frame
local cursorFrame: Frame
local cursorIcon: Frame
local cursorCount: TextLabel
local tooltip: TextLabel
local widgets: { Widget } = {}
local layoutKind: string? = nil
local hovered: Widget? = nil
local splitMode = false
-- Modifier keys, tracked from key events (UserInputService:IsKeyDown missed Shift during
-- GUI clicks in a Studio test on macOS). Both sources are combined.
local shiftHeld, ctrlHeld = false, false
local shiftMarker: TextLabel? = nil
local function shiftDown(): boolean
	return shiftHeld or UserInputService:IsKeyDown(Enum.KeyCode.LeftShift) or UserInputService:IsKeyDown(Enum.KeyCode.RightShift)
end
local function ctrlDown(): boolean
	-- Ctrl only: Cmd+Q would quit Studio on a Mac
	return ctrlHeld or UserInputService:IsKeyDown(Enum.KeyCode.LeftControl) or UserInputService:IsKeyDown(Enum.KeyCode.RightControl)
end
local furnaceArrow: Frame? = nil
local furnaceFlame: Frame? = nil

local TITLES = {
	inventory = "Inventory",
	crafting_table = "Crafting Table",
	furnace = "Furnace",
	chest = "Chest",
}

local function stackFor(w: Widget): InventoryClient.Stack?
	local win = InventoryClient.window
	if w.container == "inv" then
		return InventoryClient.slots[w.index]
	elseif w.container == "craft" then
		return win.craft and win.craft[w.index]
	elseif w.container == "result" then
		return win.result
	elseif w.container == "block" then
		return win.block and win.block[w.index]
	end
	return nil
end

local function label(parent: Instance, text: string, pos: UDim2, size: UDim2, textSize: number?): TextLabel
	local l = Instance.new("TextLabel")
	l.BackgroundTransparency = 1
	l.Font = Enum.Font.GothamBold
	l.TextSize = textSize or 15
	l.TextColor3 = Color3.fromRGB(225, 228, 236)
	l.TextXAlignment = Enum.TextXAlignment.Left
	l.Text = text
	l.Position = pos
	l.Size = size
	l.Parent = parent
	return l
end

local function slot(x: number, y: number, container: string, index: number, big: boolean?): Widget
	local size = if big then SLOT + 8 else SLOT
	local b = Instance.new("TextButton")
	b.Text = ""
	b.AutoButtonColor = false
	b.BackgroundColor3 = Color3.fromRGB(14, 15, 19)
	b.BackgroundTransparency = 0.1
	b.BorderSizePixel = 0
	b.Position = UDim2.fromOffset(x, y)
	b.Size = UDim2.fromOffset(size, size)
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 4)
	corner.Parent = b
	local stroke = Instance.new("UIStroke")
	stroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	stroke.Color = Color3.fromRGB(150, 154, 166)
	stroke.Transparency = 0.5
	stroke.Parent = b

	local icon = Instance.new("Frame")
	icon.BorderSizePixel = 0
	icon.BackgroundTransparency = 1
	icon.AnchorPoint = Vector2.new(0.5, 0.5)
	icon.Position = UDim2.fromScale(0.5, 0.48)
	icon.Size = UDim2.fromOffset(size - 18, size - 18)
	icon.Parent = b

	local count = Instance.new("TextLabel")
	count.BackgroundTransparency = 1
	count.AnchorPoint = Vector2.new(1, 1)
	count.Position = UDim2.new(1, -3, 1, -1)
	count.Size = UDim2.fromOffset(30, 16)
	count.Font = Enum.Font.GothamBold
	count.TextSize = 14
	count.TextXAlignment = Enum.TextXAlignment.Right
	count.TextColor3 = Color3.fromRGB(250, 250, 250)
	count.TextStrokeTransparency = 0.2
	count.ZIndex = 3
	count.Text = ""
	count.Parent = b

	local durabilityBg = Instance.new("Frame")
	durabilityBg.BorderSizePixel = 0
	durabilityBg.BackgroundColor3 = Color3.new(0, 0, 0)
	durabilityBg.Position = UDim2.new(0, 5, 1, -6)
	durabilityBg.Size = UDim2.new(1, -10, 0, 3)
	durabilityBg.Visible = false
	durabilityBg.ZIndex = 3
	durabilityBg.Parent = b
	local durability = Instance.new("Frame")
	durability.BorderSizePixel = 0
	durability.Size = UDim2.fromScale(1, 1)
	durability.ZIndex = 4
	durability.Parent = durabilityBg

	local w: Widget = {
		container = container,
		index = index,
		button = b,
		icon = icon,
		count = count,
		durabilityBg = durabilityBg,
		durability = durability,
		shown = nil,
	}
	b.MouseButton1Click:Connect(function()
		InventoryClient.click(container, index, if splitMode then "right" else "left", shiftDown())
	end)
	b.MouseButton2Click:Connect(function()
		InventoryClient.click(container, index, "right", shiftDown())
	end)
	b.MouseEnter:Connect(function()
		hovered = w
		stroke.Transparency = 0
	end)
	b.MouseLeave:Connect(function()
		if hovered == w then
			hovered = nil
		end
		stroke.Transparency = 0.5
	end)
	b.Parent = panel
	table.insert(widgets, w)
	return w
end

-- Grid of `cols` x `rows` slots starting at (x, y), indices start..start+n-1 row-major.
local function grid(x: number, y: number, cols: number, rows: number, container: string, start: number)
	for r = 0, rows - 1 do
		for c = 0, cols - 1 do
			slot(x + c * (SLOT + GAP), y + r * (SLOT + GAP), container, start + r * cols + c)
		end
	end
end

local function rowsHeight(rows: number): number
	return rows * SLOT + (rows - 1) * GAP
end

local function arrow(x: number, y: number): Frame
	local bg = Instance.new("Frame")
	bg.BorderSizePixel = 0
	bg.BackgroundColor3 = Color3.fromRGB(60, 64, 76)
	bg.Position = UDim2.fromOffset(x, y)
	bg.Size = UDim2.fromOffset(44, 8)
	bg.Parent = panel
	local fill = Instance.new("Frame")
	fill.BorderSizePixel = 0
	fill.BackgroundColor3 = Color3.fromRGB(235, 235, 240)
	fill.Size = UDim2.fromScale(0, 1)
	fill.Parent = bg
	-- arrow head
	local head = Instance.new("Frame")
	head.BorderSizePixel = 0
	head.BackgroundColor3 = Color3.fromRGB(60, 64, 76)
	head.AnchorPoint = Vector2.new(0.5, 0.5)
	head.Position = UDim2.fromOffset(x + 48, y + 4)
	head.Size = UDim2.fromOffset(12, 12)
	head.Rotation = 45
	head.Parent = panel
	return fill
end

-- Build the panel layout for a window kind.
local function build(kind: string)
	for _, c in panel:GetChildren() do
		if not c:IsA("UICorner") and not c:IsA("UIStroke") then
			c:Destroy()
		end
	end
	table.clear(widgets)
	hovered = nil
	furnaceArrow, furnaceFlame = nil, nil
	layoutKind = kind

	local y = PAD
	label(panel, TITLES[kind] or kind, UDim2.fromOffset(PAD, y), UDim2.fromOffset(300, 20))
	-- shows while Shift is held, so it's visible whether shift-clicks will quick-move
	local marker = label(panel, "SHIFT", UDim2.new(1, -PAD - 120, 0, y), UDim2.fromOffset(60, 20), 13)
	marker.TextColor3 = Color3.fromRGB(140, 200, 255)
	marker.Visible = false
	shiftMarker = marker
	y += 26

	if kind == "inventory" or kind == "crafting_table" then
		local cw = if kind == "crafting_table" then 3 else 2
		local gx = PAD + (if cw == 3 then 60 else 110)
		grid(gx, y, cw, cw, "craft", 1)
		local gridW = cw * SLOT + (cw - 1) * GAP
		local midY = y + rowsHeight(cw) / 2
		local fill = arrow(gx + gridW + 20, midY - 4)
		fill.Size = UDim2.fromScale(1, 1)
		slot(gx + gridW + 90, midY - (SLOT + 8) / 2, "result", 1, true)
		y += rowsHeight(cw)
	elseif kind == "furnace" then
		local x = PAD + 120
		slot(x, y, "block", 1) -- input
		local flameBg = Instance.new("Frame")
		flameBg.BorderSizePixel = 0
		flameBg.BackgroundColor3 = Color3.fromRGB(60, 64, 76)
		flameBg.Position = UDim2.fromOffset(x + SLOT / 2 - 7, y + SLOT + 6)
		flameBg.Size = UDim2.fromOffset(14, 20)
		flameBg.Parent = panel
		local flame = Instance.new("Frame")
		flame.BorderSizePixel = 0
		flame.BackgroundColor3 = Color3.fromRGB(255, 150, 40)
		flame.AnchorPoint = Vector2.new(0, 1)
		flame.Position = UDim2.fromScale(0, 1)
		flame.Size = UDim2.fromScale(1, 0)
		flame.Parent = flameBg
		furnaceFlame = flame
		slot(x, y + SLOT + 32, "block", 2) -- fuel
		local midY = y + (SLOT * 2 + 32) / 2
		furnaceArrow = arrow(x + SLOT + 30, midY - 4)
		slot(x + SLOT + 100, midY - (SLOT + 8) / 2, "block", 3, true) -- output
		y += SLOT * 2 + 32
	elseif kind == "chest" then
		grid(PAD, y, COLS, 3, "block", 1)
		y += rowsHeight(3)
	end
	y += 14
	label(panel, "Inventory", UDim2.fromOffset(PAD, y), UDim2.fromOffset(300, 18), 13)
	y += 20
	grid(PAD, y, COLS, 3, "inv", Config.HOTBAR_SLOTS + 1) -- main 10..36
	y += rowsHeight(3) + 10
	grid(PAD, y, COLS, 1, "inv", 1) -- hotbar row 1..9
	y += SLOT + PAD

	panel.Size = UDim2.fromOffset(PANEL_W, y)

	if UserInputService.TouchEnabled then
		local t = Instance.new("TextButton")
		t.Size = UDim2.fromOffset(44, 26)
		t.Position = UDim2.new(1, -PAD - 44, 0, PAD - 4)
		t.Font = Enum.Font.GothamBold
		t.TextSize = 14
		t.BackgroundColor3 = Color3.fromRGB(40, 44, 54)
		t.TextColor3 = Color3.fromRGB(235, 235, 240)
		t.Text = "½"
		t.Parent = panel
		t.Activated:Connect(function()
			splitMode = not splitMode
			t.BackgroundColor3 = if splitMode then Color3.fromRGB(90, 120, 200) else Color3.fromRGB(40, 44, 54)
		end)
	end
end

local function refresh()
	if not gui.Enabled then
		return
	end
	local kind = InventoryClient.window.kind
	if kind ~= layoutKind then
		build(kind)
	end
	for _, w in widgets do
		local s = stackFor(w)
		local key = s and s.item
		if w.shown ~= key then
			w.shown = key
			if key then
				ItemIcon.draw(w.icon, key)
			else
				ItemIcon.clear(w.icon)
			end
		end
		w.count.Text = if s and s.count > 1 then tostring(s.count) else ""
		local def = key and ItemRegistry.get(key)
		if s and def and def.tool and s.durability and s.durability < def.tool.durability then
			local f = math.clamp(s.durability / def.tool.durability, 0, 1)
			w.durabilityBg.Visible = true
			w.durability.Size = UDim2.fromScale(f, 1)
			w.durability.BackgroundColor3 = Color3.fromHSV(f * 0.33, 0.9, 0.9)
		else
			w.durabilityBg.Visible = false
		end
	end
	local win = InventoryClient.window
	if furnaceArrow and furnaceFlame then
		furnaceArrow.Size = UDim2.fromScale(math.clamp((win.progress or 0) / Recipes.SMELT_SECONDS, 0, 1), 1)
		local burnMax = win.burnMax or 0
		furnaceFlame.Size = UDim2.fromScale(1, if burnMax > 0 then math.clamp((win.burn or 0) / burnMax, 0, 1) else 0)
	end
	-- cursor stack
	local c = InventoryClient.cursor
	cursorFrame.Visible = c ~= nil
	if c then
		ItemIcon.draw(cursorIcon, c.item)
		cursorCount.Text = if c.count > 1 then tostring(c.count) else ""
	end
end

local function setOtherHud(visible: boolean)
	local pg = Players.LocalPlayer:FindFirstChildOfClass("PlayerGui")
	if not pg then
		return
	end
	for _, name in { "RocraftHotbar", "Crosshair", "TouchActions" } do
		local g = pg:FindFirstChild(name)
		if g and g:IsA("ScreenGui") then
			g.Enabled = visible
		end
	end
end

local function show()
	if gui.Enabled then
		return
	end
	gui.Enabled = true
	InventoryClient.uiOpen = true
	CameraController.mouseUnlocked = true
	setOtherHud(false)
	layoutKind = nil
	refresh()
end

local function hide(tellServer: boolean)
	if not gui.Enabled then
		return
	end
	gui.Enabled = false
	InventoryClient.uiOpen = false
	CameraController.mouseUnlocked = false
	setOtherHud(true)
	tooltip.Visible = false
	if tellServer then
		InventoryClient.close()
	end
end

function InventoryUI.isOpen(): boolean
	return gui ~= nil and gui.Enabled
end

function InventoryUI.toggle()
	if gui.Enabled then
		hide(true)
	else
		InventoryClient.openInventory()
		show()
	end
end

function InventoryUI.init()
	gui = Instance.new("ScreenGui")
	gui.Name = "RocraftInventory"
	gui.ResetOnSpawn = false
	gui.DisplayOrder = 20
	gui.Enabled = false

	local dim = Instance.new("Frame")
	dim.BackgroundColor3 = Color3.new(0, 0, 0)
	dim.BackgroundTransparency = 0.55
	dim.BorderSizePixel = 0
	dim.Size = UDim2.fromScale(1, 1)
	dim.Parent = gui

	panel = Instance.new("Frame")
	panel.AnchorPoint = Vector2.new(0.5, 0.5)
	panel.Position = UDim2.fromScale(0.5, 0.5)
	panel.BackgroundColor3 = Color3.fromRGB(26, 28, 35)
	panel.BorderSizePixel = 0
	panel.Active = true -- clicks on the panel background don't count as "outside" (no drop)
	panel.Size = UDim2.fromOffset(PANEL_W, 300)
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 8)
	corner.Parent = panel
	local stroke = Instance.new("UIStroke")
	stroke.Color = Color3.fromRGB(120, 126, 142)
	stroke.Transparency = 0.4
	stroke.Parent = panel
	panel.Parent = gui

	cursorFrame = Instance.new("Frame")
	cursorFrame.BackgroundTransparency = 1
	cursorFrame.Size = UDim2.fromOffset(SLOT, SLOT)
	cursorFrame.AnchorPoint = Vector2.new(0.5, 0.5)
	cursorFrame.ZIndex = 50
	cursorFrame.Visible = false
	cursorFrame.Parent = gui
	cursorIcon = Instance.new("Frame")
	cursorIcon.BackgroundTransparency = 1
	cursorIcon.AnchorPoint = Vector2.new(0.5, 0.5)
	cursorIcon.Position = UDim2.fromScale(0.5, 0.5)
	cursorIcon.Size = UDim2.fromOffset(SLOT - 18, SLOT - 18)
	cursorIcon.ZIndex = 50
	cursorIcon.Parent = cursorFrame
	cursorCount = Instance.new("TextLabel")
	cursorCount.BackgroundTransparency = 1
	cursorCount.AnchorPoint = Vector2.new(1, 1)
	cursorCount.Position = UDim2.new(1, -3, 1, -1)
	cursorCount.Size = UDim2.fromOffset(30, 16)
	cursorCount.Font = Enum.Font.GothamBold
	cursorCount.TextSize = 14
	cursorCount.TextXAlignment = Enum.TextXAlignment.Right
	cursorCount.TextColor3 = Color3.fromRGB(250, 250, 250)
	cursorCount.TextStrokeTransparency = 0.2
	cursorCount.ZIndex = 51
	cursorCount.Parent = cursorFrame

	tooltip = Instance.new("TextLabel")
	tooltip.BackgroundColor3 = Color3.fromRGB(12, 10, 20)
	tooltip.BackgroundTransparency = 0.1
	tooltip.BorderSizePixel = 0
	tooltip.Font = Enum.Font.GothamBold
	tooltip.TextSize = 14
	tooltip.TextColor3 = Color3.fromRGB(240, 240, 250)
	tooltip.AutomaticSize = Enum.AutomaticSize.XY
	tooltip.ZIndex = 60
	tooltip.Visible = false
	local tp = Instance.new("UIPadding")
	tp.PaddingLeft = UDim.new(0, 6)
	tp.PaddingRight = UDim.new(0, 6)
	tp.PaddingTop = UDim.new(0, 3)
	tp.PaddingBottom = UDim.new(0, 3)
	tp.Parent = tooltip
	tooltip.Parent = gui

	gui.Parent = Players.LocalPlayer:WaitForChild("PlayerGui")

	-- Touch devices have no E key: a small bag button next to the hotbar.
	if UserInputService.TouchEnabled then
		local bgui = Instance.new("ScreenGui")
		bgui.Name = "InventoryButton"
		bgui.ResetOnSpawn = false
		local b = Instance.new("TextButton")
		b.AnchorPoint = Vector2.new(0, 1)
		b.Position = UDim2.new(0.5, 9 * 54 / 2 + 10, 1, -12)
		b.Size = UDim2.fromOffset(50, 50)
		b.BackgroundColor3 = Color3.fromRGB(18, 20, 26)
		b.BackgroundTransparency = 0.3
		b.TextColor3 = Color3.fromRGB(235, 235, 240)
		b.Font = Enum.Font.GothamBold
		b.TextSize = 14
		b.Text = "Bag"
		b.Parent = bgui
		b.Activated:Connect(InventoryUI.toggle)
		bgui.Parent = gui.Parent
	end

	-- Server state drives the UI: a container window opening shows it; the server closing a
	-- container (walked away, block broken) hides it.
	local lastKind = "inventory"
	InventoryClient.Changed:Connect(function()
		local kind = InventoryClient.window.kind
		if kind ~= "inventory" and not gui.Enabled then
			show()
		elseif kind == "inventory" and lastKind ~= "inventory" and gui.Enabled then
			hide(false)
		end
		lastKind = kind
		refresh()
	end)

	local keyInventory = (Enum.KeyCode :: any)[Config.KEY_INVENTORY]
	local keyDrop = (Enum.KeyCode :: any)[Config.KEY_DROP]
	local function setModifier(k: Enum.KeyCode, down: boolean)
		if k == Enum.KeyCode.LeftShift or k == Enum.KeyCode.RightShift then
			shiftHeld = down
		elseif k == Enum.KeyCode.LeftControl or k == Enum.KeyCode.RightControl then
			ctrlHeld = down
		end
	end
	UserInputService.InputEnded:Connect(function(input)
		setModifier(input.KeyCode, false)
	end)
	UserInputService.InputBegan:Connect(function(input, processed)
		setModifier(input.KeyCode, true) -- regardless of `processed`
		if input.KeyCode == keyDrop and gui.Enabled and hovered then
			-- Q over a slot drops one item from it; Ctrl/Cmd+Q drops the whole stack
			local h = hovered :: Widget
			InventoryClient.dropSlot(h.container, h.index, ctrlDown())
		elseif input.KeyCode == keyInventory and (not processed or gui.Enabled) then
			InventoryUI.toggle()
		elseif input.KeyCode == Enum.KeyCode.Escape and gui.Enabled then
			hide(true)
		elseif gui.Enabled and not processed then
			-- click outside the panel while carrying a stack: drop it (right click: one item)
			local t = input.UserInputType
			if InventoryClient.cursor and (t == Enum.UserInputType.MouseButton1 or t == Enum.UserInputType.MouseButton2) then
				InventoryClient.dropCursor(t == Enum.UserInputType.MouseButton1)
			end
		end
	end)

	RunService.RenderStepped:Connect(function()
		if not gui.Enabled then
			return
		end
		local inset = GuiService:GetGuiInset()
		local m = UserInputService:GetMouseLocation() - inset
		cursorFrame.Position = UDim2.fromOffset(m.X, m.Y)
		if shiftMarker then
			shiftMarker.Visible = shiftDown()
		end
		local h = hovered
		local s = h and stackFor(h)
		local def = s and ItemRegistry.get(s.item)
		if s and def and not InventoryClient.cursor then
			local text = def.name
			if def.tool and s.durability then
				text ..= `\nDurability {s.durability} / {def.tool.durability}`
			end
			tooltip.Text = text
			tooltip.Position = UDim2.fromOffset(m.X + 16, m.Y + 12)
			tooltip.Visible = true
		else
			tooltip.Visible = false
		end
	end)
end

return InventoryUI
