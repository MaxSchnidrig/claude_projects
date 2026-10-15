--!strict
--[[
	Assets
	======
	Lets you swap the placeholder blocks for real models later, with no code
	changes.

	How it works: the game always builds a simple placeholder part (that part
	does the gameplay work: touching, standing on, and so on). Then
	Assets.decorate() looks in ReplicatedStorage.Assets for a model with the
	given name. If it finds one, it places a copy of the model on top of the
	placeholder and makes the placeholder invisible. If not, the placeholder
	stays visible.

	To use your own model: in Studio, put a Model (or Part) named, for example,
	"HatchPad" into ReplicatedStorage > Assets. Its pivot is placed at the
	center of the placeholder.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Assets = {}

-- Find an asset template by name, or nil if there isn't one.
function Assets.find(assetName: string): Instance?
	local folder = ReplicatedStorage:FindFirstChild("Assets")
	if not folder then
		return nil
	end
	local template = folder:FindFirstChild(assetName)
	if template and (template:IsA("Model") or template:IsA("BasePart")) then
		return template
	end
	return nil
end

-- If an asset named `assetName` exists, put a copy of it on `placeholder` and
-- hide the placeholder. Returns the copy, or nil if no asset was found.
function Assets.decorate(placeholder: BasePart, assetName: string): PVInstance?
	local template = Assets.find(assetName)
	if not template then
		return nil
	end

	local copy = template:Clone() :: PVInstance
	-- Decorations are only for looks: anchor them and make sure they never
	-- block players or trigger touch events.
	local parts: { Instance } = copy:GetDescendants()
	table.insert(parts, copy)
	for _, item in parts do
		if item:IsA("BasePart") then
			item.Anchored = true
			item.CanCollide = false
			item.CanTouch = false
			item.CanQuery = false
		end
	end
	copy:PivotTo(placeholder.CFrame)
	copy.Parent = placeholder
	placeholder.Transparency = 1
	return copy
end

return Assets
