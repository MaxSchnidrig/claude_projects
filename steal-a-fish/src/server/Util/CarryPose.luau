--!strict
--[[
	CarryPose
	=========
	Raises a character's arms above the head (to carry an egg) and lowers them
	again. Works for R15 and R6 characters.

	How: the server rotates the shoulder joints (Motor6D.C0). That change is
	seen by every player. While a player carries an egg, every client also
	stops the walk animation from swinging those arms (EggController), so
	the arms stay up while the legs keep walking normally.

	Usage:
		CarryPose.set(character, true)   -- arms up
		CarryPose.set(character, false)  -- back to normal
]]

local CarryPose = {}

local ORIGINAL = "OriginalC0"

-- The shoulder joints of R15 and R6 rigs, and how to rotate each one so the
-- arm points straight up.
local function shoulders(character: Model): { { Joint: Motor6D, Raise: CFrame } }
	local result = {}
	local function add(parentName: string, jointName: string, raise: CFrame)
		local parent = character:FindFirstChild(parentName)
		local joint = parent and parent:FindFirstChild(jointName)
		if joint and joint:IsA("Motor6D") then
			table.insert(result, { Joint = joint, Raise = raise })
		end
	end
	-- R15: the arm swings around the joint's X axis.
	add("RightUpperArm", "RightShoulder", CFrame.Angles(math.pi, 0, 0))
	add("LeftUpperArm", "LeftShoulder", CFrame.Angles(math.pi, 0, 0))
	-- R6: the arm swings around the joint's Z axis.
	add("Torso", "Right Shoulder", CFrame.Angles(0, 0, math.pi))
	add("Torso", "Left Shoulder", CFrame.Angles(0, 0, math.pi))
	return result
end

function CarryPose.set(character: Model, armsUp: boolean)
	for _, entry in shoulders(character) do
		local joint = entry.Joint
		local original = joint:GetAttribute(ORIGINAL)
		if typeof(original) ~= "CFrame" then
			original = joint.C0
			joint:SetAttribute(ORIGINAL, original)
		end
		joint.C0 = if armsUp then (original :: CFrame) * entry.Raise else original :: CFrame
	end
end

return CarryPose
