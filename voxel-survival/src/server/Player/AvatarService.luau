--!strict
-- Builds every player's character as a blocky R6 rig:
--   * default R6 limbs (plain boxes) instead of any body-part package or R15 mesh
--   * a cube head (the R6 head mesh switched to a box)
--   * the player's own clothing (Shirt/Pants/T-shirt), body colours and face are kept
--   * accessories removed unless Config.KEEP_ACCESSORIES (they'd clip through blocks)
-- R6 has no body scaling, so every character has the same 5-stud-tall, 2-stud-wide hitbox:
-- fits 2-block (6 stud) gaps and 1-block (3 stud) wide gaps, never 1-block-tall gaps.
--
-- The character is created with Players:CreateHumanoidModelFromDescription(desc, R6), so this
-- works regardless of the place's Avatar settings. If that fails, it falls back to LoadCharacter.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared.Config)

local AvatarService = {}

local ACCESSORY_FIELDS = {
	"HatAccessory", "HairAccessory", "FaceAccessory", "NeckAccessory",
	"ShouldersAccessory", "FrontAccessory", "BackAccessory", "WaistAccessory",
}
local BODY_PART_FIELDS = { "Head", "Torso", "LeftArm", "RightArm", "LeftLeg", "RightLeg" }

local function description(player: Player): HumanoidDescription
	local desc: HumanoidDescription? = nil
	if player.UserId > 0 then
		local ok, result = pcall(function()
			return Players:GetHumanoidDescriptionFromUserId(player.UserId)
		end)
		if ok then
			desc = result
		end
	end
	local d = desc or Instance.new("HumanoidDescription")
	-- Plain blocky limbs: no body-part packages.
	for _, field in BODY_PART_FIELDS do
		(d :: any)[field] = 0
	end
	if not Config.KEEP_ACCESSORIES then
		for _, field in ACCESSORY_FIELDS do
			(d :: any)[field] = ""
		end
		pcall(function()
			d:SetAccessories({}, true) -- also clears layered clothing entries
		end)
	end
	return d
end

-- Turn the R6 head into a cube and remove anything that would un-block the silhouette.
local function blockify(model: Model)
	for _, obj in model:GetDescendants() do
		if obj:IsA("CharacterMesh") then
			obj:Destroy()
		elseif obj:IsA("Accessory") and not Config.KEEP_ACCESSORIES then
			obj:Destroy()
		end
	end
	local head = model:FindFirstChild("Head") :: BasePart?
	if head then
		local mesh = head:FindFirstChildOfClass("SpecialMesh")
		if not mesh then
			mesh = Instance.new("SpecialMesh")
			mesh.Parent = head
		end
		local s = Config.AVATAR_HEAD_SIZE
		local m = mesh :: SpecialMesh
		m.MeshType = Enum.MeshType.Brick
		-- Brick mesh renders a box of (part size x scale); R6 head part is 2 x 1 x 1.
		m.Scale = Vector3.new(s / head.Size.X, s / head.Size.Y, s / head.Size.Z)
	end
end

-- Spawn (or respawn) the player's character at `cframe`.
function AvatarService.spawn(player: Player, cframe: CFrame)
	if not player.Parent then
		return
	end
	local ok, model = pcall(function()
		return Players:CreateHumanoidModelFromDescription(description(player), Enum.HumanoidRigType.R6)
	end)
	if not ok or not model then
		warn(`[AvatarService] R6 build failed for {player.Name} ({model}); using LoadCharacter`)
		player:LoadCharacter()
		if player.Character then
			player.Character:PivotTo(cframe)
		end
		return
	end
	local character = model :: Model
	character.Name = player.Name
	blockify(character)
	if not character:FindFirstChild("Animate") then
		warn("[AvatarService] generated character has no Animate script; it will not animate")
	end
	character:PivotTo(cframe)
	-- Assigning player.Character manually doesn't clean up the old body (LoadCharacter would).
	local old = player.Character
	player.Character = character
	if old and old ~= character then
		old:Destroy()
	end
	character.Parent = workspace
end

-- Movement settings applied to every character (server-side defaults; the client's
-- MovementController handles sprinting).
function AvatarService.configureHumanoid(humanoid: Humanoid)
	humanoid.UseJumpPower = false
	humanoid.JumpHeight = Config.JUMP_HEIGHT
	humanoid.WalkSpeed = Config.WALK_SPEED
	humanoid.AutoRotate = false -- the camera controller turns the body to face where you look
	humanoid:SetStateEnabled(Enum.HumanoidStateType.Climbing, false) -- no climbing block walls
end

return AvatarService
