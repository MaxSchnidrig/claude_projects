--!strict
--[[
	IndexController
	===============
	The 📖 Index window: every fish in the game, zone by zone.

	  [zone tabs]  [grid of that zone's 8 fish]     [big preview of the selected fish]
	               [progress bar "4/8" + zone reward] [its reward + CLAIM]
	               [CLAIM ALL (n)]

	  - Found fish show their picture and name; not-found fish are a black
	    silhouette with "???". Card colors match the fish's rarity.
	  - A newly found fish has a reward (cash + Speed) to claim; a green dot
	    marks it. Finding all 8 fish of a zone unlocks the zone reward.
	  - The red badge on the Index button = how many rewards are waiting.

	The server owns the data: it sends it with "IndexSync", and every claim
	only ASKS the server ("IndexClaim").
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = require(ReplicatedStorage.Shared.Config)
local Fish = require(ReplicatedStorage.Shared.Fish)
local Format = require(ReplicatedStorage.Shared.Format)
local Net = require(ReplicatedStorage.Shared.Net)
local Rarity = require(ReplicatedStorage.Shared.Rarity)
local FishPicture = require(script.Parent.Parent.Ui.FishPicture)
local Hud = require(script.Parent.Parent.Ui.Hud)
local Kit = require(script.Parent.Parent.Ui.Kit)
local Sounds = require(script.Parent.Parent.Ui.Sounds)

local IndexController = {}
IndexController.Name = "IndexController"

local LOCKED_COLOR = Color3.fromRGB(55, 60, 75)

type IndexData = { Found: { [string]: boolean }, Claimed: { [string]: boolean }, ZonesClaimed: { [number]: boolean } }

local data: IndexData = { Found = {}, Claimed = {}, ZonesClaimed = {} }
local window: Kit.Window
local zoneButtons: { [number]: TextButton } = {}
local grid: Frame
local progressFill: Frame
local progressText: TextLabel
local zoneRewardText: TextLabel
local zoneClaim: TextButton
local claimAll: TextButton
local preview: Frame
local previewName: TextLabel
local previewInfo: TextLabel
local previewReward: TextLabel
local previewClaim: TextButton
local currentZone = 1
local selected: Config.FishConfig? = nil

local function foundCount(zoneIndex: number): number
	local count = 0
	for _, fish in Fish.inZone(zoneIndex) do
		if data.Found[fish.Name] then
			count += 1
		end
	end
	return count
end

local function zoneClaimable(zoneIndex: number): boolean
	local total = #Fish.inZone(zoneIndex)
	return total > 0 and foundCount(zoneIndex) == total and not data.ZonesClaimed[zoneIndex]
end

-- How many rewards are waiting (fish + zones).
local function waitingRewards(): number
	local count = 0
	for name in data.Found do
		if not data.Claimed[name] then
			count += 1
		end
	end
	for zoneIndex in Config.Zones do
		if zoneClaimable(zoneIndex) then
			count += 1
		end
	end
	return count
end

local function rewardText(cash: number, speed: number): string
	return `+${Format.short(cash)}   +⚡{Format.short(speed)}`
end

---------------------------------------------------------------------------
-- Drawing
---------------------------------------------------------------------------

local function clearChildren(parent: Instance, keep: { [Instance]: boolean }?)
	for _, child in parent:GetChildren() do
		if child:IsA("GuiObject") and not (keep and keep[child]) then
			child:Destroy()
		end
	end
end

local function drawPreview()
	local picture = preview:FindFirstChild("Picture")
	if picture then
		picture:Destroy()
	end
	local fish = selected
	if not fish then
		previewName.Text = "Pick a fish"
		previewInfo.Text = ""
		previewReward.Text = ""
		previewClaim.Visible = false
		return
	end
	local found = data.Found[fish.Name] == true
	local holder = preview:FindFirstChild("PictureHolder") :: Frame
	FishPicture.create(holder, fish, UDim2.fromScale(1, 1), UDim2.new(), not found)
	if found then
		previewName.Text = fish.Name
		previewName.TextColor3 = Rarity.color(fish.Rarity)
		previewInfo.Text = `{fish.Rarity}\n${Format.short(fish.Income)}/s`
	else
		previewName.Text = "???"
		previewName.TextColor3 = Kit.Colors.Text
		previewInfo.Text = `{fish.Rarity}\nNot found yet`
	end
	local cash, speed = Config.IndexFishReward(fish)
	previewReward.Text = `Reward: {rewardText(cash, speed)}`
	local claimable = found and not data.Claimed[fish.Name]
	previewClaim.Visible = found
	Kit.setText(previewClaim, if claimable then "CLAIM!" elseif found then "Claimed ✓" else "")
	Kit.setColor(previewClaim, if claimable then Kit.Colors.Green else Kit.Colors.Grey)
end

local function drawGrid()
	clearChildren(grid)
	for order, fish in Fish.inZone(currentZone) do
		local found = data.Found[fish.Name] == true
		local card = Instance.new("TextButton")
		card.LayoutOrder = order
		card.Text = ""
		card.AutoButtonColor = true
		card.BackgroundColor3 = if found then Rarity.color(fish.Rarity) else LOCKED_COLOR
		card.Parent = grid
		Kit.corner(card, 10)
		local isSelected = selected ~= nil and selected.Name == fish.Name
		Kit.stroke(card, if isSelected then Color3.new(1, 1, 1) else Kit.Colors.Outline, if isSelected then 4 else 3)
		FishPicture.create(card, fish, UDim2.new(1, -10, 1, -30), UDim2.fromOffset(5, 26), not found)
		local name = Kit.label(card, if found then fish.Name else "???", UDim2.new(1, -8, 0, 22), UDim2.fromOffset(4, 3), Kit.Colors.Text, 2)
		name.TextXAlignment = Enum.TextXAlignment.Center
		if found and not data.Claimed[fish.Name] then
			-- Green dot: a reward is waiting.
			local dot = Instance.new("Frame")
			dot.AnchorPoint = Vector2.new(0.5, 0.5)
			dot.Position = UDim2.new(1, -6, 0, 6)
			dot.Size = UDim2.fromOffset(22, 22)
			dot.BackgroundColor3 = Kit.Colors.Green
			dot.ZIndex = 3
			dot.Parent = card
			Kit.corner(dot, 11)
			Kit.stroke(dot, Color3.new(1, 1, 1), 2)
		end
		card.Activated:Connect(function()
			Sounds.play("Click")
			selected = fish
			drawGrid()
			drawPreview()
		end)
	end

	-- Progress bar and zone reward.
	local total = #Fish.inZone(currentZone)
	local count = foundCount(currentZone)
	progressFill.Size = UDim2.fromScale(if total > 0 then count / total else 0, 1)
	progressText.Text = `{count}/{total}`
	local cash, speed = Config.IndexZoneReward(currentZone)
	zoneRewardText.Text = `Complete: {rewardText(cash, speed)}`
	local claimable = zoneClaimable(currentZone)
	Kit.setText(zoneClaim, if data.ZonesClaimed[currentZone] then "✓" else "CLAIM!")
	Kit.setColor(zoneClaim, if claimable then Kit.Colors.Green else Kit.Colors.Grey)
end

local function drawTabs()
	for zoneIndex, button in zoneButtons do
		local zone = Config.Zones[zoneIndex]
		Kit.setText(button, `{zone.Name}  {foundCount(zoneIndex)}/{#Fish.inZone(zoneIndex)}`)
		local stroke = button:FindFirstChildOfClass("UIStroke")
		if stroke then
			stroke.Color = if zoneIndex == currentZone then Color3.new(1, 1, 1) else Kit.Colors.Outline
			stroke.Thickness = if zoneIndex == currentZone then 4 else 3
		end
	end
end

local function redraw()
	local waiting = waitingRewards()
	Hud.setIndexBadge(waiting)
	Kit.setText(claimAll, if waiting > 0 then `CLAIM ALL ({waiting})!` else "CLAIM ALL")
	Kit.setColor(claimAll, if waiting > 0 then Kit.Colors.Blue else Kit.Colors.Grey)
	if not window.IsOpen() then
		return
	end
	drawTabs()
	drawGrid()
	drawPreview()
end

local function selectZone(zoneIndex: number)
	currentZone = zoneIndex
	local list = Fish.inZone(zoneIndex)
	selected = list[1]
	redraw()
end

---------------------------------------------------------------------------
-- Building the window
---------------------------------------------------------------------------

function IndexController.Init()
	window = Kit.window("📖 Fish Index", Vector2.new(900, 500), { Color = Kit.Colors.Blue })
	local content = window.Content

	-- Zone tabs on the left.
	local tabs = Kit.scroll(content, UDim2.new(0, 190, 1, 0), UDim2.new())
	Kit.list(tabs, 8)
	local tabPadding = Instance.new("UIPadding")
	tabPadding.PaddingTop = UDim.new(0, 4)
	tabPadding.PaddingLeft = UDim.new(0, 4)
	tabPadding.PaddingRight = UDim.new(0, 12)
	tabPadding.Parent = tabs
	for zoneIndex, zone in Config.Zones do
		local button = Kit.button(tabs, zone.Name, zone.Color, UDim2.new(1, 0, 0, 46))
		button.LayoutOrder = zoneIndex
		button.Activated:Connect(function()
			selectZone(zoneIndex)
		end)
		zoneButtons[zoneIndex] = button
	end

	-- The fish grid in the middle.
	local middle = Instance.new("Frame")
	middle.Position = UDim2.fromOffset(204, 0)
	middle.Size = UDim2.new(1, -204 - 250, 1, 0)
	middle.BackgroundTransparency = 1
	middle.Parent = content

	grid = Instance.new("Frame")
	grid.Size = UDim2.new(1, 0, 1, -122)
	grid.BackgroundColor3 = Kit.Colors.Card
	grid.Parent = middle
	Kit.corner(grid, 12)
	Kit.stroke(grid)
	local layout = Instance.new("UIGridLayout")
	layout.CellSize = UDim2.new(0.25, -9, 0.5, -9)
	layout.CellPadding = UDim2.fromOffset(8, 8)
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Parent = grid
	local gridPadding = Instance.new("UIPadding")
	for _, side in { "PaddingTop", "PaddingBottom", "PaddingLeft", "PaddingRight" } do
		(gridPadding :: any)[side] = UDim.new(0, 6)
	end
	gridPadding.Parent = grid

	-- Progress bar + zone reward.
	local bar = Instance.new("Frame")
	bar.Position = UDim2.new(0, 0, 1, -112)
	bar.Size = UDim2.new(1, -110, 0, 44)
	bar.BackgroundColor3 = Color3.fromRGB(20, 25, 40)
	bar.ClipsDescendants = true
	bar.Parent = middle
	Kit.corner(bar, 10)
	Kit.stroke(bar)
	progressFill = Instance.new("Frame")
	progressFill.Size = UDim2.fromScale(0, 1)
	progressFill.BackgroundColor3 = Kit.Colors.Green
	progressFill.Parent = bar
	Kit.corner(progressFill, 10)
	progressText = Kit.label(bar, "0/8", UDim2.new(1, 0, 1, -8), UDim2.fromOffset(0, 4), Kit.Colors.Text, 3)
	progressText.TextXAlignment = Enum.TextXAlignment.Center
	zoneClaim = Kit.button(middle, "CLAIM!", Kit.Colors.Grey, UDim2.fromOffset(100, 44), UDim2.new(1, -100, 1, -112))
	zoneClaim.Activated:Connect(function()
		Net.event(Net.Names.IndexClaim):FireServer("Zone", currentZone)
	end)
	zoneRewardText = Kit.label(middle, "", UDim2.new(1, 0, 0, 22), UDim2.new(0, 0, 1, -64), Kit.Colors.SubText)

	claimAll = Kit.button(middle, "CLAIM ALL", Kit.Colors.Grey, UDim2.new(1, 0, 0, 36), UDim2.new(0, 0, 1, -38))
	claimAll.Activated:Connect(function()
		Net.event(Net.Names.IndexClaim):FireServer("All")
	end)

	-- Big preview on the right.
	preview = Instance.new("Frame")
	preview.AnchorPoint = Vector2.new(1, 0)
	preview.Position = UDim2.fromScale(1, 0)
	preview.Size = UDim2.new(0, 236, 1, 0)
	preview.BackgroundColor3 = Kit.Colors.Card
	preview.Parent = content
	Kit.corner(preview, 12)
	Kit.stroke(preview)
	local holder = Instance.new("Frame")
	holder.Name = "PictureHolder"
	holder.Size = UDim2.new(1, -20, 0, 180)
	holder.Position = UDim2.fromOffset(10, 8)
	holder.BackgroundTransparency = 1
	holder.Parent = preview
	previewName = Kit.label(preview, "", UDim2.new(1, -16, 0, 34), UDim2.fromOffset(8, 192), Kit.Colors.Text, 3)
	previewName.TextXAlignment = Enum.TextXAlignment.Center
	previewInfo = Kit.label(preview, "", UDim2.new(1, -16, 0, 56), UDim2.fromOffset(8, 228), Kit.Colors.Text, 2)
	previewInfo.TextXAlignment = Enum.TextXAlignment.Center
	previewReward = Kit.label(preview, "", UDim2.new(1, -16, 0, 26), UDim2.fromOffset(8, 290), Kit.Colors.SubText)
	previewReward.TextXAlignment = Enum.TextXAlignment.Center
	previewClaim = Kit.button(preview, "CLAIM!", Kit.Colors.Green, UDim2.new(1, -24, 0, 54), UDim2.new(0, 12, 1, -66))
	previewClaim.Activated:Connect(function()
		local fish = selected
		if fish and data.Found[fish.Name] and not data.Claimed[fish.Name] then
			Net.event(Net.Names.IndexClaim):FireServer("Fish", fish.Name)
		end
	end)

	window.Opened.Event:Connect(function()
		if not selected then
			selectZone(currentZone)
		else
			redraw()
		end
	end)
	Hud.Index.Activated:Connect(function()
		window.Toggle()
	end)
end

function IndexController.Start()
	Net.event(Net.Names.IndexSync).OnClientEvent:Connect(function(incoming: unknown)
		if typeof(incoming) ~= "table" then
			return
		end
		local raw = incoming :: any
		local newData: IndexData = { Found = {}, Claimed = {}, ZonesClaimed = {} }
		for _, field in { "Found", "Claimed" } do
			if typeof(raw[field]) == "table" then
				for _, name in raw[field] do
					if typeof(name) == "string" then
						(newData :: any)[field][name] = true
					end
				end
			end
		end
		if typeof(raw.ZonesClaimed) == "table" then
			for _, zoneIndex in raw.ZonesClaimed do
				if typeof(zoneIndex) == "number" then
					newData.ZonesClaimed[zoneIndex] = true
				end
			end
		end
		data = newData
		redraw()
	end)
	-- Ask for our data (in case it was sent before we were listening).
	Net.event(Net.Names.IndexClaim):FireServer("Sync")
end

return IndexController
