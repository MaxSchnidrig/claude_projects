--!strict
--[[
	CarryRig
	========
	The "arms straight up, egg on the hands" carry pose. Shared, because the
	server and every client each do one half of it:

	  SERVER  CarryRig.setRaised(character, true/false)
	          Turns the shoulders so the arms point straight up. This change
	          is copied to every player automatically.
	  CLIENT  CarryRig.holdArmsStill(character)    (every frame, after animations)
	          Stops the walk/run animation from swinging the arms, so they
	          stay straight up while the legs keep walking.

	Works with R15 and R6 characters, and with both kinds of joints Roblox
	characters can have: classic Motor6D joints and the newer
	AnimationConstraint joints. (The first version only knew Motor6D, which is
	why the arms didn't move on newer avatars.)

	CarryRig.carryHeight(character, root) -> number?
		How far above the HumanoidRootPart the hands reach with the arms up
		(nil if the character's arms can't be found).
]]

local CarryRig = {}

-- Rotation that turns a hanging arm straight up, per rig type.
local RAISE_R15 = CFrame.Angles(math.pi, 0, 0)
local RAISE_R6 = CFrame.Angles(0, 0, math.pi)
local ORIGINAL = "CarryOriginal" -- attribute: the joint's normal offset

-- Each arm part, the part it hangs from, and whether its joint is a shoulder.
type ArmPart = { Part: string, Parent: string, Shoulder: boolean }
local R15_ARM: { ArmPart } = {
	{ Part = "RightUpperArm", Parent = "UpperTorso", Shoulder = true },
	{ Part = "LeftUpperArm", Parent = "UpperTorso", Shoulder = true },
	{ Part = "RightLowerArm", Parent = "RightUpperArm", Shoulder = false },
	{ Part = "LeftLowerArm", Parent = "LeftUpperArm", Shoulder = false },
	{ Part = "RightHand", Parent = "RightLowerArm", Shoulder = false },
	{ Part = "LeftHand", Parent = "LeftLowerArm", Shoulder = false },
}
local R6_ARM: { ArmPart } = {
	{ Part = "Right Arm", Parent = "Torso", Shoulder = true },
	{ Part = "Left Arm", Parent = "Torso", Shoulder = true },
}

export type ArmJoint = {
	Joint: Motor6D | AnimationConstraint,
	Shoulder: boolean,
	Raise: CFrame,
}

-- The joint that moves `part` (it usually lives inside the part itself or
-- inside its parent part).
local function findJoint(part: Instance, parentPart: Instance?): (Motor6D | AnimationConstraint)?
	local places: { Instance } = { part }
	if parentPart then
		table.insert(places, parentPart)
	end
	for _, place in places do
		for _, item in place:GetChildren() do
			if item:IsA("Motor6D") and item.Part1 == part then
				return item
			elseif item:IsA("AnimationConstraint") then
				local attachment = item.Attachment1
				if attachment and attachment.Parent == part then
					return item
				end
			end
		end
	end
	return nil
end

function CarryRig.armJoints(character: Model): { ArmJoint }
	local result: { ArmJoint } = {}
	local isR6 = character:FindFirstChild("Torso") ~= nil and character:FindFirstChild("UpperTorso") == nil
	local list: { ArmPart } = if isR6 then R6_ARM else R15_ARM
	for _, entry in list do
		local part = character:FindFirstChild(entry.Part)
		if part then
			local joint = findJoint(part, character:FindFirstChild(entry.Parent))
			if joint then
				table.insert(result, {
					Joint = joint,
					Shoulder = entry.Shoulder,
					Raise = if isR6 then RAISE_R6 else RAISE_R15,
				})
			end
		end
	end
	return result
end

-- SERVER: arms up (true) or back to normal (false).
function CarryRig.setRaised(character: Model, raised: boolean)
	for _, arm in CarryRig.armJoints(character) do
		if not arm.Shoulder then
			continue
		end
		local joint = arm.Joint
		if joint:IsA("Motor6D") then
			local original = joint:GetAttribute(ORIGINAL)
			if typeof(original) ~= "CFrame" then
				original = joint.C0
				joint:SetAttribute(ORIGINAL, original)
			end
			joint.C0 = if raised then (original :: CFrame) * arm.Raise else original :: CFrame
		elseif joint:IsA("AnimationConstraint") then
			-- For these joints the "C0" is the CFrame of Attachment0.
			local attachment = joint.Attachment0
			if attachment then
				local original = attachment:GetAttribute(ORIGINAL)
				if typeof(original) ~= "CFrame" then
					original = attachment.CFrame
					attachment:SetAttribute(ORIGINAL, original)
				end
				attachment.CFrame = if raised then (original :: CFrame) * arm.Raise else original :: CFrame
			end
		end
	end
end

-- CLIENT: undo the animation's arm swing for this frame. Call it in
-- RunService.PreSimulation (that runs after animations, before physics).
function CarryRig.holdArmsStill(joints: { ArmJoint })
	for _, arm in joints do
		local joint = arm.Joint
		if joint:IsA("Motor6D") then
			joint.Transform = CFrame.identity
		elseif joint:IsA("AnimationConstraint") then
			joint.Transform = CFrame.identity
		end
	end
end

-- Where a shoulder joint is in the world.
local function shoulderPosition(joint: Motor6D | AnimationConstraint): Vector3?
	if joint:IsA("Motor6D") then
		local part0 = joint.Part0
		local original = joint:GetAttribute(ORIGINAL)
		local c0 = if typeof(original) == "CFrame" then original else joint.C0
		return if part0 then (part0.CFrame * c0).Position else nil
	elseif joint:IsA("AnimationConstraint") then
		local attachment = joint.Attachment0
		return if attachment then attachment.WorldPosition else nil
	end
	return nil
end

-- How high above `root` the tips of the hands are when the arms point up.
-- Measured from the real character, so it fits small and big avatars.
function CarryRig.carryHeight(character: Model, root: BasePart): number?
	local isR6 = character:FindFirstChild("Torso") ~= nil and character:FindFirstChild("UpperTorso") == nil
	local hand = character:FindFirstChild(if isR6 then "Right Arm" else "RightHand")
	if not (hand and hand:IsA("BasePart")) then
		return nil
	end
	for _, arm in CarryRig.armJoints(character) do
		if arm.Shoulder then
			local shoulder = shoulderPosition(arm.Joint)
			if shoulder then
				-- Arm length: shoulder to the middle of the hand, plus half a hand.
				local reach = (hand.Position - shoulder).Magnitude + hand.Size.Y / 2
				return root.CFrame:PointToObjectSpace(shoulder).Y + reach
			end
		end
	end
	return nil
end

return CarryRig
