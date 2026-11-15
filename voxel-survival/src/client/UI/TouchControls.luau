--!strict
-- Touch controls in the style of mobile Minecraft (our own drawing), used instead of Roblox's
-- touch thumbstick and jump button:
--   movement   arrow buttons bottom left (8 directions; slide your finger between them) with a
--              sneak button in the middle, or a joystick (Options > Movement Controls).
--              Double-tap forward (or the joystick) to sprint.
--   jump       the big button bottom right; hold it to keep jumping / swim up
--   the world  drag to look around; tap to place, open, use or attack where you tapped; hold
--              to break the block you're pressing (food, bows and shields: hold to use)
--   hotbar     tap a slot to select it, hold it to drop the item
--   pause      the button at the top; inventory: the bag next to the hotbar
-- Movement goes to MovementController.touch; the world taps to BlockInteraction.

local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local GuiService = game:GetService("GuiService")

local MenuKit = require(script.Parent.MenuKit)
local MovementController = require(script.Parent.Parent.Player.MovementController)
local CameraController = require(script.Parent.Parent.Player.CameraController)
local InventoryClient = require(script.Parent.Parent.Player.InventoryClient)
local Settings = require(script.Parent.Parent.Player.Settings)

local TouchControls = {}
TouchControls.active = false

local HOLD_TO_BREAK = 0.3 -- seconds a still finger must stay down before it breaks / uses
local DRAG = 12 -- pixels a finger may move and still count as a tap
local DOUBLE_TAP = 0.35 -- seconds between two forward presses to sprint (Java: 7 ticks)

local gui: ScreenGui
local dpad: Frame
local stick: Frame
local knob: Frame
local layout = "dpad"
local state = { forward = 0, strafe = 0, jump = false }

-- which finger does what
local moveTouch: InputObject? = nil
local jumpTouch: InputObject? = nil
type WorldTouch = { start: Vector2, last: Vector2, t0: number, dragging: boolean, holding: boolean }
local worldTouches: { [InputObject]: WorldTouch } = {}
local lastForwardTap = -math.huge
local wasForward = false

local BlockInteraction: any = nil -- set in init (it requires us lazily)

local function inside(g: GuiObject, p: Vector2): boolean
	local a, s = g.AbsolutePosition, g.AbsoluteSize
	return g.Visible and p.X >= a.X and p.X <= a.X + s.X and p.Y >= a.Y and p.Y <= a.Y + s.Y
end

-- Movement from a finger at `p` on the arrow pad / joystick. `fresh`: the finger just went down
-- (only a new press counts towards a double tap, not sliding back onto forward).
local function moveFrom(p: Vector2, fresh: boolean)
	local area = if layout == "joystick" then stick else dpad
	local c = area.AbsolutePosition + area.AbsoluteSize / 2
	local d = p - c
	local r = area.AbsoluteSize.X / 2
	local f, s = 0, 0
	if layout == "joystick" then
		local v = d / r
		if v.Magnitude > 1 then
			v = v.Unit
		end
		knob.Position = UDim2.new(0.5, v.X * r * 0.6, 0.5, v.Y * r * 0.6)
		if v.Magnitude > 0.2 then
			f, s = -v.Y, v.X
		end
	else
		-- 8 sectors around the centre; the middle third is the sneak button (not movement)
		if d.Magnitude > r / 3 then
			local a = math.atan2(-d.Y, d.X) -- 0 = right, pi/2 = forward
			local sector = math.floor((a + math.pi / 8) / (math.pi / 4)) % 8
			local dirs = { [0] = { 0, 1 }, { 1, 1 }, { 1, 0 }, { 1, -1 }, { 0, -1 }, { -1, -1 }, { -1, 0 }, { -1, 1 } }
			local v = dirs[sector]
			f, s = v[1], v[2]
		end
	end
	-- double-tap forward sprints (like W)
	local forwardNow = f > 0.5
	if forwardNow and not wasForward and fresh then
		local now = os.clock()
		if now - lastForwardTap <= DOUBLE_TAP then
			MovementController.touchSprint()
			lastForwardTap = -math.huge
		else
			lastForwardTap = now
		end
	end
	wasForward = forwardNow
	state.forward, state.strafe = f, s
end

local function stopMove()
	moveTouch = nil
	state.forward, state.strafe = 0, 0
	wasForward = false
	if knob then
		knob.Position = UDim2.fromScale(0.5, 0.5)
	end
end

local function blocked(): boolean
	return InventoryClient.uiOpen or GuiService.MenuIsOpen
end

local function arrow(parent: Instance, text: string, col: number, row: number): TextLabel
	local cell = MenuKit.make("TextLabel", {
		Size = UDim2.fromScale(1 / 3, 1 / 3),
		Position = UDim2.fromScale(col / 3, row / 3),
		BackgroundColor3 = MenuKit.COLORS.panel,
		BackgroundTransparency = 0.45,
		TextColor3 = MenuKit.COLORS.text,
		TextTransparency = 0.1,
		Font = Enum.Font.GothamBlack,
		TextScaled = true,
		Text = text,
	}, parent)
	MenuKit.corner(cell, 8)
	MenuKit.make("UIPadding", {
		PaddingTop = UDim.new(0.22, 0), PaddingBottom = UDim.new(0.22, 0),
		PaddingLeft = UDim.new(0.22, 0), PaddingRight = UDim.new(0.22, 0),
	}, cell)
	return cell
end

local sneakCell: TextLabel
local jumpButton: TextLabel

-- Size the pad to the room left of the hotbar (phones are narrow).
local function relayout()
	local cam = workspace.CurrentCamera
	local w = if cam then cam.ViewportSize.X else 800
	local hotbar = 9 * 50 + 8 * 4
	local room = (w - hotbar) / 2 - 24
	local size = math.clamp(room, 120, 180)
	local lifted = room < 120 -- no room beside the hotbar: sit above it
	for _, area in { dpad, stick } do
		area.Size = UDim2.fromOffset(size, size)
		area.Position = UDim2.new(0, 16, 1, if lifted then -84 else -16)
	end
	jumpButton.Size = UDim2.fromOffset(math.floor(size * 0.5), math.floor(size * 0.5))
	jumpButton.Position = UDim2.new(1, -20, 1, if lifted then -84 else -24)
end

local function applyLayout()
	dpad.Visible = layout ~= "joystick"
	stick.Visible = layout == "joystick"
	stopMove()
end

function TouchControls.init()
	if not UserInputService.TouchEnabled then
		return
	end
	TouchControls.active = true
	BlockInteraction = require(script.Parent.Parent.Interaction.BlockInteraction) :: any
	-- Roblox's own thumbstick and jump button would sit on top of ours
	pcall(function()
		(GuiService :: any).TouchControlsEnabled = false
	end)
	CameraController.touchOwned = true
	MovementController.touch = state

	gui = MenuKit.screen("TouchControls", 3)
	dpad = MenuKit.make("Frame", { AnchorPoint = Vector2.new(0, 1), BackgroundTransparency = 1 }, gui)
	arrow(dpad, "▲", 1, 0)
	arrow(dpad, "◀", 0, 1)
	arrow(dpad, "▶", 2, 1)
	arrow(dpad, "▼", 1, 2)
	sneakCell = arrow(dpad, "◆", 1, 1) -- sneak (toggle), like the middle button on mobile
	stick = MenuKit.make("Frame", {
		AnchorPoint = Vector2.new(0, 1),
		BackgroundColor3 = MenuKit.COLORS.panel,
		BackgroundTransparency = 0.55,
	}, gui)
	MenuKit.make("UICorner", { CornerRadius = UDim.new(0.5, 0) }, stick)
	knob = MenuKit.make("Frame", {
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromScale(0.42, 0.42),
		BackgroundColor3 = MenuKit.COLORS.text,
		BackgroundTransparency = 0.4,
	}, stick)
	MenuKit.make("UICorner", { CornerRadius = UDim.new(0.5, 0) }, knob)
	jumpButton = MenuKit.make("TextLabel", {
		AnchorPoint = Vector2.new(1, 1),
		BackgroundColor3 = MenuKit.COLORS.panel,
		BackgroundTransparency = 0.45,
		TextColor3 = MenuKit.COLORS.text,
		Font = Enum.Font.GothamBlack,
		TextScaled = true,
		Text = "⬆",
	}, gui)
	MenuKit.make("UICorner", { CornerRadius = UDim.new(0.5, 0) }, jumpButton)
	MenuKit.make("UIPadding", {
		PaddingTop = UDim.new(0.2, 0), PaddingBottom = UDim.new(0.2, 0),
		PaddingLeft = UDim.new(0.2, 0), PaddingRight = UDim.new(0.2, 0),
	}, jumpButton)
	relayout()
	local cam = workspace.CurrentCamera
	if cam then
		cam:GetPropertyChangedSignal("ViewportSize"):Connect(relayout)
	end
	Settings.onChange(function(key: string, value: any)
		if key == "touchLayout" then
			layout = value
			applyLayout()
		end
	end)
	applyLayout()
	gui.Parent = MenuKit.playerGui()

	UserInputService.TouchStarted:Connect(function(input: InputObject, processed: boolean)
		local p = Vector2.new(input.Position.X, input.Position.Y)
		if blocked() then
			return
		end
		if not moveTouch and (inside(dpad, p) or inside(stick, p)) then
			if layout ~= "joystick" and inside(sneakCell, p) then
				MovementController.toggleSneak()
				sneakCell.BackgroundTransparency = if MovementController.sneaking then 0.45 else 0.15
				return
			end
			moveTouch = input
			moveFrom(p, true)
			return
		end
		if not jumpTouch and inside(jumpButton, p) then
			jumpTouch = input
			state.jump = true
			return
		end
		if processed then
			return -- a button (hotbar, pause, bag) took it
		end
		worldTouches[input] = { start = p, last = p, t0 = os.clock(), dragging = false, holding = false }
	end)
	UserInputService.TouchMoved:Connect(function(input: InputObject)
		local p = Vector2.new(input.Position.X, input.Position.Y)
		if input == moveTouch then
			moveFrom(p, false)
			return
		end
		local w = worldTouches[input]
		if w then
			local d = p - w.last
			w.last = p
			if not w.dragging and (p - w.start).Magnitude > DRAG and not w.holding then
				w.dragging = true
			end
			if w.holding then
				BlockInteraction.aimAt(p) -- breaking: the aim follows the finger
			elseif w.dragging then
				CameraController.turn(d.X, d.Y)
			end
		end
	end)
	UserInputService.TouchEnded:Connect(function(input: InputObject)
		if input == moveTouch then
			stopMove()
			return
		end
		if input == jumpTouch then
			jumpTouch = nil
			state.jump = false
			return
		end
		local w = worldTouches[input]
		if w then
			worldTouches[input] = nil
			if w.holding then
				BlockInteraction.touchRelease()
			elseif not w.dragging and not blocked() then
				BlockInteraction.touchTap(w.last)
			end
		end
	end)

	RunService.RenderStepped:Connect(function()
		gui.Enabled = not blocked() -- (spectators keep them: they fly with them)
		if blocked() then
			if moveTouch then
				stopMove()
			end
			state.jump = false
			jumpTouch = nil
			for _, w in worldTouches do
				if w.holding then
					BlockInteraction.touchRelease()
				end
			end
			table.clear(worldTouches)
			return
		end
		sneakCell.BackgroundTransparency = if MovementController.sneaking then 0.15 else 0.45
		-- a finger that stays still becomes a hold: break (or use the held item)
		local now = os.clock()
		for _, w in worldTouches do
			if not w.dragging and not w.holding and now - w.t0 >= HOLD_TO_BREAK then
				w.holding = true
				BlockInteraction.touchHold(w.last)
			end
		end
	end)
end

return TouchControls
