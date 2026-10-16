--!strict
--[[
	ZoneController
	==============
	When you walk into a danger zone, its name appears big at the top of the
	screen for a few seconds ("Kelp Forest 😐"), then fades away. The emoji
	gets scarier the deeper the zone (Config.Zones[...].Emoji).
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local Config = require(ReplicatedStorage.Shared.Config)
local Layout = require(ReplicatedStorage.Shared.Layout)
local Kit = require(script.Parent.Parent.Ui.Kit)

local ZoneController = {}
ZoneController.Name = "ZoneController"

local CHECK_INTERVAL = 0.2
local FADE_IN = 0.3
local FADE_OUT = 0.6

local player = Players.LocalPlayer
local banner: TextLabel
local bannerStroke: UIStroke
local currentZone: number? = nil
local showId = 0

local function show(zoneIndex: number)
	local zone = Config.Zones[zoneIndex]
	if not zone then
		return
	end
	showId += 1
	local myId = showId
	banner.Text = `{zone.Name} {zone.Emoji}`
	bannerStroke.Color = zone.Color:Lerp(Color3.new(0, 0, 0), 0.6)
	banner.TextTransparency = 1
	bannerStroke.Transparency = 1
	local info = TweenInfo.new(FADE_IN)
	TweenService:Create(banner, info, { TextTransparency = 0 }):Play()
	TweenService:Create(bannerStroke, info, { Transparency = 0 }):Play()
	task.delay(FADE_IN + Config.UI.ZoneBannerSeconds, function()
		if showId ~= myId then
			return -- a newer zone name is showing
		end
		local out = TweenInfo.new(FADE_OUT)
		TweenService:Create(banner, out, { TextTransparency = 1 }):Play()
		TweenService:Create(bannerStroke, out, { Transparency = 1 }):Play()
	end)
end

function ZoneController.Init()
	local gui = Kit.screenGui("ZoneBanner", 9)
	banner = Instance.new("TextLabel")
	banner.AnchorPoint = Vector2.new(0.5, 0)
	banner.Position = UDim2.new(0.5, 0, 0, 66)
	banner.Size = UDim2.fromOffset(600, 76)
	banner.BackgroundTransparency = 1
	banner.Font = Enum.Font.FredokaOne
	banner.TextScaled = true
	banner.TextColor3 = Color3.new(1, 1, 1)
	banner.TextTransparency = 1
	banner.Text = ""
	banner.Parent = gui
	bannerStroke = Kit.textStroke(banner, 5)
	bannerStroke.Transparency = 1
	Kit.autoScale(banner, Vector2.new(600, 76))
end

function ZoneController.Start()
	task.spawn(function()
		while true do
			task.wait(CHECK_INTERVAL)
			local character = player.Character
			local root = character and character:FindFirstChild("HumanoidRootPart")
			if root and root:IsA("BasePart") then
				local zoneIndex = Layout.zoneIndexAt(root.Position)
				if zoneIndex ~= currentZone then
					currentZone = zoneIndex
					if zoneIndex then
						show(zoneIndex)
					end
				end
			end
		end
	end)
end

return ZoneController
