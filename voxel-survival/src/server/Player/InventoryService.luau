--!strict
-- Server-authoritative player inventory (phase 2 subset: storage, stacking, hotbar selection,
-- tool durability). Clients only ever see copies via InventorySync.
--
-- Slots 1..9 are the hotbar, 10..36 the main inventory (its UI arrives in phase 3).

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared.Config)
local Remotes = require(Shared.Net.Remotes)
local ItemRegistry = require(Shared.Items.ItemRegistry)

export type Stack = { item: string, count: number, durability: number? }
type Inv = { slots: { [number]: Stack? }, selected: number, dirty: boolean }

local N = Config.INVENTORY_SLOTS
local InventoryService = {}
local invs: { [Player]: Inv } = {}

local function inv(player: Player): Inv
	local i = invs[player]
	if not i then
		i = { slots = {}, selected = 1, dirty = true }
		invs[player] = i
	end
	return i
end

local function newStack(item: string, count: number): Stack
	local def = ItemRegistry.get(item)
	local s: Stack = { item = item, count = count }
	if def and def.tool then
		s.durability = def.tool.durability
	end
	return s
end

-- Add items; fills existing stacks first (hotbar first), then empty slots. Returns leftover.
function InventoryService.add(player: Player, item: string, count: number): number
	local def = ItemRegistry.get(item)
	if not def or count <= 0 then
		return count
	end
	local i = inv(player)
	local left = count
	for slot = 1, N do
		local s = i.slots[slot]
		if s and s.item == item and s.count < def.stack then
			local n = math.min(def.stack - s.count, left)
			s.count += n
			left -= n
			if left == 0 then
				break
			end
		end
	end
	for slot = 1, N do
		if left == 0 then
			break
		end
		if not i.slots[slot] then
			local n = math.min(def.stack, left)
			i.slots[slot] = newStack(item, n)
			left -= n
		end
	end
	if left ~= count then
		i.dirty = true
	end
	return left -- phase 3: leftover becomes a dropped item entity
end

function InventoryService.selectedSlot(player: Player): number
	return inv(player).selected
end

function InventoryService.selectedStack(player: Player): Stack?
	local i = inv(player)
	return i.slots[i.selected]
end

-- Remove `n` items from the selected slot. Returns false if not enough.
function InventoryService.consumeSelected(player: Player, n: number): boolean
	local i = inv(player)
	local s = i.slots[i.selected]
	if not s or s.count < n then
		return false
	end
	s.count -= n
	if s.count <= 0 then
		i.slots[i.selected] = nil
	end
	i.dirty = true
	return true
end

-- Wear the selected tool by `n`; removes it when it breaks.
function InventoryService.damageSelectedTool(player: Player, n: number)
	local i = inv(player)
	local s = i.slots[i.selected]
	if not s or s.durability == nil then
		return
	end
	s.durability -= n
	if (s.durability :: number) <= 0 then
		i.slots[i.selected] = nil -- phase 7: break sound
	end
	i.dirty = true
end

local function sync(player: Player)
	local i = inv(player)
	i.dirty = false
	-- Remote arrays can't contain nil holes, so empty slots are sent as false.
	local out = table.create(N)
	for slot = 1, N do
		local s = i.slots[slot]
		out[slot] = if s then { item = s.item, count = s.count, durability = s.durability } else false
	end
	Remotes.get("InventorySync"):FireClient(player, { slots = out, selected = i.selected })
end

function InventoryService.init()
	Remotes.get("SelectSlot").OnServerEvent:Connect(function(player: Player, n: any)
		if typeof(n) ~= "number" or n % 1 ~= 0 or n < 1 or n > Config.HOTBAR_SLOTS then
			return
		end
		local i = inv(player)
		if i.selected ~= n then
			i.selected = n
			-- no sync needed: the client already shows its own selection
		end
	end)

	local function onPlayer(player: Player)
		inv(player)
		if RunService:IsStudio() then
			for _, entry in Config.STUDIO_STARTER_KIT do
				InventoryService.add(player, entry[1], entry[2])
			end
		end
	end
	Players.PlayerAdded:Connect(onPlayer)
	for _, player in Players:GetPlayers() do
		onPlayer(player)
	end
	Players.PlayerRemoving:Connect(function(player)
		invs[player] = nil -- phase 6: save first
	end)

	-- Batch inventory updates: at most one sync per player per frame.
	RunService.Heartbeat:Connect(function()
		for player, i in invs do
			if i.dirty and player.Parent then
				sync(player)
			end
		end
	end)
end

return InventoryService
