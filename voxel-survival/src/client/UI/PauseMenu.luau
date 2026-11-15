--!strict
-- The pause menu (Java's Game Menu): P or the button at the top of the screen.
--   Back to Game / Options / World Settings / Save and Quit to Title
-- World Settings: the world's difficulty and whether friends can join; only the world's owner
-- can change them (others see them). A Hardcore world is always Hard.
-- The world keeps running while the menu is open (it's a server shared with friends).

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared.Config)
local Remotes = require(Shared.Net.Remotes)
local Difficulty = require(Shared.Gameplay.Difficulty)
local MenuKit = require(script.Parent.MenuKit)
local SettingsUI = require(script.Parent.SettingsUI)
local InventoryClient = require(script.Parent.Parent.Player.InventoryClient)
local CameraController = require(script.Parent.Parent.Player.CameraController)
local SurvivalClient = require(script.Parent.Parent.Survival.SurvivalClient)

local C = MenuKit.COLORS

local PauseMenu = {}
PauseMenu.open = false

local screen: ScreenGui
local pages: { [string]: Frame } = {}
local statusLabel: TextLabel

local function isOwner(): boolean
	return ReplicatedStorage:GetAttribute("WorldOwner") == Players.LocalPlayer.UserId
		or game:GetService("RunService"):IsStudio()
end

local function setStatus(text: string)
	statusLabel.Text = text
end

function PauseMenu.setOpen(on: boolean)
	if on == PauseMenu.open then
		return
	end
	if on and (InventoryClient.uiOpen or SurvivalClient.dead) then
		return -- another window (or the death screen) is up
	end
	PauseMenu.open = on
	InventoryClient.uiOpen = on
	CameraController.mouseUnlocked = on
	setStatus("")
	MenuKit.show(pages :: any, if on then "main" else nil)
end

function PauseMenu.init()
	screen = MenuKit.screen("PauseMenu", 60)
	statusLabel = MenuKit.make("TextLabel", {
		AnchorPoint = Vector2.new(0.5, 1),
		Position = UDim2.new(0.5, 0, 1, -6),
		Size = UDim2.new(1, -32, 0, 22),
		BackgroundTransparency = 1,
		Text = "",
		TextColor3 = C.text,
		TextStrokeTransparency = 0.4,
		Font = Enum.Font.GothamBold,
		TextSize = 15,
		ZIndex = 20,
	}, screen)

	-- Game Menu
	local main, list = MenuKit.page(screen, "Game Menu")
	pages.main = main
	MenuKit.button(list, "Back to Game", "primary").Activated:Connect(function()
		PauseMenu.setOpen(false)
	end)
	MenuKit.button(list, "Options...").Activated:Connect(function()
		MenuKit.show(pages :: any, "options")
	end)
	MenuKit.button(list, "World Settings...").Activated:Connect(function()
		MenuKit.show(pages :: any, "world")
	end)
	MenuKit.button(list, "Save and Quit to Title").Activated:Connect(function()
		Remotes.get("Menu"):FireServer({ type = "quit" })
	end)

	-- Options
	pages.options = SettingsUI.build(screen, function()
		MenuKit.show(pages :: any, "main")
	end)

	-- World Settings
	local world, wlist = MenuKit.page(screen, "World Settings")
	pages.world = world
	local info = MenuKit.label(wlist, "", true)
	local diffOptions = {}
	for _, n in Difficulty.ORDER do
		table.insert(diffOptions, { n, Difficulty.LABEL[n] })
	end
	local diffBtn, refreshDiff = MenuKit.cycle(wlist, "Difficulty", diffOptions, function()
		return Difficulty.sanitize(ReplicatedStorage:GetAttribute("Difficulty"))
	end, function(v)
		if ReplicatedStorage:GetAttribute("Hardcore") == true then
			setStatus("A Hardcore world is always Hard.")
			return
		end
		if not isOwner() then
			setStatus("Only the world's owner can change this.")
			return
		end
		Remotes.get("WorldSettings"):FireServer({ type = "difficulty", value = v })
	end, function(): string?
		return if ReplicatedStorage:GetAttribute("Hardcore") == true then "Difficulty: Hard (Hardcore)" else nil
	end)
	local friendsBtn, refreshFriends = MenuKit.toggle(wlist, "Friends can join", function()
		return ReplicatedStorage:GetAttribute("FriendsCanJoin") ~= false
	end, function(v)
		if not isOwner() then
			setStatus("Only the world's owner can change this.")
			return
		end
		Remotes.get("WorldSettings"):FireServer({ type = "friends", on = v })
	end)
	MenuKit.button(wlist, "Done", "primary").Activated:Connect(function()
		MenuKit.show(pages :: any, "main")
	end)
	local function refreshWorld()
		local hc = ReplicatedStorage:GetAttribute("Hardcore") == true
		refreshDiff()
		refreshFriends()
		local owner = isOwner()
		diffBtn.BackgroundTransparency = if hc or not owner then 0.6 else 0
		friendsBtn.BackgroundTransparency = if owner then 0 else 0.6
		info.Text = if hc then "Hardcore world: one life, always Hard."
			elseif owner then "You own this world."
			else "Only the world's owner can change these."
	end
	world:GetPropertyChangedSignal("Visible"):Connect(function()
		if world.Visible then
			refreshWorld()
		end
	end)
	for _, attr in { "Difficulty", "Hardcore", "FriendsCanJoin" } do
		ReplicatedStorage:GetAttributeChangedSignal(attr):Connect(function()
			if world.Visible then
				refreshWorld()
			end
		end)
	end

	-- messages from the server
	for _, name in { "Menu", "WorldSettings" } do
		Remotes.get(name).OnClientEvent:Connect(function(m: any)
			if typeof(m) == "table" and m.type == "status" and typeof(m.text) == "string" then
				setStatus(m.text)
				if not PauseMenu.open and name == "WorldSettings" then
					-- (e.g. "The difficulty is now Hard" for everyone): show it briefly
					task.delay(4, function()
						if statusLabel.Text == m.text then
							setStatus("")
						end
					end)
				end
			end
		end)
	end

	-- the pause button at the top (always there; on phones it's the only way in)
	local button = MenuKit.make("TextButton", {
		Name = "PauseButton",
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.new(0.5, 0, 0, 6),
		Size = UDim2.fromOffset(44, 36),
		BackgroundColor3 = C.panel,
		BackgroundTransparency = 0.35,
		TextColor3 = C.text,
		Font = Enum.Font.GothamBlack,
		TextSize = 18,
		Text = "II",
		ZIndex = 5,
	}, screen)
	MenuKit.corner(button, 8)
	button.Activated:Connect(function()
		PauseMenu.setOpen(not PauseMenu.open)
	end)

	local key = (Enum.KeyCode :: any)[Config.KEY_PAUSE]
	UserInputService.InputBegan:Connect(function(input, processed)
		if processed then
			return
		end
		if input.KeyCode == key then
			PauseMenu.setOpen(not PauseMenu.open)
		end
	end)
	-- dying closes it (the death screen takes over)
	SurvivalClient.Changed:Connect(function(event: string?)
		if event == "died" and PauseMenu.open then
			PauseMenu.setOpen(false)
		end
	end)

	MenuKit.show(pages :: any, nil)
	screen.Parent = MenuKit.playerGui()
end

return PauseMenu
