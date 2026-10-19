--!strict
--[[
	ChaseController
	===============
	While a shark is chasing YOU:
	  - a red vignette pulses around the edges of the screen (about once per
	    second, faster when the shark is close), and
	  - a big shaking "RUN!!" banner sits at the top center.
	Both fade in and out smoothly when the chase starts and ends (escaped,
	caught or safe).

	How we know: the server marks the chasing shark with the attribute
	"ChasingUserId" = your UserId (BotService).
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local Kit = require(script.Parent.Parent.Ui.Kit)

local ChaseController = {}
ChaseController.Name = "ChaseController"

local FADE_SPEED = 3 -- how fast everything fades in/out (per second)
local CLOSE_DISTANCE = 40 -- studs: closer than this, the pulse speeds up
local EDGE = 0.22 -- how far the vignette reaches into the screen (fraction)
local RED = Color3.fromRGB(230, 20, 20)

local player = Players.LocalPlayer
local vignette: { Frame } = {}
local banner: Frame
local bannerStroke: UIStroke
local bannerText: TextLabel
local bannerTextStroke: UIStroke
local strength = 0 -- 0 = no effect, 1 = full effect
local pulseClock = 0

-- The shark chasing me (or nil).
local function myChaser(): Model?
	local world = Workspace:FindFirstChild("World")
	local sharks = world and world:FindFirstChild("Sharks")
	if not sharks then
		return nil
	end
	for _, shark in sharks:GetChildren() do
		if shark:IsA("Model") and shark:GetAttribute("ChasingUserId") == player.UserId then
			return shark
		end
	end
	return nil
end

-- One red edge strip that fades toward the middle of the screen.
local function edge(gui: ScreenGui, position: UDim2, size: UDim2, rotation: number)
	local frame = Instance.new("Frame")
	frame.Position = position
	frame.Size = size
	frame.BackgroundColor3 = RED
	frame.BorderSizePixel = 0
	frame.BackgroundTransparency = 1
	frame.Parent = gui
	local gradient = Instance.new("UIGradient")
	gradient.Rotation = rotation
	gradient.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0),
		NumberSequenceKeypoint.new(1, 1),
	})
	gradient.Parent = frame
	table.insert(vignette, frame)
end

function ChaseController.Init()
	local gui = Kit.screenGui("ChaseEffect", 6)
	gui.IgnoreGuiInset = true
	-- Gradient rotation 0 = fades left->right, 90 = top->bottom, etc.
	edge(gui, UDim2.fromScale(0, 0), UDim2.fromScale(EDGE, 1), 0) -- left
	edge(gui, UDim2.fromScale(1 - EDGE, 0), UDim2.fromScale(EDGE, 1), 180) -- right
	edge(gui, UDim2.fromScale(0, 0), UDim2.fromScale(1, EDGE * 1.3), 90) -- top
	edge(gui, UDim2.fromScale(0, 1 - EDGE * 1.3), UDim2.fromScale(1, EDGE * 1.3), 270) -- bottom

	-- "RUN!!" banner.
	banner = Instance.new("Frame")
	banner.AnchorPoint = Vector2.new(0.5, 0)
	banner.Position = UDim2.new(0.5, 0, 0, 70)
	banner.Size = UDim2.fromOffset(300, 84)
	banner.BackgroundColor3 = Color3.fromRGB(120, 10, 15)
	banner.BackgroundTransparency = 1
	banner.Parent = gui
	Kit.corner(banner, 16)
	bannerStroke = Kit.stroke(banner, Color3.fromRGB(255, 50, 50), 4)
	bannerStroke.Transparency = 1
	Kit.autoScale(banner, Vector2.new(300, 84))
	bannerText = Kit.label(banner, "RUN!!", UDim2.new(1, -24, 1, -12), UDim2.fromOffset(12, 6), Color3.new(1, 1, 1), 4)
	bannerText.TextXAlignment = Enum.TextXAlignment.Center
	bannerText.TextTransparency = 1
	bannerTextStroke = bannerText:FindFirstChildOfClass("UIStroke") :: UIStroke
	bannerTextStroke.Transparency = 1
end

function ChaseController.Start()
	RunService.RenderStepped:Connect(function(dt: number)
		local chaser = myChaser()
		local target = if chaser then 1 else 0
		if strength ~= target then
			strength = if target > strength then math.min(1, strength + dt * FADE_SPEED) else math.max(0, strength - dt * FADE_SPEED)
		end

		-- Pulse speed: once per second, up to ~2.5x faster when it's close.
		local speed = 1
		local character = player.Character
		local root = character and character:FindFirstChild("HumanoidRootPart")
		if chaser and root and root:IsA("BasePart") then
			local distance = (chaser:GetPivot().Position - root.Position).Magnitude
			speed = 1 + math.clamp(1 - distance / CLOSE_DISTANCE, 0, 1) * 1.5
		end
		pulseClock += dt * speed
		local pulse = 0.5 + 0.5 * math.sin(pulseClock * math.pi * 2)

		-- Vignette: stronger at the peak of each pulse.
		for _, frame in vignette do
			frame.BackgroundTransparency = 1 - strength * (0.35 + 0.35 * pulse)
		end

		-- Banner: fades with the effect, bounces with the pulse, shakes a bit.
		banner.BackgroundTransparency = 1 - strength * 0.85
		bannerStroke.Transparency = 1 - strength
		bannerText.TextTransparency = 1 - strength
		bannerTextStroke.Transparency = 1 - strength
		if strength > 0 then
			local t = os.clock()
			banner.Rotation = math.sin(t * 23) * 2.5 * strength
			banner.Position = UDim2.new(0.5, math.sin(t * 31) * 3, 0, 70 + math.cos(t * 27) * 2)
			bannerText.Size = UDim2.new(1, -24 + pulse * 10, 1, -12 + pulse * 6)
			bannerText.Position = UDim2.fromOffset(12 - pulse * 5, 6 - pulse * 3)
		end
	end)
end

return ChaseController
