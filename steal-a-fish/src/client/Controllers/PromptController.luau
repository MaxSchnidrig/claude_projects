--!strict
--[[
	PromptController
	================
	Makes sure ProximityPrompts (Place Egg, Upgrade, Sell, Hatch, Unlock Pad,
	Upgrade Treadmill, Steal...) never block the camera.

	Roblox's prompts are clickable buttons by default. On a computer, when
	your mouse is over one, the button grabs the mouse and you can't drag
	the camera. So:
	  - On a computer (keyboard): prompts are NOT clickable. Use the key
	    shown on them (E, F, ...). The camera always works.
	  - On a phone/tablet (touch, no keyboard): prompts stay tappable, since
	    there is no key to press.

	This only changes how prompts behave on YOUR screen; every prompt in the
	world, also ones created later, is handled.
]]

local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")

local PromptController = {}
PromptController.Name = "PromptController"

local function tapToUse(): boolean
	return UserInputService.TouchEnabled and not UserInputService.KeyboardEnabled
end

local function setup(item: Instance)
	if item:IsA("ProximityPrompt") then
		item.ClickablePrompt = tapToUse()
	end
end

function PromptController.Init()
end

function PromptController.Start()
	Workspace.DescendantAdded:Connect(setup)
	for _, item in Workspace:GetDescendants() do
		setup(item)
	end
	-- If a keyboard gets plugged in (or removed), update every prompt.
	UserInputService:GetPropertyChangedSignal("KeyboardEnabled"):Connect(function()
		for _, item in Workspace:GetDescendants() do
			setup(item)
		end
	end)
end

return PromptController
