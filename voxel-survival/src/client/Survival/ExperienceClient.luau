--!strict
-- Experience on the client (Phase 10a): the numbers the server sends (level, progress, total,
-- score) for the HUD bar and F3, the "/xp" chat command, and the orbs' look: the server's
-- XPOrbs parts (Neon balls, bigger for bigger values) get our own pulsing yellow-green glow
-- here.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local StarterGui = game:GetService("StarterGui")
local TextChatService = game:GetService("TextChatService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Remotes = require(Shared.Net.Remotes)

local ExperienceClient = {}
ExperienceClient.level = 0
ExperienceClient.progress = 0
ExperienceClient.total = 0
ExperienceClient.score = 0

local changed = Instance.new("BindableEvent")
ExperienceClient.Changed = changed.Event

local function chatCommand()
	pcall(function()
		if TextChatService.ChatVersion ~= Enum.ChatVersion.TextChatService then
			return -- the old chat: the server listens to Player.Chatted instead
		end
		local cmd = Instance.new("TextChatCommand")
		cmd.Name = "RocraftXp"
		cmd.PrimaryAlias = "/xp"
		cmd.SecondaryAlias = "/experience"
		cmd.Triggered:Connect(function(_source: TextSource, text: string)
			local words = string.split(string.lower(text), " ")
			table.remove(words, 1)
			local args = {}
			for _, w in words do
				if w ~= "" then
					table.insert(args, w)
				end
			end
			Remotes.get("XpCommand"):FireServer(args)
		end)
		cmd.Parent = TextChatService:FindFirstChild("TextChatCommands") or TextChatService
	end)
end

-- Orb look: colour pulses between yellow-green and green (10 radians a second), each orb out
-- of step with the others.
local function animateOrbs()
	local folder: Instance? = nil
	RunService.RenderStepped:Connect(function()
		if not folder or not folder.Parent then
			folder = workspace:FindFirstChild("XPOrbs")
			if not folder then
				return
			end
		end
		local t = os.clock() * 10
		for i, part in (folder :: Instance):GetChildren() do
			if part:IsA("BasePart") then
				local f = t + i * 1.7
				local r = (math.sin(f) + 1) * 0.5
				local b = (math.sin(f + 4.18879) + 1) * 0.1
				part.Color = Color3.new(0.45 + r * 0.55, 1, b)
			end
		end
	end)
end

function ExperienceClient.init()
	Remotes.get("Experience").OnClientEvent:Connect(function(m: any)
		if typeof(m) ~= "table" then
			return
		end
		if m.type == "sync" then
			ExperienceClient.level = tonumber(m.level) or 0
			ExperienceClient.progress = tonumber(m.progress) or 0
			ExperienceClient.total = tonumber(m.total) or 0
			ExperienceClient.score = tonumber(m.score) or 0
			changed:Fire()
		elseif m.type == "message" and typeof(m.text) == "string" then
			pcall(function()
				StarterGui:SetCore("SendNotification", { Title = "Experience", Text = m.text, Duration = 5 })
			end)
		end
	end)
	Remotes.get("Experience"):FireServer({ type = "hello" })
	chatCommand()
	animateOrbs()
end

return ExperienceClient
