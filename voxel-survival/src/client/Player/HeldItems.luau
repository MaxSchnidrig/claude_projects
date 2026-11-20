--!strict
-- Items in players' hands as seen from outside (third person, and every other player): the
-- server puts each character's held items in the attributes "HeldItem" (right hand) and
-- "HeldOff" (left hand, Java's off hand); this module welds the item's 3D mesh
-- (Render/ItemMeshes) to the matching arm:
--   flat items   seen side-on like Java: the icon's handle in the fist, the tip pointing forward
--   blocks       a small block held in front of the fist
-- Your own held item is hidden in first person (the ViewModel shows it there instead).
-- Placement on the arm is an estimate for our R6 rig.

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

local ItemMeshes = require(script.Parent.Parent.Render.ItemMeshes)
local CameraController = require(script.Parent.CameraController)

local HeldItems = {}
HeldItems.stats = { shown = 0 }

local Grip = require(script.Parent.ItemGrip)
local Glint = require(script.Parent.Parent.UI.Glint)

type Slot = { key: string, part: BasePart?, final: boolean }
type Rig = { character: Model, right: Slot, left: Slot }

local rigs: { [Model]: Rig } = {}
local holder: Folder

local function setSlot(rig: Rig, slot: Slot, key: string, armName: string)
	if slot.part then
		(slot.part :: BasePart):Destroy()
		slot.part = nil
	end
	slot.key = key
	slot.final = key == ""
	if key == "" then
		return
	end
	local arm = rig.character:FindFirstChild(armName) :: BasePart?
	if not arm then
		return
	end
	local scale = arm.Size.Y / 2
	local part, final = Grip.make(key, scale)
	part.Anchored = false
	part.Massless = true
	part.CanCollide = false
	part.CastShadow = true
	part.Name = "Held_" .. armName
	local weld = Instance.new("Weld")
	weld.Part0 = arm
	weld.Part1 = part
	weld.C0 = CFrame.new(0,-0.39 * arm.Size.Y,-0.46 * arm.Size.Z) * Grip.offset(key, scale, armName == "Left Arm")
	weld.Parent = part
	part.Parent = holder
	slot.part = part
	slot.final = final
end

local function track(character: Model)
	if rigs[character] then
		return
	end
	local rig: Rig = {
		character = character,
		right = { key = "", part = nil, final = true },
		left = { key = "", part = nil, final = true },
	}
	rigs[character] = rig
	character.AncestryChanged:Connect(function()
		if not character.Parent then
			for _, s in { rig.right, rig.left } do
				if s.part then
					(s.part :: BasePart):Destroy()
				end
			end
			rigs[character] = nil
		end
	end)
end

local function watch(player: Player)
	if player.Character then
		track(player.Character)
	end
	player.CharacterAdded:Connect(track)
end

function HeldItems.init()
	holder = Instance.new("Folder")
	holder.Name = "HeldItems"
	holder.Parent = workspace
	for _, p in Players:GetPlayers() do
		watch(p)
	end
	Players.PlayerAdded:Connect(watch)

	RunService.RenderStepped:Connect(function()
		local me = Players.LocalPlayer.Character
		local firstPerson = CameraController.mode == "first"
		local shown = 0
		for character, rig in rigs do
			local main = character:GetAttribute("HeldItem")
			local off = character:GetAttribute("HeldOff")
			main = if typeof(main) == "string" then main else ""
			off = if typeof(off) == "string" then off else ""
			if main ~= rig.right.key or (not rig.right.final and ItemMeshes.get(main :: string)) then
				setSlot(rig, rig.right, main :: string, "Right Arm")
			end
			if off ~= rig.left.key or (not rig.left.final and ItemMeshes.get(off :: string)) then
				setSlot(rig, rig.left, off :: string, "Left Arm")
			end
			-- your own items: hidden in first person; everyone's hidden with an invisible body
			-- (spectators)
			local head = character:FindFirstChild("Head") :: BasePart?
			local hidden = (character == me and firstPerson) or (head ~= nil and head.Transparency >= 1)
			Glint.sync(rig.right.part, not hidden and character:GetAttribute("HeldGlint") == true)
			Glint.sync(rig.left.part, not hidden and character:GetAttribute("HeldOffGlint") == true)
			for _, s in { rig.right, rig.left } do
				local p = s.part
				if p then
					p.LocalTransparencyModifier = if hidden then 1 else 0
					if not hidden then
						shown += 1
					end
				end
			end
		end
		HeldItems.stats.shown = shown
	end)
end

return HeldItems
