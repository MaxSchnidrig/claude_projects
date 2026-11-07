--!strict
-- Sneaking pose and collision for the R6 avatar (Roblox-only; used by client and server).
--
-- Pose: the torso leans forward 0.5 rad about its bottom edge (RootJoint), the legs are counter-
-- rotated so they stay upright (hips). The server sets the same C0s so every player sees it; the
-- owner sets them at once locally.
--
-- Collision (owner only, physics is client-side): while crouched the visual body parts are moved
-- to the GHOST collision group and a single box from the feet+2 to the feet+4.5 studs collides
-- instead: with the legs' 2-stud hover that makes the body 4.5 studs = 1.5 blocks tall (Java's
-- sneaking height), so you fit under 1.5-block gaps.

local Config = require(script.Parent.Parent.Config)

local SneakPose = {}

-- Eye height (studs above the root) the server uses for reach and sight checks.
function SneakPose.eyeHeight(character: Instance?): number
	if character and character:GetAttribute("Sneaking") == true then
		return Config.EYE_HEIGHT_SNEAK
	end
	return Config.EYE_HEIGHT
end

SneakPose.LEAN = 0.5
SneakPose.GHOST_GROUP = "RocraftGhost"
SneakPose.CAP_NAME = "SneakCollider"

local function base(motor: Motor6D): CFrame
	local b = motor:GetAttribute("BaseC0")
	if typeof(b) == "CFrame" then
		return b
	end
	motor:SetAttribute("BaseC0", motor.C0)
	return motor.C0
end

-- Record the standing C0s (call once when the character spawns, before any sneaking).
function SneakPose.remember(character: Model)
	for _, d in character:GetDescendants() do
		if d:IsA("Motor6D") then
			base(d)
		end
	end
end

function SneakPose.apply(character: Model, on: boolean)
	local root = character:FindFirstChild("HumanoidRootPart")
	local torso = character:FindFirstChild("Torso")
	local rootJoint = root and root:FindFirstChild("RootJoint")
	if rootJoint and rootJoint:IsA("Motor6D") then
		local b = base(rootJoint)
		rootJoint.C0 = if on
			then CFrame.new(0, -1, 0) * CFrame.Angles(-SneakPose.LEAN, 0, 0) * CFrame.new(0, 1, 0) * b
			else b
	end
	if torso then
		for _, name in { "Right Hip", "Left Hip" } do
			local hip = torso:FindFirstChild(name)
			if hip and hip:IsA("Motor6D") then
				local b = base(hip)
				local p = b.Position
				hip.C0 = if on then CFrame.new(p) * CFrame.Angles(SneakPose.LEAN, 0, 0) * CFrame.new(-p) * b else b
			end
		end
	end
end

-- Owner side: switch the collision shape (see header).
function SneakPose.setCollision(character: Model, on: boolean)
	local root = character:FindFirstChild("HumanoidRootPart") :: BasePart?
	if not root then
		return
	end
	local cap = root:FindFirstChild(SneakPose.CAP_NAME) :: BasePart?
	if not cap then
		local p = Instance.new("Part")
		p.Name = SneakPose.CAP_NAME
		p.Size = Vector3.new(2, 2.5, 1)
		p.Transparency = 1
		p.Massless = true
		p.CanQuery = false
		p.CanTouch = false
		p.CastShadow = false
		p.CanCollide = false
		-- root centre is 3 studs above the feet: the box spans feet+2 .. feet+4.5
		p.CFrame = root.CFrame * CFrame.new(0, 0.25, 0)
		local weld = Instance.new("WeldConstraint")
		weld.Part0 = root
		weld.Part1 = p
		weld.Parent = p
		p.Parent = root
		cap = p
	end
	(cap :: BasePart).CanCollide = on
	for _, name in { "Head", "Torso", "HumanoidRootPart" } do
		local part = character:FindFirstChild(name)
		if part and part:IsA("BasePart") then
			pcall(function()
				part.CollisionGroup = if on then SneakPose.GHOST_GROUP else "Default"
			end)
		end
	end
end

return SneakPose
