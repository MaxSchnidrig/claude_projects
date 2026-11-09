--!strict
-- Armour, shields, bows and crossbows (Phase 8c), with Java values.
--
-- Armour: worn pieces add up their armour points and toughness; damage that armour applies to
-- (SurvivalService opts.armor) is cut by Combat.armorReduce, and every piece loses
-- max(1, damage / 4) durability. Pieces show on the character (our own blocky designs).
--
-- Shield (main or off hand): hold right-click; after 5 ticks it blocks all damage from in front
-- (attacks, arrows, explosions). Hits of 3+ cost the shield 1 + floor(damage) durability.
--
-- Bow: hold to draw (power from Combat.bowPower), release to shoot one arrow at power x 3
-- blocks/tick; full power shoots a critical arrow. Crossbow: hold 25 ticks and release to load
-- (uses the arrow), then right-click to fire a critical arrow at 3.15 blocks/tick.
-- Both use 1 durability per shot. Player arrows stuck in the ground can be picked up.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared.Config)
local Remotes = require(Shared.Net.Remotes)
local ItemRegistry = require(Shared.Items.ItemRegistry)
local Combat = require(Shared.Gameplay.Combat)
local SneakPose = require(Shared.Gameplay.SneakPose)
local InventoryService = require(script.Parent.InventoryService)
local SurvivalService = require(script.Parent.Parent.Survival.SurvivalService)

local BS = Config.BLOCK_SIZE
local CombatGearService = {}

type Use = { kind: string, since: number }
local using: { [Player]: Use } = {}
local MobService: any = nil

local function rootOf(p: Player): BasePart?
	local c = p.Character
	return c and c:FindFirstChild("HumanoidRootPart") :: BasePart?
end

-- Armour ----------------------------------------------------------------------------------------

local function armorTotals(p: Player): (number, number)
	local defense, toughness = 0, 0
	for _, s in InventoryService.armor(p) do
		local def = s and ItemRegistry.get(s.item)
		if def and def.armor then
			defense += def.armor.defense
			toughness += def.armor.toughness
		end
	end
	return defense, toughness
end
CombatGearService.armorTotals = armorTotals

local MATERIAL_LOOK: { [string]: { Color3 | Enum.Material } } = {
	leather = { Color3.fromRGB(150, 96, 56), Enum.Material.Fabric },
	chainmail = { Color3.fromRGB(150, 152, 160), Enum.Material.DiamondPlate },
	iron = { Color3.fromRGB(214, 214, 218), Enum.Material.Metal },
	golden = { Color3.fromRGB(246, 206, 60), Enum.Material.Metal },
	diamond = { Color3.fromRGB(96, 220, 220), Enum.Material.SmoothPlastic },
}

-- Our own blocky armour: a slightly bigger box over each covered body part.
local PIECES: { [string]: { { part: string, size: Vector3, offset: Vector3 } } } = {
	head = { { part = "Head", size = Vector3.new(1.25, 1.25, 1.25), offset = Vector3.new(0, 0.08, 0) } },
	chest = {
		{ part = "Torso", size = Vector3.new(2.15, 2.1, 1.15), offset = Vector3.zero },
		{ part = "Left Arm", size = Vector3.new(1.12, 1.0, 1.12), offset = Vector3.new(0, 0.5, 0) },
		{ part = "Right Arm", size = Vector3.new(1.12, 1.0, 1.12), offset = Vector3.new(0, 0.5, 0) },
	},
	legs = {
		{ part = "Left Leg", size = Vector3.new(1.1, 1.3, 1.1), offset = Vector3.new(0, 0.35, 0) },
		{ part = "Right Leg", size = Vector3.new(1.1, 1.3, 1.1), offset = Vector3.new(0, 0.35, 0) },
	},
	feet = {
		{ part = "Left Leg", size = Vector3.new(1.14, 0.7, 1.14), offset = Vector3.new(0, -0.66, 0) },
		{ part = "Right Leg", size = Vector3.new(1.14, 0.7, 1.14), offset = Vector3.new(0, -0.66, 0) },
	},
}
local SLOT_NAMES = { "head", "chest", "legs", "feet" }

local function attach(character: Model, folder: Folder, partName: string, size: Vector3, offset: CFrame, color: Color3, material: Enum.Material)
	local body = character:FindFirstChild(partName) :: BasePart?
	if not body then
		return
	end
	local p = Instance.new("Part")
	p.Name = partName .. "Armor"
	p.Size = size
	p.Color = color
	p.Material = material
	p.CanCollide = false
	p.CanQuery = false
	p.CanTouch = false
	p.Massless = true
	p.CastShadow = false
	p.CFrame = body.CFrame * offset
	local w = Instance.new("WeldConstraint")
	w.Part0 = body
	w.Part1 = p
	w.Parent = p
	p.Parent = folder
end

local function refreshLook(p: Player)
	local character = p.Character
	if not character then
		return
	end
	local old = character:FindFirstChild("RocraftGear")
	if old then
		old:Destroy()
	end
	local folder = Instance.new("Folder")
	folder.Name = "RocraftGear"
	for i, s in InventoryService.armor(p) do
		local def = s and ItemRegistry.get(s.item)
		if def and def.armor then
			local look = MATERIAL_LOOK[def.armor.material] or MATERIAL_LOOK.iron
			for _, piece in PIECES[SLOT_NAMES[i]] do
				attach(character, folder, piece.part, piece.size, CFrame.new(piece.offset), look[1] :: Color3, look[2] :: Enum.Material)
			end
		end
	end
	-- a shield in the off hand hangs on the left arm (our own design: planks with an iron band)
	local off = InventoryService.offhand(p)
	if off and off.item == "shield" then
		attach(character, folder, "Left Arm", Vector3.new(0.2, 1.9, 1.4), CFrame.new(-0.62, -0.2, 0), Color3.fromRGB(140, 104, 64), Enum.Material.Wood)
	end
	folder.Parent = character
end

-- Shield ----------------------------------------------------------------------------------------

-- The hand holding a shield that is in use (slot index), or nil.
local function shieldSlot(p: Player): number?
	local u = using[p]
	if not u or u.kind ~= "shield" or os.clock() - u.since < 0.25 then
		return nil -- Java: the shield works 5 ticks after raising it
	end
	local held = InventoryService.selectedStack(p)
	if held and held.item == "shield" then
		return InventoryService.selectedSlot(p)
	end
	local off = InventoryService.offhand(p)
	if off and off.item == "shield" then
		return Config.OFFHAND_SLOT
	end
	return nil
end

local function block(p: Player, amount: number, opts: SurvivalService.DamageOpts): boolean
	local slot = shieldSlot(p)
	local root = rootOf(p)
	local src = opts.source
	if not slot or not root or not src then
		return false
	end
	local look = root.CFrame.LookVector
	local pos = root.Position / BS
	if not Combat.shieldBlocks(look.X, look.Z, pos.X, pos.Z, src.X, src.Z) then
		return false
	end
	if amount >= 3 then
		if InventoryService.damageSlot(p, slot, 1 + math.floor(amount)) then
			using[p] = nil -- broke
		end
	end
	return true
end

local function armor(p: Player, dealt: number): number
	local defense, toughness = armorTotals(p)
	if defense <= 0 then
		return dealt
	end
	InventoryService.damageArmor(p, dealt)
	return Combat.armorReduce(dealt, defense, toughness)
end

-- Bows and crossbows ----------------------------------------------------------------------------

local function eyeOf(p: Player): Vector3?
	local root = rootOf(p)
	if not root then
		return nil
	end
	return (root.Position + Vector3.new(0, SneakPose.eyeHeight(root.Parent), 0)) / BS
end

local function gaussian(): number
	local u1, u2 = math.max(math.random(), 1e-9), math.random()
	return math.sqrt(-2 * math.log(u1)) * math.cos(2 * math.pi * u2)
end

-- Java Projectile.shoot: direction + gaussian spread (0.0075 x inaccuracy), times speed.
local function shoot(p: Player, look: Vector3, speedPerTick: number, crit: boolean)
	local eye = eyeOf(p)
	if not eye or not MobService then
		return
	end
	local d = look.Unit
	d = (d + Vector3.new(gaussian(), gaussian(), gaussian()) * 0.0075).Unit
	MobService.shootArrow(eye - Vector3.new(0, 0.1, 0) + d * 0.3, d * speedPerTick * 20, Combat.ARROW_DAMAGE,
		p.DisplayName, nil, { player = p, crit = crit, pickup = true })
end

local function validLook(v: any): Vector3?
	if typeof(v) ~= "Vector3" or v ~= v or v.Magnitude < 0.5 or v.Magnitude > 1.5 then
		return nil
	end
	return v.Unit
end

local function onGear(p: Player, m: any)
	if typeof(m) ~= "table" then
		return
	end
	local held = InventoryService.selectedStack(p)
	local item = held and held.item
	if m.type == "shield" then
		local off = InventoryService.offhand(p)
		local has = item == "shield" or (off ~= nil and off.item == "shield")
		if m.on == true and has then
			using[p] = { kind = "shield", since = os.clock() }
		elseif using[p] and using[p].kind == "shield" then
			using[p] = nil
		end
	elseif m.type == "draw" then
		if (item == "bow" or item == "crossbow") and InventoryService.has(p, "arrow") then
			using[p] = { kind = item :: string, since = os.clock() }
		end
	elseif m.type == "release" then
		local u = using[p]
		using[p] = nil
		local look = validLook(m.look)
		if not u or not look or u.kind ~= item then
			return
		end
		-- the client counts the draw too; a little network slack
		local ticks = (os.clock() - u.since) * 20 + 2
		if item == "bow" then
			local power = Combat.bowPower(ticks)
			if power < 0.1 or not InventoryService.takeOne(p, "arrow") then
				return
			end
			InventoryService.damageSlot(p, InventoryService.selectedSlot(p), 1)
			shoot(p, look, power * Combat.BOW_SPEED, power >= 1)
		elseif item == "crossbow" and ticks >= Combat.CROSSBOW_CHARGE_TICKS then
			if InventoryService.takeOne(p, "arrow") then
				local s = InventoryService.selectedStack(p)
				if s and s.item == "crossbow" then
					InventoryService.setSlot(p, InventoryService.selectedSlot(p), { item = "crossbow_loaded", count = 1, durability = s.durability })
				end
			end
		end
	elseif m.type == "fire" then
		local look = validLook(m.look)
		if item ~= "crossbow_loaded" or not look or not held then
			return
		end
		local slot = InventoryService.selectedSlot(p)
		InventoryService.setSlot(p, slot, { item = "crossbow", count = 1, durability = held.durability })
		InventoryService.damageSlot(p, slot, 1)
		shoot(p, look, Combat.CROSSBOW_SPEED, true) -- Java: crossbow arrows are always critical
	end
end

function CombatGearService.isBlocking(p: Player): boolean
	return shieldSlot(p) ~= nil
end

function CombatGearService.init()
	MobService = require(script.Parent.Parent.Mobs.MobService)
	SurvivalService.setGear({ block = block, armor = armor })
	InventoryService.onArmorChanged(refreshLook)
	Remotes.get("Gear").OnServerEvent:Connect(onGear)
	-- arrows shot by players can be picked up again once they're in the ground
	MobService.setArrowPickup(function(p: Player): boolean
		return InventoryService.add(p, "arrow", 1) == 0
	end)
	local function onCharacter(p: Player)
		p.CharacterAdded:Connect(function(character)
			character:WaitForChild("HumanoidRootPart", 10)
			using[p] = nil
			refreshLook(p)
		end)
		if p.Character then
			task.spawn(refreshLook, p)
		end
	end
	for _, p in Players:GetPlayers() do
		onCharacter(p)
	end
	Players.PlayerAdded:Connect(onCharacter)
	Players.PlayerRemoving:Connect(function(p)
		using[p] = nil
	end)
end

return CombatGearService
