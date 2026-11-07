--!strict
-- Lobby screen (public servers): play your own world, join a friend's running world, and choose
-- whether friends may join yours. Talks to server/Lobby/LobbyService over the "Lobby" remote.
-- Original look: dark panel, flat buttons (the full main menu comes in phase 7).

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local GameInfo = require(Shared.GameInfo)
local Remotes = require(Shared.Net.Remotes)

local LobbyUI = {}

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

local function corner(parent: Instance, r: number)
	make("UICorner", { CornerRadius = UDim.new(0, r) }, parent)
end

local function button(parent: Instance, text: string, size: UDim2, color: Color3): TextButton
	local b = make("TextButton", {
		Size = size,
		BackgroundColor3 = color,
		TextColor3 = Color3.fromRGB(240, 240, 245),
		Font = Enum.Font.GothamBold,
		TextSize = 18,
		Text = text,
		AutoButtonColor = true,
	}, parent)
	corner(b, 8)
	return b
end

function LobbyUI.init()
	local remote = Remotes.get("Lobby")
	local camera = workspace.CurrentCamera
	camera.CameraType = Enum.CameraType.Scriptable
	camera.CFrame = CFrame.new(0, 50, 0)

	local gui = make("ScreenGui", { Name = "Lobby", ResetOnSpawn = false, IgnoreGuiInset = true }, nil)
	local bg = make("Frame", {
		Size = UDim2.fromScale(1, 1),
		BackgroundColor3 = Color3.fromRGB(18, 20, 28),
		BorderSizePixel = 0,
	}, gui)
	local panel = make("Frame", {
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.new(0, 420, 0, 520),
		BackgroundColor3 = Color3.fromRGB(32, 35, 46),
		BorderSizePixel = 0,
	}, bg)
	corner(panel, 14)
	make("UISizeConstraint", { MaxSize = Vector2.new(420, 520) }, panel)
	make("UIPadding", {
		PaddingTop = UDim.new(0, 20),
		PaddingBottom = UDim.new(0, 20),
		PaddingLeft = UDim.new(0, 20),
		PaddingRight = UDim.new(0, 20),
	}, panel)
	make("UIListLayout", { Padding = UDim.new(0, 12), SortOrder = Enum.SortOrder.LayoutOrder }, panel)

	make("TextLabel", {
		LayoutOrder = 1,
		Size = UDim2.new(1, 0, 0, 44),
		BackgroundTransparency = 1,
		Text = GameInfo.TITLE,
		TextColor3 = Color3.fromRGB(250, 220, 120),
		Font = Enum.Font.GothamBlack,
		TextSize = 40,
	}, panel)

	local play = button(panel, "Play my world", UDim2.new(1, 0, 0, 48), Color3.fromRGB(60, 140, 80))
	play.LayoutOrder = 2

	local friendsToggle = button(panel, "Friends can join: ...", UDim2.new(1, 0, 0, 36), Color3.fromRGB(60, 64, 80))
	friendsToggle.LayoutOrder = 3
	friendsToggle.TextSize = 16

	make("TextLabel", {
		LayoutOrder = 4,
		Size = UDim2.new(1, 0, 0, 24),
		BackgroundTransparency = 1,
		Text = "Friends' worlds (running now)",
		TextColor3 = Color3.fromRGB(200, 200, 210),
		Font = Enum.Font.GothamBold,
		TextSize = 16,
		TextXAlignment = Enum.TextXAlignment.Left,
	}, panel)

	local list = make("ScrollingFrame", {
		LayoutOrder = 5,
		Size = UDim2.new(1, 0, 0, 220),
		BackgroundColor3 = Color3.fromRGB(24, 26, 34),
		BorderSizePixel = 0,
		ScrollBarThickness = 6,
		AutomaticCanvasSize = Enum.AutomaticSize.Y,
		CanvasSize = UDim2.new(),
	}, panel)
	corner(list, 8)
	make("UIListLayout", { Padding = UDim.new(0, 6) }, list)
	make("UIPadding", {
		PaddingTop = UDim.new(0, 6),
		PaddingLeft = UDim.new(0, 6),
		PaddingRight = UDim.new(0, 6),
	}, list)

	local refresh = button(panel, "Refresh", UDim2.new(1, 0, 0, 32), Color3.fromRGB(60, 64, 80))
	refresh.LayoutOrder = 6
	refresh.TextSize = 16

	local statusLabel = make("TextLabel", {
		LayoutOrder = 7,
		Size = UDim2.new(1, 0, 0, 40),
		BackgroundTransparency = 1,
		Text = "Loading...",
		TextWrapped = true,
		TextColor3 = Color3.fromRGB(180, 180, 190),
		Font = Enum.Font.Gotham,
		TextSize = 14,
	}, panel)

	local friendsOn = true
	local function setStatus(t: string)
		statusLabel.Text = t
	end

	remote.OnClientEvent:Connect(function(msg: any)
		if typeof(msg) ~= "table" then
			return
		end
		if msg.type == "status" and typeof(msg.text) == "string" then
			setStatus(msg.text)
		elseif msg.type == "state" then
			friendsOn = msg.friends ~= false
			friendsToggle.Text = if friendsOn then "Friends can join my world: ON" else "Friends can join my world: OFF"
			for _, c in list:GetChildren() do
				if c:IsA("Frame") then
					c:Destroy()
				end
			end
			local worlds = if typeof(msg.worlds) == "table" then msg.worlds else {}
			for _, w in worlds do
				local row = make("Frame", {
					Size = UDim2.new(1, 0, 0, 40),
					BackgroundColor3 = Color3.fromRGB(40, 44, 58),
					BorderSizePixel = 0,
				}, list)
				corner(row, 6)
				make("TextLabel", {
					Position = UDim2.fromOffset(10, 0),
					Size = UDim2.new(1, -110, 1, 0),
					BackgroundTransparency = 1,
					Text = `{w.name}'s world ({w.players} playing)`,
					TextColor3 = Color3.fromRGB(230, 230, 235),
					Font = Enum.Font.Gotham,
					TextSize = 15,
					TextXAlignment = Enum.TextXAlignment.Left,
				}, row)
				local join = button(row, "Join", UDim2.fromOffset(84, 30), Color3.fromRGB(60, 110, 160))
				join.AnchorPoint = Vector2.new(1, 0.5)
				join.Position = UDim2.new(1, -6, 0.5, 0)
				join.TextSize = 15
				local ownerId = w.userId
				join.Activated:Connect(function()
					remote:FireServer({ type = "join", ownerId = ownerId })
				end)
			end
			if #worlds == 0 then
				local row = make("Frame", { Size = UDim2.new(1, 0, 0, 30), BackgroundTransparency = 1 }, list)
				make("TextLabel", {
					Size = UDim2.fromScale(1, 1),
					BackgroundTransparency = 1,
					Text = "No friends' worlds are open right now.",
					TextColor3 = Color3.fromRGB(150, 150, 160),
					Font = Enum.Font.Gotham,
					TextSize = 14,
				}, row)
			end
			setStatus(if msg.saving == false then "Warning: saving is unavailable on this server." else "")
		end
	end)

	play.Activated:Connect(function()
		remote:FireServer({ type = "play" })
	end)
	friendsToggle.Activated:Connect(function()
		remote:FireServer({ type = "setFriends", on = not friendsOn })
	end)
	refresh.Activated:Connect(function()
		setStatus("Refreshing...")
		remote:FireServer({ type = "state" })
	end)

	gui.Parent = Players.LocalPlayer:WaitForChild("PlayerGui")
	remote:FireServer({ type = "state" })
end

return LobbyUI
