--!strict
local Players = game:GetService("Players")
local UserInputService = game:GetService("UserInputService")
local Remotes = require(game:GetService("ReplicatedStorage"):WaitForChild("Shared").Net.Remotes)

local AnimalNamePrompt = {}

function AnimalNamePrompt.init()
	local remote = Remotes.get("NameAnimal")
	local activeId: number? = nil
	local dialog: ScreenGui? = nil
	local message: TextLabel? = nil
	local saving = false
	local function close()
		if dialog then dialog:Destroy() end
		dialog, activeId, message = nil, nil, nil
		saving = false
	end
	local function cancel()
		if activeId then remote:FireServer(activeId, nil) end
		close()
	end
	UserInputService.InputBegan:Connect(function(input)
		if activeId and input.KeyCode == Enum.KeyCode.Escape then cancel() end
	end)
	Players.LocalPlayer.CharacterRemoving:Connect(close)
	remote.OnClientEvent:Connect(function(action, id, text)
		if action ~= "open" then
			if id ~= activeId then return end
			if action == "close" then close()
			elseif action == "retry" and message then
				saving = false
				message.Text = text
			end
			return
		end
		close()
		activeId = id
		local gui = Instance.new("ScreenGui")
		gui.Name = "AnimalNamePrompt"
		gui.DisplayOrder = 50
		dialog = gui
		local panel = Instance.new("Frame")
		panel.AnchorPoint = Vector2.new(0.5, 0.5)
		panel.Position = UDim2.fromScale(0.5, 0.48)
		panel.Size = UDim2.fromOffset(288, 144)
		panel.BackgroundColor3 = Color3.fromRGB(43, 37, 31)
		panel.BorderColor3 = Color3.fromRGB(206, 169, 106)
		panel.BorderSizePixel = 2
		panel.Parent = gui
		local title = Instance.new("TextLabel")
		title.Position = UDim2.fromOffset(16, 8)
		title.Size = UDim2.fromOffset(256, 30)
		title.Text = "Name your " .. string.lower(text)
		title.TextXAlignment = Enum.TextXAlignment.Left
		title.BackgroundTransparency = 1
		title.Font = Enum.Font.GothamBold
		title.TextSize = 18
		title.TextColor3 = Color3.fromRGB(255, 237, 200)
		title.Parent = panel
		message = title
		local box = Instance.new("TextBox")
		box.Position = UDim2.fromOffset(16, 44)
		box.Size = UDim2.fromOffset(256, 38)
		box.BackgroundColor3 = Color3.fromRGB(250, 233, 202)
		box.TextColor3 = Color3.fromRGB(50, 37, 25)
		box.Font = Enum.Font.GothamMedium
		box.TextSize = 18
		box.Text = ""
		box.PlaceholderText = "Animal name"
		box.ClearTextOnFocus = false
		box.Parent = panel
		local function save()
			if saving or not box.Text:find("%S") then return end
			saving = true
			remote:FireServer(id, box.Text)
		end
		for index, caption in { "Cancel", "Save name" } do
			local button = Instance.new("TextButton")
			button.Text = caption
			button.Font = Enum.Font.GothamBold
			button.TextSize = 16
			button.Modal = true
			button.Size = UDim2.fromOffset(122, 34)
			button.Position = UDim2.fromOffset(16 + (index - 1) * 134, 96)
			button.BackgroundColor3 = if index == 1 then Color3.fromRGB(85, 73, 59) else Color3.fromRGB(240, 195, 113)
			button.TextColor3 = if index == 1 then Color3.new(1,1,1) else Color3.fromRGB(49, 35, 22)
			button.Parent = panel
			button.Activated:Connect(if index == 1 then cancel else save)
		end
		box.FocusLost:Connect(function(enter)
			if enter then save() end
		end)
		gui.Parent = Players.LocalPlayer:WaitForChild("PlayerGui")
		box:CaptureFocus()
	end)
end

return AnimalNamePrompt
