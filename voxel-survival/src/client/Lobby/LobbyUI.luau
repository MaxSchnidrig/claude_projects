--!strict
-- The title screen (lobby servers, and Studio before a world opens). Our own layout, in the spirit
-- of Java's title screen and world list:
--   Home       Play / Friends' Worlds / Options
--   Worlds     your worlds, most recently played first: play, create, delete, friends on/off
--   Create     name, game mode (Survival / Hardcore), difficulty, seed
--   Friends    friends' worlds running now
--   Options    shared with the pause menu (UI/SettingsUI)
-- Talks to server/Lobby/LobbyService over the "Lobby" remote.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local GameInfo = require(Shared.GameInfo)
local Remotes = require(Shared.Net.Remotes)
local Difficulty = require(Shared.Gameplay.Difficulty)
local MenuKit = require(script.Parent.Parent.UI.MenuKit)
local SettingsUI = require(script.Parent.Parent.UI.SettingsUI)

local C = MenuKit.COLORS
local make = MenuKit.make

local LobbyUI = {}
local gui: ScreenGui? = nil

local function when(t: number): string
	if t <= 0 then
		return ""
	end
	return os.date("%d %b %Y, %H:%M", t) :: string
end

function LobbyUI.init()
	local remote = Remotes.get("Lobby")
	local camera = workspace.CurrentCamera
	camera.CameraType = Enum.CameraType.Scriptable
	camera.CFrame = CFrame.new(0, 50, 0)

	local screen = MenuKit.screen("TitleScreen", 100)
	gui = screen
	local pages: { [string]: Frame } = {}

	-- status line at the bottom (errors in red)
	local statusLabel = make("TextLabel", {
		AnchorPoint = Vector2.new(0.5, 1),
		Position = UDim2.new(0.5, 0, 1, -6),
		Size = UDim2.new(1, -32, 0, 22),
		BackgroundTransparency = 1,
		Text = "",
		TextColor3 = C.muted,
		Font = Enum.Font.GothamBold,
		TextSize = 15,
		ZIndex = 20,
	}, screen)
	local function setStatus(text: string, isError: boolean?)
		statusLabel.Text = text
		statusLabel.TextColor3 = if isError then C.hardcore else C.muted
	end
	make("TextLabel", {
		AnchorPoint = Vector2.new(0, 1),
		Position = UDim2.new(0, 10, 1, -6),
		Size = UDim2.fromOffset(200, 18),
		BackgroundTransparency = 1,
		Text = `{GameInfo.TITLE} {GameInfo.VERSION}`,
		TextColor3 = C.muted,
		TextXAlignment = Enum.TextXAlignment.Left,
		Font = Enum.Font.Gotham,
		TextSize = 13,
		ZIndex = 20,
	}, screen)

	local function show(name: string)
		MenuKit.show(pages :: any, name)
	end

	-- Home ---------------------------------------------------------------------------------
	local home, homeList = MenuKit.page(screen, GameInfo.TITLE, true)
	pages.home = home
	MenuKit.button(homeList, "Play", "primary").Activated:Connect(function()
		show("worlds")
		remote:FireServer({ type = "state" })
	end)
	MenuKit.button(homeList, "Friends' Worlds").Activated:Connect(function()
		show("friends")
		setStatus("Looking for friends' worlds...")
		remote:FireServer({ type = "state" })
	end)
	MenuKit.button(homeList, "Options").Activated:Connect(function()
		show("options")
	end)
	local hint = MenuKit.label(homeList, "", true)

	-- Worlds -------------------------------------------------------------------------------
	local worldsPage, worldsList = MenuKit.page(screen, "Select World", true)
	pages.worlds = worldsPage
	local rows = make("Frame", {
		LayoutOrder = 0,
		Size = UDim2.new(1, 0, 0, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		BackgroundTransparency = 1,
	}, worldsList)
	make("UIListLayout", { Padding = UDim.new(0, 6), SortOrder = Enum.SortOrder.LayoutOrder }, rows)
	local selected: string? = nil
	local worlds: { any } = {}
	local maxWorlds = 10
	local playBtn = MenuKit.button(worldsList, "Play Selected World", "primary")
	local createBtn = MenuKit.button(worldsList, "Create New World")
	local actionRow = MenuKit.row(worldsList)
	local friendsBtn = MenuKit.button(actionRow, "Friends can join: -")
	local deleteBtn = MenuKit.button(actionRow, "Delete", "danger")
	MenuKit.button(worldsList, "Back").Activated:Connect(function()
		show("home")
	end)

	local function selectedWorld(): any
		for _, w in worlds do
			if w.key == selected then
				return w
			end
		end
		return nil
	end
	local function refreshButtons()
		local w = selectedWorld()
		playBtn.Active, playBtn.AutoButtonColor = w ~= nil, w ~= nil
		playBtn.BackgroundTransparency = if w then 0 else 0.6
		deleteBtn.BackgroundTransparency = if w then 0 else 0.6
		friendsBtn.BackgroundTransparency = if w then 0 else 0.6
		friendsBtn.Text = if w then `Friends can join: {if w.friends then "ON" else "OFF"}` else "Friends can join: -"
		createBtn.Text = if #worlds >= maxWorlds then `Create New World (max {maxWorlds})` else "Create New World"
	end
	local function drawRows()
		for _, c in rows:GetChildren() do
			if c:IsA("GuiObject") then
				c:Destroy()
			end
		end
		if #worlds == 0 then
			MenuKit.label(rows, "No worlds yet. Create one!", true)
		end
		for i, w in worlds do
			local isSel = w.key == selected
			local b = make("TextButton", {
				LayoutOrder = i,
				Size = UDim2.new(1, 0, 0, 58),
				BackgroundColor3 = if isSel then C.buttonHover else C.inset,
				AutoButtonColor = true,
				Text = "",
			}, rows)
			MenuKit.corner(b, 8)
			if isSel then
				make("UIStroke", { Color = C.title, Thickness = 2 }, b)
			end
			make("TextLabel", {
				Position = UDim2.fromOffset(12, 6),
				Size = UDim2.new(1, -24, 0, 24),
				BackgroundTransparency = 1,
				Text = w.name,
				TextColor3 = C.text,
				TextXAlignment = Enum.TextXAlignment.Left,
				TextTruncate = Enum.TextTruncate.AtEnd,
				Font = Enum.Font.GothamBold,
				TextSize = 17,
			}, b)
			local mode = if w.hardcore then "Hardcore" else `Survival, {Difficulty.LABEL[w.difficulty] or "Normal"}`
			make("TextLabel", {
				Position = UDim2.fromOffset(12, 30),
				Size = UDim2.new(1, -24, 0, 20),
				BackgroundTransparency = 1,
				Text = `{mode}   {when(w.played)}`,
				TextColor3 = if w.hardcore then C.hardcore else C.muted,
				TextXAlignment = Enum.TextXAlignment.Left,
				TextTruncate = Enum.TextTruncate.AtEnd,
				Font = Enum.Font.Gotham,
				TextSize = 14,
			}, b)
			local key = w.key
			b.Activated:Connect(function()
				if selected == key then
					-- second tap / double click plays it (Java: double-click)
					setStatus(`Opening {w.name}...`)
					remote:FireServer({ type = "play", world = key })
					return
				end
				selected = key
				drawRows()
				refreshButtons()
			end)
		end
	end
	playBtn.Activated:Connect(function()
		local w = selectedWorld()
		if w then
			setStatus(`Opening {w.name}...`)
			remote:FireServer({ type = "play", world = w.key })
		end
	end)
	friendsBtn.Activated:Connect(function()
		local w = selectedWorld()
		if w then
			remote:FireServer({ type = "setFriends", world = w.key, on = not w.friends })
		end
	end)
	deleteBtn.Activated:Connect(function()
		local w = selectedWorld()
		if not w then
			return
		end
		MenuKit.confirm(screen, `Delete "{w.name}"?`, "It will be lost forever (a long time!)", "Delete", function()
			setStatus("Deleting...")
			remote:FireServer({ type = "delete", world = w.key })
			selected = nil
		end)
	end)

	-- Create -------------------------------------------------------------------------------
	local createPage, createList = MenuKit.page(screen, "Create New World", true)
	pages.create = createPage
	MenuKit.label(createList, "World Name", true)
	local nameBox = MenuKit.textbox(createList, "New World", 32)
	local hardcore = false
	local difficulty: Difficulty.Name = Difficulty.DEFAULT
	local modeHelp: TextLabel
	local refreshDifficulty: () -> ()
	local _, refreshMode = MenuKit.cycle(createList, "Game Mode", { { false, "Survival" }, { true, "Hardcore" } }, function()
		return hardcore
	end, function(v)
		hardcore = v
		modeHelp.Text = if hardcore
			then "Same as Survival, but locked at the hardest difficulty, and you only have one life. After you die you can only watch."
			else "Search for resources, craft, gain levels, health and hunger."
		refreshDifficulty()
	end)
	modeHelp = MenuKit.label(createList, "Search for resources, craft, gain levels, health and hunger.", true)
	local diffOptions = {}
	for _, n in Difficulty.ORDER do
		table.insert(diffOptions, { n, Difficulty.LABEL[n] })
	end
	local diffBtn
	diffBtn, refreshDifficulty = MenuKit.cycle(createList, "Difficulty", diffOptions, function()
		return if hardcore then "hard" else difficulty
	end, function(v)
		if not hardcore then
			difficulty = v
		end
	end)
	local baseRefresh = refreshDifficulty
	refreshDifficulty = function()
		baseRefresh()
		diffBtn.BackgroundTransparency = if hardcore then 0.6 else 0
		if hardcore then
			diffBtn.Text = "Difficulty: Hard (Hardcore)"
		end
	end
	MenuKit.label(createList, "Seed for the world generator", true)
	local seedBox = MenuKit.textbox(createList, "Leave blank for a random seed", 32)
	local createRow = MenuKit.row(createList)
	local createGo = MenuKit.button(createRow, "Create New World", "primary")
	MenuKit.button(createRow, "Cancel").Activated:Connect(function()
		show("worlds")
	end)
	createBtn.Activated:Connect(function()
		if #worlds >= maxWorlds then
			setStatus(`You already have {maxWorlds} worlds. Delete one to make room.`, true)
			return
		end
		nameBox.Text, seedBox.Text = "", ""
		hardcore, difficulty = false, Difficulty.DEFAULT
		refreshMode()
		modeHelp.Text = "Search for resources, craft, gain levels, health and hunger."
		refreshDifficulty()
		show("create")
	end)
	createGo.Activated:Connect(function()
		setStatus("Creating the world...")
		remote:FireServer({
			type = "create", name = nameBox.Text, hardcore = hardcore, difficulty = difficulty, seed = seedBox.Text,
		})
	end)

	-- Friends ------------------------------------------------------------------------------
	local friendsPage, friendsList = MenuKit.page(screen, "Friends' Worlds", true)
	pages.friends = friendsPage
	local friendRows = make("Frame", {
		LayoutOrder = 0,
		Size = UDim2.new(1, 0, 0, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		BackgroundTransparency = 1,
	}, friendsList)
	make("UIListLayout", { Padding = UDim.new(0, 6), SortOrder = Enum.SortOrder.LayoutOrder }, friendRows)
	MenuKit.button(friendsList, "Refresh").Activated:Connect(function()
		setStatus("Refreshing...")
		remote:FireServer({ type = "state" })
	end)
	MenuKit.button(friendsList, "Back").Activated:Connect(function()
		show("home")
	end)
	local function drawFriends(list: { any }, studio: boolean)
		for _, c in friendRows:GetChildren() do
			if c:IsA("GuiObject") then
				c:Destroy()
			end
		end
		if #list == 0 then
			MenuKit.label(friendRows, if studio
				then "Friends' worlds can't be joined from Studio."
				else "None of your friends have a world open to friends right now.", true)
		end
		for i, w in list do
			local row = make("Frame", {
				LayoutOrder = i,
				Size = UDim2.new(1, 0, 0, 48),
				BackgroundColor3 = C.inset,
			}, friendRows)
			MenuKit.corner(row, 8)
			make("TextLabel", {
				Position = UDim2.fromOffset(12, 0),
				Size = UDim2.new(1, -120, 1, 0),
				BackgroundTransparency = 1,
				Text = `{w.name}'s world ({w.players} playing)`,
				TextColor3 = C.text,
				TextXAlignment = Enum.TextXAlignment.Left,
				TextTruncate = Enum.TextTruncate.AtEnd,
				Font = Enum.Font.Gotham,
				TextSize = 15,
			}, row)
			local join = make("TextButton", {
				AnchorPoint = Vector2.new(1, 0.5),
				Position = UDim2.new(1, -6, 0.5, 0),
				Size = UDim2.fromOffset(96, 36),
				BackgroundColor3 = C.primary,
				TextColor3 = C.text,
				Font = Enum.Font.GothamBold,
				TextSize = 16,
				Text = "Join",
			}, row)
			MenuKit.corner(join, 8)
			local ownerId = w.userId
			join.Activated:Connect(function()
				remote:FireServer({ type = "join", ownerId = ownerId })
			end)
		end
	end

	-- Options ------------------------------------------------------------------------------
	pages.options = SettingsUI.build(screen, function()
		show("home")
	end)
	for _, p in pages do
		p.ZIndex = 1
	end

	remote.OnClientEvent:Connect(function(msg: any)
		if typeof(msg) ~= "table" then
			return
		end
		if msg.type == "status" and typeof(msg.text) == "string" then
			setStatus(msg.text, msg.error == true)
		elseif msg.type == "created" and typeof(msg.world) == "string" then
			selected = msg.world
			show("worlds")
		elseif msg.type == "state" then
			worlds = if typeof(msg.worlds) == "table" then msg.worlds else {}
			maxWorlds = if typeof(msg.max) == "number" then msg.max else 10
			if not selectedWorld() then
				selected = if worlds[1] then worlds[1].key else nil
			end
			drawRows()
			refreshButtons()
			drawFriends(if typeof(msg.friendsWorlds) == "table" then msg.friendsWorlds else {}, msg.studio == true)
			if msg.listOk == false then
				setStatus("Couldn't load your worlds (saving service unavailable). Try again in a minute.", true)
			elseif msg.saving == false then
				setStatus("Saving is unavailable here: worlds won't be kept.", true)
			elseif not string.find(statusLabel.Text, "Opening", 1, true) and not string.find(statusLabel.Text, "Creating", 1, true) then
				setStatus("")
			end
			hint.Text = if msg.studio == true
				then "Studio: the world opens in this test session. Stop the test to come back here."
				else ""
		end
	end)

	show("home")
	screen.Parent = MenuKit.playerGui()
	remote:FireServer({ type = "state" })
end

-- The world opened in this server (Studio): remove the title screen.
function LobbyUI.close()
	if gui then
		gui:Destroy()
		gui = nil
	end
end

return LobbyUI
