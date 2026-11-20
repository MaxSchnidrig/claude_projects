--!strict
-- Survival HUD (original look, drawn from Frames):
--   * health: 10 red pips above the left half of the hotbar (each pip = 2 HP, half pips shown)
--   * hunger: 10 amber pips above the right half (each = 2 food points)
--   * air: 10 small blue rounds above the hunger row, only while it's not full
--   * a red flash when hurt, an eating progress bar under the crosshair
--   * death screen with the cause and a Respawn button (mouse unlocked while it shows)
--   * status effects (Phase 9c): green health while poisoned, a wave while regenerating, gold
--     extra pips for absorption (a row above health, armour moves up), a greenish hunger row
--     with the hunger effect, and a list of active effects with their time at the top right
--   * experience (Phase 10a): a thin bar right above the hotbar that fills toward the next
--     level, the level number in green over its middle (hidden at 0), hearts and hunger above
--     it like Java; the death screen shows the score

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Effects = require(ReplicatedStorage:WaitForChild("Shared").Gameplay.Effects)
local SurvivalClient = require(script.Parent.SurvivalClient)
local ExperienceClient = require(script.Parent.ExperienceClient)
local CameraController = require(script.Parent.Parent.Player.CameraController)
local InventoryClient = require(script.Parent.Parent.Player.InventoryClient)

local PIP = 16
local PIP_GAP = 2
local HOTBAR_WIDTH = 9 * 50 + 8 * 4 -- matches UI/Hotbar
local XP_Y = -12 - 50 - 5 -- the experience bar's bottom, just above the hotbar
local XP_H = 5
local ROW_Y = XP_Y - XP_H - 4 -- hearts and hunger above the experience bar

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
local deathTitle: TextLabel
local deathScore: TextLabel
local xpBar: Frame
local xpFill: Frame
local xpLevel: TextLabel
local respawnButton: TextButton
local titleButton: TextButton
local hud: Frame

local function isHardcore(): boolean
	return game:GetService("ReplicatedStorage"):GetAttribute("Hardcore") == true
end

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
		deathScore.Text = `Score: {SurvivalClient.deathScore}`
		-- Hardcore (Java): "Game over!", and you can only watch from now on
		local hc = isHardcore()
		deathTitle.Text = if hc then "Game Over!" else "You died"
		respawnButton.Text = if hc then "Spectate World" else "Respawn"
		titleButton.Visible = hc
	end
end

function SurvivalHUD.setEatProgress(p: number?)
	eatBar.Visible = p ~= nil
	if p then
		eatFill.Size = UDim2.fromScale(math.clamp(p, 0, 1), 1)
	end
end

local armorRow: Frame
local armorPips: { Pip }
local absorbRow: Frame
local absorbPips: { Pip }
local effectList: Frame

local HEART = Color3.fromRGB(222, 44, 54)
local HEART_POISON = Color3.fromRGB(140, 170, 40)
local FOOD = Color3.fromRGB(218, 142, 40)
local FOOD_HUNGER = Color3.fromRGB(130, 150, 60)
local ABSORB = Color3.fromRGB(240, 196, 60)

-- One line of the effect list: a badge in the effect's colour, its name and level, and the time.
local function effectLine(parent: Instance, id: string, amp: number, secs: number, order: number)
	local def = Effects.DEFS[id]
	local c = if def then def.color else { 200, 200, 200 }
	local line = Instance.new("Frame")
	line.Name = id
	line.BorderSizePixel = 0
	line.BackgroundColor3 = Color3.fromRGB(20, 18, 22)
	line.BackgroundTransparency = 0.35
	line.Size = UDim2.fromOffset(190, 26)
	line.LayoutOrder = order
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 4)
	corner.Parent = line
	local badge = Instance.new("Frame")
	badge.BorderSizePixel = 0
	badge.BackgroundColor3 = Color3.fromRGB(c[1], c[2], c[3])
	badge.Position = UDim2.fromOffset(5, 5)
	badge.Size = UDim2.fromOffset(16, 16)
	local bc = Instance.new("UICorner")
	bc.CornerRadius = UDim.new(0.5, 0)
	bc.Parent = badge
	local stroke = Instance.new("UIStroke")
	stroke.Color = if def and def.harmful then Color3.fromRGB(90, 20, 20) else Color3.fromRGB(250, 250, 240)
	stroke.Thickness = 1.5
	stroke.Parent = badge
	badge.Parent = line
	local label = Instance.new("TextLabel")
	label.BackgroundTransparency = 1
	label.Position = UDim2.fromOffset(28, 0)
	label.Size = UDim2.new(1, -78, 1, 0)
	label.Font = Enum.Font.GothamBold
	label.TextSize = 13
	label.TextXAlignment = Enum.TextXAlignment.Left
	label.TextColor3 = Color3.fromRGB(240, 240, 245)
	label.Text = Effects.label(id, amp)
	label.Parent = line
	local time = Instance.new("TextLabel")
	time.BackgroundTransparency = 1
	time.AnchorPoint = Vector2.new(1, 0)
	time.Position = UDim2.new(1, -6, 0, 0)
	time.Size = UDim2.new(0, 46, 1, 0)
	time.Font = Enum.Font.Gotham
	time.TextSize = 13
	time.TextXAlignment = Enum.TextXAlignment.Right
	time.TextColor3 = Color3.fromRGB(200, 200, 210)
	time.Text = Effects.timeText(secs * 20)
	time.Parent = line
	line.Parent = parent
end

local lastFx = ""
local function refreshEffects()
	local key = ""
	for _, e in SurvivalClient.effects do
		key ..= `{e[1]}{e[2]}:{e[3]},`
	end
	if key == lastFx then
		return
	end
	lastFx = key
	for _, c in effectList:GetChildren() do
		if c:IsA("Frame") then
			c:Destroy()
		end
	end
	for i, e in SurvivalClient.effects do
		effectLine(effectList, e[1], e[2], e[3], i)
	end
end

function SurvivalHUD.init()
	gui = Instance.new("ScreenGui")
	gui.Name = "SurvivalHUD"
	gui.ResetOnSpawn = false
	gui.DisplayOrder = 4

	hud = Instance.new("Frame")
	hud.BackgroundTransparency = 1
	hud.AnchorPoint = Vector2.new(0.5, 1)
	hud.Position = UDim2.new(0.5, 0, 1, ROW_Y)
	hud.Size = UDim2.fromOffset(HOTBAR_WIDTH, PIP * 2 + 6)
	hud.Parent = gui

	-- experience bar (our own look: dark track, green fill, pale top edge)
	xpBar = Instance.new("Frame")
	xpBar.Name = "XPBar"
	xpBar.BorderSizePixel = 0
	xpBar.BackgroundColor3 = Color3.fromRGB(20, 22, 18)
	xpBar.BackgroundTransparency = 0.2
	xpBar.AnchorPoint = Vector2.new(0.5, 1)
	xpBar.Position = UDim2.new(0.5, 0, 1, XP_Y)
	xpBar.Size = UDim2.fromOffset(HOTBAR_WIDTH, XP_H)
	xpBar.Parent = gui
	local xpStroke = Instance.new("UIStroke")
	xpStroke.Color = Color3.new(0, 0, 0)
	xpStroke.Transparency = 0.3
	xpStroke.Parent = xpBar
	xpFill = Instance.new("Frame")
	xpFill.BorderSizePixel = 0
	xpFill.BackgroundColor3 = Color3.fromRGB(110, 220, 40)
	xpFill.Size = UDim2.fromScale(0, 1)
	xpFill.Parent = xpBar
	local shine = Instance.new("Frame")
	shine.BorderSizePixel = 0
	shine.BackgroundColor3 = Color3.fromRGB(200, 255, 150)
	shine.Size = UDim2.new(1, 0, 0, 1)
	shine.Parent = xpFill
	xpLevel = Instance.new("TextLabel")
	xpLevel.Name = "XPLevel"
	xpLevel.BackgroundTransparency = 1
	xpLevel.AnchorPoint = Vector2.new(0.5, 0.5)
	xpLevel.Position = UDim2.new(0.5, 0, 0, -3)
	xpLevel.Size = UDim2.fromOffset(80, 18)
	xpLevel.Font = Enum.Font.GothamBlack
	xpLevel.TextSize = 16
	xpLevel.TextColor3 = Color3.fromRGB(128, 255, 32)
	xpLevel.TextStrokeColor3 = Color3.new(0, 0, 0)
	xpLevel.TextStrokeTransparency = 0
	xpLevel.ZIndex = 3
	xpLevel.Visible = false
	xpLevel.Parent = xpBar

	local hRow, hp = pipRow(hud, 10, HEART, false, false)
	hRow.AnchorPoint = Vector2.new(0, 1)
	hRow.Position = UDim2.fromScale(0, 1)
	healthPips = hp
	local fRow, fp = pipRow(hud, 10, FOOD, false, true)
	fRow.AnchorPoint = Vector2.new(1, 1)
	fRow.Position = UDim2.fromScale(1, 1)
	hungerPips = fp
	local aRow, ap = pipRow(hud, 10, Color3.fromRGB(120, 190, 255), true, true)
	aRow.AnchorPoint = Vector2.new(1, 1)
	aRow.Position = UDim2.new(1, 0, 1, -(PIP + 6))
	airRow = aRow
	airPips = ap
	-- armour points (Java: above the health bar, only while wearing armour)
	local arRow, arp = pipRow(hud, 10, Color3.fromRGB(196, 200, 210), false, false)
	arRow.AnchorPoint = Vector2.new(0, 1)
	arRow.Position = UDim2.new(0, 0, 1, -(PIP + 6))
	armorRow = arRow
	armorPips = arp
	-- absorption (gold extra health): its own row right above the health row
	local abRow, abp = pipRow(hud, 10, ABSORB, false, false)
	abRow.AnchorPoint = Vector2.new(0, 1)
	abRow.Position = UDim2.new(0, 0, 1, -(PIP + 6))
	absorbRow = abRow
	absorbPips = abp

	-- active effects, top right (below Roblox's top bar)
	effectList = Instance.new("Frame")
	effectList.Name = "Effects"
	effectList.BackgroundTransparency = 1
	effectList.AnchorPoint = Vector2.new(1, 0)
	effectList.Position = UDim2.new(1, -10, 0, 10)
	effectList.Size = UDim2.fromOffset(190, 200)
	local layout = Instance.new("UIListLayout")
	layout.Padding = UDim.new(0, 4)
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Parent = effectList
	effectList.Parent = gui

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
	deathTitle = title
	deathCause = Instance.new("TextLabel")
	deathCause.BackgroundTransparency = 1
	deathCause.AnchorPoint = Vector2.new(0.5, 0.5)
	deathCause.Position = UDim2.fromScale(0.5, 0.44)
	deathCause.Size = UDim2.fromOffset(600, 30)
	deathCause.Font = Enum.Font.GothamBold
	deathCause.TextSize = 20
	deathCause.TextColor3 = Color3.fromRGB(240, 210, 210)
	deathCause.Parent = deathScreen
	deathScore = Instance.new("TextLabel")
	deathScore.BackgroundTransparency = 1
	deathScore.AnchorPoint = Vector2.new(0.5, 0.5)
	deathScore.Position = UDim2.fromScale(0.5, 0.49)
	deathScore.Size = UDim2.fromOffset(600, 26)
	deathScore.Font = Enum.Font.GothamBold
	deathScore.TextSize = 18
	deathScore.TextColor3 = Color3.fromRGB(255, 255, 255)
	deathScore.Text = "Score: 0"
	deathScore.Parent = deathScreen
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
	respawnButton = respawn
	titleButton = respawn:Clone()
	titleButton.Position = UDim2.fromScale(0.5, 0.66)
	titleButton.Text = "Title Screen"
	titleButton.Visible = false
	titleButton.Parent = deathScreen
	titleButton.Activated:Connect(function()
		-- the world keeps your spectator state; this goes back to the title screen
		game:GetService("ReplicatedStorage"):WaitForChild("Shared")
		require(game:GetService("ReplicatedStorage").Shared.Net.Remotes).get("Menu"):FireServer({ type = "quit" })
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

	-- Hardcore hearts: our own mark, a gold rim around each heart
	local function hardcoreLook()
		local hc = isHardcore()
		for _, p in healthPips do
			local stroke = p.bg:FindFirstChildOfClass("UIStroke")
			if stroke then
				stroke.Color = if hc then Color3.fromRGB(240, 200, 80) else Color3.new(0, 0, 0)
				stroke.Thickness = if hc then 2 else 1
				stroke.Transparency = if hc then 0 else 0.3
			end
		end
	end
	hardcoreLook()
	game:GetService("ReplicatedStorage"):GetAttributeChangedSignal("Hardcore"):Connect(hardcoreLook)

	RunService.RenderStepped:Connect(function()
		-- spectators have no health or hunger to show
		hud.Visible = Players.LocalPlayer:GetAttribute("Spectator") ~= true
		xpBar.Visible = hud.Visible
		xpFill.Size = UDim2.fromScale(math.clamp(ExperienceClient.progress, 0, 1), 1)
		xpLevel.Visible = ExperienceClient.level > 0
		xpLevel.Text = tostring(ExperienceClient.level)
		local h = humanoid()
		setPips(healthPips, if h then math.ceil(h.Health) else 0, false)
		setPips(hungerPips, SurvivalClient.food, true)
		-- effects on the bars
		local poisoned = SurvivalClient.hasEffect("poison")
		local regen = SurvivalClient.hasEffect("regeneration")
		local t = os.clock()
		for i, p in healthPips do
			p.fill.BackgroundColor3 = if poisoned then HEART_POISON else HEART
			-- regeneration: a wave runs along the hearts (our take on Java's bobbing hearts)
			local slot = i - 1
			local y = if regen and math.floor(t * 20) % 10 == slot % 10 then -3 else 0
			p.bg.Position = UDim2.fromOffset(slot * (PIP + PIP_GAP), y)
		end
		local hungry = SurvivalClient.hasEffect("hunger")
		for _, p in hungerPips do
			p.fill.BackgroundColor3 = if hungry then FOOD_HUNGER else FOOD
		end
		local absorb = SurvivalClient.absorption
		absorbRow.Visible = absorb > 0
		setPips(absorbPips, absorb, false)
		refreshEffects()
		local air = SurvivalClient.air
		local maxAir = SurvivalClient.maxAir
		airRow.Visible = air < maxAir
		setPips(airPips, math.ceil(air / maxAir * 20), true)
		local armor = InventoryClient.armorPoints()
		armorRow.Visible = armor > 0
		setPips(armorPips, armor, false)
		-- armour sits above the absorption row when there is one (Java stacks it above all hearts)
		armorRow.Position = UDim2.new(0, 0, 1, -(PIP + 6) * (if absorb > 0 then 2 else 1))
	end)
end

return SurvivalHUD
