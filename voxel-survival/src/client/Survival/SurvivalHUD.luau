--!strict
-- Survival HUD (original look, drawn from Frames):
--   * health: 10 red pips above the left half of the hotbar (each pip = 2 HP, half pips shown)
--   * hunger: 10 amber pips above the right half (each = 2 food points)
--   * air: 10 small blue rounds above the hunger row, only while it's not full
--   * a red flash when hurt, an eating progress bar under the crosshair
--   * death screen with the cause and a Respawn button (mouse unlocked while it shows)

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")

local SurvivalClient = require(script.Parent.SurvivalClient)
local CameraController = require(script.Parent.Parent.Player.CameraController)

local PIP = 16
local PIP_GAP = 2
local HOTBAR_WIDTH = 9 * 50 + 8 * 4 -- matches UI/Hotbar
local ROW_Y = -12 - 50 - 8 -- just above the hotbar

local SurvivalHUD = {}

type Pip = { bg: Frame, fill: Frame }

local gui: ScreenGui
local healthPips: { Pip } = {}
local hungerPips: { Pip } = {}
local airPips: { Pip } = {}
local airRow: Frame
local flash: Frame
local eatBar: Frame
local eatFill: Frame
local deathScreen: Frame
local deathCause: TextLabel

local function pipRow(parent: Instance, count: number, color: Color3, round: boolean, alignRight: boolean): (Frame, { Pip })
	local row = Instance.new("Frame")
	row.BackgroundTransparency = 1
	row.Size = UDim2.fromOffset(count * (PIP + PIP_GAP), PIP)
	row.Parent = parent
	local pips = {}
	for i = 1, count do
		local bg = Instance.new("Frame")
		bg.BorderSizePixel = 0
		bg.BackgroundColor3 = Color3.fromRGB(20, 18, 22)
		bg.BackgroundTransparency = 0.25
		bg.Size = UDim2.fromOffset(PIP, PIP)
		-- health fills left->right from the left; hunger/air fill from the right like their row
		local slot = if alignRight then count - i else i - 1
		bg.Position = UDim2.fromOffset(slot * (PIP + PIP_GAP), 0)
		local corner = Instance.new("UICorner")
		corner.CornerRadius = if round then UDim.new(0.5, 0) else UDim.new(0, 3)
		corner.Parent = bg
		local stroke = Instance.new("UIStroke")
		stroke.Color = Color3.new(0, 0, 0)
		stroke.Transparency = 0.3
		stroke.Parent = bg
		local fill = Instance.new("Frame")
		fill.BorderSizePixel = 0
		fill.BackgroundColor3 = color
		fill.Size = UDim2.fromScale(1, 1)
		fill.Parent = bg
		local fc = Instance.new("UICorner")
		fc.CornerRadius = corner.CornerRadius
		fc.Parent = fill
		bg.Parent = row
		table.insert(pips, { bg = bg, fill = fill })
	end
	return row, pips
end

-- value in half-pip units: each pip shows 2 points
local function setPips(pips: { Pip }, value: number, alignRight: boolean)
	for i, p in pips do
		local v = math.clamp(value - (i - 1) * 2, 0, 2)
		p.fill.Visible = v > 0
		p.fill.Size = UDim2.fromScale(v / 2, 1)
		p.fill.AnchorPoint = if alignRight then Vector2.new(1, 0) else Vector2.zero
		p.fill.Position = if alignRight then UDim2.fromScale(1, 0) else UDim2.fromScale(0, 0)
	end
end

local function humanoid(): Humanoid?
	local c = Players.LocalPlayer.Character
	return c and c:FindFirstChildOfClass("Humanoid")
end

local function showDeath(on: boolean)
	deathScreen.Visible = on
	CameraController.mouseUnlocked = on
	if on then
		deathCause.Text = `{Players.LocalPlayer.DisplayName} {SurvivalClient.deathCause}`
	end
end

function SurvivalHUD.setEatProgress(p: number?)
	eatBar.Visible = p ~= nil
	if p then
		eatFill.Size = UDim2.fromScale(math.clamp(p, 0, 1), 1)
	end
end

function SurvivalHUD.init()
	gui = Instance.new("ScreenGui")
	gui.Name = "SurvivalHUD"
	gui.ResetOnSpawn = false
	gui.DisplayOrder = 4

	local hud = Instance.new("Frame")
	hud.BackgroundTransparency = 1
	hud.AnchorPoint = Vector2.new(0.5, 1)
	hud.Position = UDim2.new(0.5, 0, 1, ROW_Y)
	hud.Size = UDim2.fromOffset(HOTBAR_WIDTH, PIP * 2 + 6)
	hud.Parent = gui

	local hRow, hp = pipRow(hud, 10, Color3.fromRGB(222, 44, 54), false, false)
	hRow.AnchorPoint = Vector2.new(0, 1)
	hRow.Position = UDim2.fromScale(0, 1)
	healthPips = hp
	local fRow, fp = pipRow(hud, 10, Color3.fromRGB(218, 142, 40), false, true)
	fRow.AnchorPoint = Vector2.new(1, 1)
	fRow.Position = UDim2.fromScale(1, 1)
	hungerPips = fp
	local aRow, ap = pipRow(hud, 10, Color3.fromRGB(120, 190, 255), true, true)
	aRow.AnchorPoint = Vector2.new(1, 1)
	aRow.Position = UDim2.new(1, 0, 1, -(PIP + 6))
	airRow = aRow
	airPips = ap

	flash = Instance.new("Frame")
	flash.BorderSizePixel = 0
	flash.BackgroundColor3 = Color3.fromRGB(200, 0, 0)
	flash.BackgroundTransparency = 1
	flash.Size = UDim2.fromScale(1, 1)
	flash.ZIndex = 0
	flash.Parent = gui

	eatBar = Instance.new("Frame")
	eatBar.BorderSizePixel = 0
	eatBar.BackgroundColor3 = Color3.fromRGB(20, 20, 24)
	eatBar.BackgroundTransparency = 0.3
	eatBar.AnchorPoint = Vector2.new(0.5, 0)
	eatBar.Position = UDim2.new(0.5, 0, 0.5, 24)
	eatBar.Size = UDim2.fromOffset(60, 5)
	eatBar.Visible = false
	eatBar.Parent = gui
	eatFill = Instance.new("Frame")
	eatFill.BorderSizePixel = 0
	eatFill.BackgroundColor3 = Color3.fromRGB(218, 142, 40)
	eatFill.Size = UDim2.fromScale(0, 1)
	eatFill.Parent = eatBar

	-- Death screen
	local deathGui = Instance.new("ScreenGui")
	deathGui.Name = "DeathScreen"
	deathGui.ResetOnSpawn = false
	deathGui.DisplayOrder = 50
	deathGui.IgnoreGuiInset = true
	deathScreen = Instance.new("Frame")
	deathScreen.BorderSizePixel = 0
	deathScreen.BackgroundColor3 = Color3.fromRGB(90, 0, 0)
	deathScreen.BackgroundTransparency = 0.45
	deathScreen.Size = UDim2.fromScale(1, 1)
	deathScreen.Visible = false
	deathScreen.Active = true
	deathScreen.Parent = deathGui
	local title = Instance.new("TextLabel")
	title.BackgroundTransparency = 1
	title.AnchorPoint = Vector2.new(0.5, 0.5)
	title.Position = UDim2.fromScale(0.5, 0.35)
	title.Size = UDim2.fromOffset(600, 60)
	title.Font = Enum.Font.GothamBlack
	title.TextSize = 46
	title.TextColor3 = Color3.fromRGB(255, 235, 235)
	title.TextStrokeTransparency = 0.5
	title.Text = "You died"
	title.Parent = deathScreen
	deathCause = Instance.new("TextLabel")
	deathCause.BackgroundTransparency = 1
	deathCause.AnchorPoint = Vector2.new(0.5, 0.5)
	deathCause.Position = UDim2.fromScale(0.5, 0.44)
	deathCause.Size = UDim2.fromOffset(600, 30)
	deathCause.Font = Enum.Font.GothamBold
	deathCause.TextSize = 20
	deathCause.TextColor3 = Color3.fromRGB(240, 210, 210)
	deathCause.Parent = deathScreen
	local respawn = Instance.new("TextButton")
	respawn.AnchorPoint = Vector2.new(0.5, 0.5)
	respawn.Position = UDim2.fromScale(0.5, 0.56)
	respawn.Size = UDim2.fromOffset(240, 48)
	respawn.BackgroundColor3 = Color3.fromRGB(40, 40, 48)
	respawn.TextColor3 = Color3.fromRGB(240, 240, 245)
	respawn.Font = Enum.Font.GothamBold
	respawn.TextSize = 20
	respawn.Text = "Respawn"
	local rc = Instance.new("UICorner")
	rc.CornerRadius = UDim.new(0, 6)
	rc.Parent = respawn
	respawn.Parent = deathScreen
	respawn.Activated:Connect(function()
		SurvivalClient.respawn()
	end)

	gui.Parent = Players.LocalPlayer:WaitForChild("PlayerGui")
	deathGui.Parent = gui.Parent

	SurvivalClient.Changed:Connect(function(event: string?)
		if event == "hurt" then
			flash.BackgroundTransparency = 0.6
			TweenService:Create(flash, TweenInfo.new(0.4), { BackgroundTransparency = 1 }):Play()
		elseif event == "died" then
			showDeath(true)
		elseif event == "spawned" then
			showDeath(false)
		end
	end)

	RunService.RenderStepped:Connect(function()
		local h = humanoid()
		setPips(healthPips, if h then math.ceil(h.Health) else 0, false)
		setPips(hungerPips, SurvivalClient.food, true)
		local air = SurvivalClient.air
		local maxAir = SurvivalClient.maxAir
		airRow.Visible = air < maxAir
		setPips(airPips, math.ceil(air / maxAir * 20), true)
	end)
end

return SurvivalHUD
