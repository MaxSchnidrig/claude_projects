--!strict
-- Right-click uses of items on blocks (server-authoritative), Java Edition rules:
--   bucket            on a water or lava SOURCE: picks it up (a stack gives one filled bucket)
--   water/lava bucket places a source at the target cell (replacing air, flowing fluid, fire,
--                     torches); the bucket becomes empty
--   flint and steel   on TNT: lights it; on an unlit campfire: lights it; otherwise sets fire to
--                     the cell next to the clicked face if fire can stay there; 1 durability
--   shovel            on a lit campfire: puts it out
--   raw food          on a campfire: cooks it (CampfireService)
-- The client sends the clicked block and face; the server checks reach and the rules.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared.Config)
local Remotes = require(Shared.Net.Remotes)
local BlockRegistry = require(Shared.Blocks.BlockRegistry)
local ItemRegistry = require(Shared.Items.ItemRegistry)
local Fluids = require(Shared.World.Fluids)
local SneakPose = require(Shared.Gameplay.SneakPose)
local WorldService = require(script.Parent.Parent.World.WorldService)
local BlockUpdates = require(script.Parent.Parent.World.BlockUpdates)
local ItemEntityService = require(script.Parent.Parent.World.ItemEntityService)
local InventoryService = require(script.Parent.Parent.Player.InventoryService)
local EntityService = require(script.Parent.EntityService)
local FireService = require(script.Parent.FireService)
local CampfireService = require(script.Parent.CampfireService)

local BS = Config.BLOCK_SIZE
local TNT = BlockRegistry.id("tnt")
local FIRE = BlockRegistry.id("fire")
local CAMPFIRE = BlockRegistry.id("campfire")
local CAMPFIRE_UNLIT = BlockRegistry.id("campfire_unlit")
local WATER, LAVA = BlockRegistry.id("water"), BlockRegistry.id("lava")

local ItemUseService = {}
ItemUseService.stats = { uses = 0, rejected = 0 }

local function isInt(v: any): boolean
	return typeof(v) == "number" and v == v and v % 1 == 0 and math.abs(v) < 2 ^ 24
end

local function eyeOf(p: Player): Vector3?
	local c = p.Character
	local root = c and c:FindFirstChild("HumanoidRootPart") :: BasePart?
	local h = c and c:FindFirstChildOfClass("Humanoid")
	if not root or not h or h.Health <= 0 then
		return nil
	end
	return (root.Position + Vector3.new(0, SneakPose.eyeHeight(c), 0)) / BS
end

local function inReach(eye: Vector3, x: number, y: number, z: number): boolean
	local center = Vector3.new(x + 0.5, y + 0.5, z + 0.5)
	return (center - eye).Magnitude <= Config.REACH + Config.REACH_TOLERANCE + 0.87
end

-- Cells a placed fluid may take over.
local function replaceable(id: number?): boolean
	if id == nil then
		return false
	end
	if id == 0 or id == FIRE then
		return true
	end
	local f, level = Fluids.info(id)
	if f then
		return level ~= 0
	end
	local def = BlockRegistry.byId[id]
	return def ~= nil and (def.shape == "torch" or def.shape == "wall_torch")
end

-- Give a filled/empty bucket in place of one held bucket.
local function swapHeld(p: Player, newItem: string)
	local stack = InventoryService.selectedStack(p)
	if not stack then
		return
	end
	if stack.count <= 1 then
		InventoryService.replaceSelected(p, { item = newItem, count = 1 })
	else
		InventoryService.consumeSelected(p, 1)
		local left = InventoryService.add(p, newItem, 1)
		if left > 0 then
			local c = p.Character
			local root = c and c:FindFirstChild("HumanoidRootPart") :: BasePart?
			if root then
				ItemEntityService.spawn({ item = newItem, count = 1 }, root.Position)
			end
		end
	end
end

local function onUse(p: Player, a: any)
	if typeof(a) ~= "table" or not isInt(a.x) or not isInt(a.y) or not isInt(a.z)
		or not isInt(a.nx) or not isInt(a.ny) or not isInt(a.nz)
		or math.abs(a.nx) + math.abs(a.ny) + math.abs(a.nz) > 1
	then
		return
	end
	local eye = eyeOf(p)
	if not eye or not inReach(eye, a.x, a.y, a.z) then
		ItemUseService.stats.rejected += 1
		return
	end
	local stack = InventoryService.selectedStack(p)
	local item = stack and stack.item
	local def = ItemRegistry.get(item)
	local x, y, z = a.x, a.y, a.z
	local clicked = WorldService.getBlockIfLoaded(x, y, z)
	if clicked == nil then
		return
	end
	ItemUseService.stats.uses += 1

	if item == "bucket" then
		if clicked == WATER then
			BlockUpdates.set(x, y, z, 0)
			swapHeld(p, "water_bucket")
		elseif clicked == LAVA then
			BlockUpdates.set(x, y, z, 0)
			swapHeld(p, "lava_bucket")
		end
		return
	end
	if item == "water_bucket" or item == "lava_bucket" then
		-- into the clicked cell if it can be replaced, else the cell in front of the clicked face
		local tx, ty, tz = x, y, z
		if not replaceable(clicked) then
			tx, ty, tz = x + a.nx, y + a.ny, z + a.nz
		end
		if replaceable(WorldService.getBlockIfLoaded(tx, ty, tz)) and inReach(eye, tx, ty, tz) then
			local here = WorldService.getBlockIfLoaded(tx, ty, tz)
			local hdef = here and BlockRegistry.byId[here]
			if hdef and hdef.drop and (hdef.shape == "torch" or hdef.shape == "wall_torch") then
				ItemEntityService.spawn({ item = hdef.drop, count = 1 }, (Vector3.new(tx, ty, tz) + Vector3.new(0.5, 0.5, 0.5)) * BS)
			end
			BlockUpdates.set(tx, ty, tz, if item == "water_bucket" then WATER else LAVA)
			InventoryService.replaceSelected(p, { item = "bucket", count = 1 })
		end
		return
	end
	if item == "flint_and_steel" then
		local used = false
		if clicked == TNT then
			EntityService.igniteBlock(x, y, z)
			used = true
		elseif clicked == CAMPFIRE_UNLIT then
			BlockUpdates.set(x, y, z, CAMPFIRE)
			used = true
		else
			used = FireService.ignite(x + a.nx, y + a.ny, z + a.nz, 0)
		end
		if used then
			InventoryService.damageSelectedTool(p, 1)
		end
		return
	end
	if clicked == CAMPFIRE and def and def.tool and def.tool.kind == "shovel" then
		BlockUpdates.set(x, y, z, CAMPFIRE_UNLIT)
		InventoryService.damageSelectedTool(p, 1)
		return
	end
	if (clicked == CAMPFIRE or clicked == CAMPFIRE_UNLIT) and CampfireService.cookable(item) then
		if CampfireService.addItem(x, y, z, item :: string) then
			InventoryService.consumeSelected(p, 1)
		end
		return
	end
end

function ItemUseService.init()
	Remotes.get("UseItem").OnServerEvent:Connect(onUse)
end

return ItemUseService
