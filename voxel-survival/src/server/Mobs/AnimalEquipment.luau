--!strict
local Players = game:GetService("Players")
local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local Config = require(Shared.Config)
local Blocks = require(Shared.Blocks.BlockRegistry)
local Animals = require(Shared.Mobs.Animals)
local Remotes = require(Shared.Net.Remotes)
local Inventory = require(script.Parent.Parent.Player.InventoryService)
local Items = require(script.Parent.Parent.World.ItemEntityService)
local BS = Config.BLOCK_SIZE
local Gear = {}
local function point(m)
	return Vector3.new(m.x, m.y, m.z)
end
local function anchor(m)
	if m.gearPart then return m.gearPart end
	local part = Instance.new("Part")
	part.Name = "AnimalGear_" .. m.id
	part.Anchored = true
	part.CanCollide, part.CanTouch, part.CanQuery = false, false, false
	part.Transparency = 1
	part.Size = Vector3.one * 0.1
	part.Position = point(m) * BS
	part.Parent = workspace
	m.gearPart = part
	return part
end
local function clearLead(m)
	local owner = m.leader
	m.leader, m.tie = nil, nil
	if owner then owner:SetAttribute("LeadingAnimal", math.max(0, (owner:GetAttribute("LeadingAnimal") or 1) - 1)) end
	if m.rope then m.rope:Destroy() m.rope = nil end
	if m.endPoint then m.endPoint:Destroy() m.endPoint = nil end
	if m.post then m.post:Destroy() m.post = nil end
end
local function leadEnd(m, target)
	local part = anchor(m)
	local start = part:FindFirstChildOfClass("Attachment") or Instance.new("Attachment", part)
	local finish = Instance.new("Attachment", target)
	local rope = Instance.new("Beam")
	rope.Attachment0, rope.Attachment1 = start, finish
	rope.Width0, rope.Width1 = 0.09, 0.09
	rope.FaceCamera = true
	rope.Color = ColorSequence.new(Color3.fromRGB(143, 98, 61))
	rope.Parent = part
	m.rope, m.endPoint = rope, finish
end
local function detach(m)
	clearLead(m)
	Items.spawn({ item = "lead", count = 1 }, point(m) * BS)
end
function Gear.remove(m)
	if m.leader then detach(m) else clearLead(m) end
	if m.gearPart then m.gearPart:Destroy() end
end
function Gear.use(m, p, item)
	if not Animals.isAnimal(m.def.key) then return false end
	if (m.leader == p or m.tie) and (not item or item == "lead") then
		detach(m)
	elseif item == "lead" and not m.leader and not m.tie then
		if Inventory.consumeSelected(p, 1) then
			m.leader = p
			p:SetAttribute("LeadingAnimal", (p:GetAttribute("LeadingAnimal") or 0) + 1)
			leadEnd(m, p.Character.HumanoidRootPart)
		end
	elseif m.def.key == "pig" and m.age >= 0 and item == "saddle" and not m.saddled then
		m.saddled = Inventory.consumeSelected(p, 1)
	elseif m.seat and not item and not m.seat.Occupant then
		m.seat:Sit(p.Character:FindFirstChildOfClass("Humanoid"))
	else
		return false
	end
	return true
end
function Gear.step(m, blockAt)
	if not (m.animalName or m.saddled or m.gearPart or m.tie) then return end
	local part = anchor(m)
	part.CFrame = CFrame.new((point(m) + Vector3.yAxis * m.def.height * (if m.age < 0 then 0.5 else 1)) * BS) * CFrame.Angles(0,m.yaw,0)
	if m.animalName then
		local gui = part:FindFirstChildOfClass("BillboardGui")
		if not gui then
			gui = Instance.new("BillboardGui")
			gui.Size = UDim2.fromOffset(320, 40)
			gui.LightInfluence = 0
			gui.StudsOffsetWorldSpace = Vector3.yAxis * 1.5
			gui.MaxDistance = 15 * BS
			local label = Instance.new("TextLabel")
			label.Size = UDim2.fromScale(1,1)
			label.BackgroundTransparency = 1
			label.Font = Enum.Font.GothamBold
			label.TextScaled = true
			label.TextColor3 = Color3.fromRGB(255, 247, 221)
			label.TextStrokeColor3 = Color3.fromRGB(38, 31, 25)
			label.TextStrokeTransparency = 0.12
			local size = Instance.new("UITextSizeConstraint")
			size.MinTextSize = 11
			size.MaxTextSize = 27
			size.Parent = label
			label.Parent = gui
			gui.Parent = part
		end
		gui.TextLabel.Text = m.animalName
	end
	if m.saddled then
		if not m.seat then
			local seat = Instance.new("Seat")
			seat.Name = "PigSaddle"
			seat.Anchored = true
			seat.CanCollide, seat.CanTouch, seat.CanQuery = false, false, false
			seat.Size = Vector3.new(0.65,0.12,0.6) * BS
			seat.Color = Color3.fromRGB(144,77,43)
			local rider: Model? = nil
			local function updateRider()
				if rider then rider:SetAttribute("RidingPig", nil) end
				rider = if seat.Occupant then seat.Occupant.Parent :: Model else nil
				if rider then rider:SetAttribute("RidingPig", true) end
			end
			seat:GetPropertyChangedSignal("Occupant"):Connect(updateRider)
			seat.Destroying:Connect(function()
				if rider then rider:SetAttribute("RidingPig", nil) end
			end)
			seat.Parent = part
			m.seat = seat
		end
		m.seat.CFrame = part.CFrame
	end
	local target
	if m.leader then
		local c = m.leader.Character
		local root = c and c:FindFirstChild("HumanoidRootPart")
		local h = c and c:FindFirstChildOfClass("Humanoid")
		if not root or not h or h.Health <= 0 or m.leader.Parent ~= Players then detach(m) return end
		target = root.Position / BS
	elseif m.tie then
		local t = m.tie
		local id = blockAt(t.X,t.Y,t.Z)
		if id == nil then return end
		if not Blocks.byId[id] or Blocks.byId[id].shape ~= "fence" then detach(m) return end
		target = t + Vector3.one * 0.5
		if not m.rope then
			local post = Instance.new("Part")
			post.Anchored, post.CanCollide, post.CanQuery, post.CanTouch = true,false,false,false
			post.Size = Vector3.one * 0.18 * BS
			post.Color = Color3.fromRGB(143,98,61)
			post.Position = target * BS
			post.Parent = part
			m.post = post
			leadEnd(m, post)
		end
	end
	if target then
		local delta = target - point(m)
		if delta.Magnitude > 10 then detach(m)
		elseif delta.Magnitude > 2 then
			m.wantX, m.wantZ = delta.Unit.X * 3, delta.Unit.Z * 3
			m.yaw = math.atan2(-delta.X,-delta.Z)
			m.wantJump = m.hitWall
		end
	end
end
function Gear.init(service)
	Remotes.get("TieLead").OnServerEvent:Connect(function(p,pos)
		local root = p.Character and p.Character:FindFirstChild("HumanoidRootPart")
		if typeof(pos) ~= "Vector3" or not root or not ((pos * BS - root.Position).Magnitude <= 6 * BS) then return end
		if pos.X % 1 ~= 0 or pos.Y % 1 ~= 0 or pos.Z % 1 ~= 0 then return end
		local id = service.blockAt(pos.X,pos.Y,pos.Z)
		if not id or not Blocks.byId[id] or Blocks.byId[id].shape ~= "fence" then return end
		for _, m in service.mobs do
			if m.leader == p and (point(m)-pos).Magnitude <= 10 then
				clearLead(m)
				m.tie = pos
			end
		end
	end)
end
return Gear
