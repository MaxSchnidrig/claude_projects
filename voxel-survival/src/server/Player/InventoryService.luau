--!strict
-- Server-authoritative inventories and container windows.
--
-- Each player has 36 slots (1..9 hotbar, 10..36 main), a cursor stack (what the mouse carries
-- while a window is open), a crafting grid and one open window:
--   "inventory"       2x2 crafting grid
--   "crafting_table"  3x3 crafting grid            (opened by right-clicking a Crafting Table)
--   "furnace"         furnace slots of that block  (BlockEntityService)
--   "chest"           27 slots of that block       (BlockEntityService)
-- Clients only send intentions (InventoryAction); all slot rules live in the pure SlotLogic /
-- Crafting / FurnaceLogic modules, executed here. Clients get a full copy via InventorySync.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared.Config)
local Remotes = require(Shared.Net.Remotes)
local ItemRegistry = require(Shared.Items.ItemRegistry)
local SlotLogic = require(Shared.Items.SlotLogic)
local Crafting = require(Shared.Items.Crafting)
local BlockRegistry = require(Shared.Blocks.BlockRegistry)
local WorldService = require(script.Parent.Parent.World.WorldService)
local BlockEntityService = require(script.Parent.Parent.World.BlockEntityService)
local ItemEntityService = require(script.Parent.Parent.World.ItemEntityService)

export type Stack = SlotLogic.Stack

type Window = { kind: string, x: number?, y: number?, z: number? }
type Inv = {
	slots: { [number]: Stack? },
	selected: number,
	cursor: Stack?,
	craft: { [number]: Stack? },
	window: Window,
	dirty: boolean,
}

local N = Config.INVENTORY_SLOTS
local ALL = Config.PLAYER_SLOTS -- with armour (37..40) and the off hand (41)
local OFFHAND = Config.OFFHAND_SLOT
local ARMOR_SLOTS = { Config.ARMOR_SLOT.head, Config.ARMOR_SLOT.chest, Config.ARMOR_SLOT.legs, Config.ARMOR_SLOT.feet }
local ARMOR_INDEX = { [Config.ARMOR_SLOT.head] = "head", [Config.ARMOR_SLOT.chest] = "chest", [Config.ARMOR_SLOT.legs] = "legs", [Config.ARMOR_SLOT.feet] = "feet" }
local HOTBAR = Config.HOTBAR_SLOTS
local BS = Config.BLOCK_SIZE
local CRAFTING_TABLE = BlockRegistry.id("crafting_table")

local InventoryService = {}
local invs: { [Player]: Inv } = {}

local function inv(player: Player): Inv
	local i = invs[player]
	if not i then
		i = { slots = {}, selected = 1, cursor = nil, craft = {}, window = { kind = "inventory" }, dirty = true }
		invs[player] = i
	end
	return i
end

-- Worn armour or the off hand changed: avatar pieces, armour points (set by AvatarService /
-- SurvivalService to avoid require cycles).
local armorListeners: { (Player) -> () } = {}
function InventoryService.onArmorChanged(fn: (Player) -> ())
	table.insert(armorListeners, fn)
end
local function armorChanged(player: Player)
	for _, fn in armorListeners do
		task.spawn(fn, player)
	end
end

local function craftWidth(i: Inv): number
	return if i.window.kind == "crafting_table" then 3 else 2
end

local function newStack(item: string, count: number): Stack
	local def = ItemRegistry.get(item)
	return { item = item, count = count, durability = if def and def.tool then def.tool.durability else nil }
end

-- Where a player is (studs), for dropping things at their feet.
local function feet(player: Player): Vector3?
	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart") :: BasePart?
	return root and root.Position
end

---------------------------------------------------------------------------------------------
-- Basic inventory API (used by block actions, pickups)
---------------------------------------------------------------------------------------------

-- Add items: fills matching stacks first, then empty slots (hotbar first). Returns leftover.
function InventoryService.add(player: Player, item: string, count: number, durability: number?): number
	if not ItemRegistry.get(item) or count <= 0 then
		return count
	end
	local i = inv(player)
	local stack: Stack = { item = item, count = count, durability = durability }
	if durability == nil then
		local def = ItemRegistry.get(item)
		if def and def.tool then
			stack.durability = def.tool.durability
		end
	end
	local left = SlotLogic.insert(i.slots, 1, N, stack)
	if left ~= count then
		i.dirty = true
	end
	return left
end

function InventoryService.addStack(player: Player, s: Stack): number
	return InventoryService.add(player, s.item, s.count, s.durability)
end

-- Studio test kit (only for players without saved data).
function InventoryService.giveStarterKit(player: Player)
	for _, entry in Config.STUDIO_STARTER_KIT do
		InventoryService.add(player, entry[1], entry[2])
	end
end

-- Save snapshot: the slots, with the carried stack and the crafting grid folded back in (Java
-- returns them to the inventory when the screen closes; whatever doesn't fit is listed in `extra`
-- and re-added on load).
function InventoryService.snapshot(player: Player): ({ [number]: Stack }, number)
	local i = inv(player)
	local slots: { [number]: Stack } = {}
	for idx = 1, ALL do
		local st = i.slots[idx]
		if st then
			slots[idx] = SlotLogic.copy(st, st.count)
		end
	end
	local loose: { Stack } = {}
	if i.cursor then
		table.insert(loose, SlotLogic.copy(i.cursor :: Stack, (i.cursor :: Stack).count))
	end
	for _, st in i.craft do
		if st then
			table.insert(loose, SlotLogic.copy(st, st.count))
		end
	end
	for _, st in loose do
		SlotLogic.insert(slots, HOTBAR + 1, N, st)
		if st.count > 0 then
			SlotLogic.insert(slots, 1, HOTBAR, st)
		end
	end
	return slots, i.selected
end

function InventoryService.restore(player: Player, slots: { [number]: Stack }, selected: number)
	local i = inv(player)
	table.clear(i.slots)
	-- stacks bigger than the item's limit (saved before the limit changed, e.g. beds stacked to
	-- 64 before 0.8.14): keep the limit in the slot and spread the rest into free slots
	local over: { { idx: number, st: Stack } } = {}
	for idx, st in slots do
		if idx >= 1 and idx <= ALL then
			i.slots[idx] = st
			local max = SlotLogic.maxStack(st.item)
			if st.count > max then
				table.insert(over, { idx = idx, st = SlotLogic.copy(st, st.count - max) })
				st.count = max
			end
		end
	end
	table.sort(over, function(a, b)
		return a.idx < b.idx
	end)
	for _, o in over do
		local left = SlotLogic.insert(i.slots, 1, N, o.st)
		if left > 0 then
			(i.slots[o.idx] :: Stack).count += left -- no room: nothing is lost, it stays over the limit
		end
	end
	i.selected = math.clamp(selected, 1, HOTBAR)
	armorChanged(player)
	i.dirty = true
end

function InventoryService.selectedSlot(player: Player): number
	return inv(player).selected
end

function InventoryService.selectedStack(player: Player): Stack?
	local i = inv(player)
	return i.slots[i.selected]
end

-- Replace the held stack (buckets: empty <-> filled). nil empties the slot.
function InventoryService.replaceSelected(player: Player, stack: Stack?)
	local i = inv(player)
	i.slots[i.selected] = stack
	i.dirty = true
end

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

-- Death: everything the player carries spills on the ground at `pos`.
function InventoryService.dropAll(player: Player, pos: Vector3)
	local i = inv(player)
	local stacks: { Stack } = {}
	for idx = 1, ALL do
		local s = i.slots[idx]
		if s then
			table.insert(stacks, s)
		end
		i.slots[idx] = nil
	end
	armorChanged(player)
	for idx, s in i.craft do
		if s then
			table.insert(stacks, s)
		end
		i.craft[idx] = nil
	end
	if i.cursor then
		table.insert(stacks, i.cursor :: Stack)
		i.cursor = nil
	end
	i.window = { kind = "inventory" }
	i.dirty = true
	ItemEntityService.spawnAround(stacks, pos)
end

---------------------------------------------------------------------------------------------
-- Armour, off hand, ammunition (Phase 8c)
---------------------------------------------------------------------------------------------

-- The worn armour (head, chest, legs, feet; nil where empty).
function InventoryService.armor(player: Player): { Stack? }
	local i = inv(player)
	return { i.slots[ARMOR_SLOTS[1]], i.slots[ARMOR_SLOTS[2]], i.slots[ARMOR_SLOTS[3]], i.slots[ARMOR_SLOTS[4]] }
end

-- Java hurtArmor: every worn piece loses max(1, floor(damage / 4)) durability; broken pieces go.
-- Returns the keys of pieces that broke.
function InventoryService.damageArmor(player: Player, damage: number): { string }
	local i = inv(player)
	local loss = math.max(1, math.floor(damage / 4))
	local broke = {}
	for _, idx in ARMOR_SLOTS do
		local s = i.slots[idx]
		if s and s.durability then
			s.durability -= loss
			if (s.durability :: number) <= 0 then
				table.insert(broke, s.item)
				i.slots[idx] = nil
			end
		end
	end
	i.dirty = true
	if #broke > 0 then
		armorChanged(player)
	end
	return broke
end

function InventoryService.offhand(player: Player): Stack?
	return inv(player).slots[OFFHAND]
end

-- Wear or damage the off hand / main hand item by slot (shield, bow).
function InventoryService.damageSlot(player: Player, idx: number, n: number): boolean
	local i = inv(player)
	local s = i.slots[idx]
	if not s or s.durability == nil then
		return false
	end
	s.durability -= n
	i.dirty = true
	if (s.durability :: number) <= 0 then
		i.slots[idx] = nil
		if idx == OFFHAND then
			armorChanged(player)
		end
		return true
	end
	return false
end

function InventoryService.setSlot(player: Player, idx: number, stack: Stack?)
	local i = inv(player)
	i.slots[idx] = stack
	i.dirty = true
	if idx > N then
		armorChanged(player)
	end
end

function InventoryService.getSlot(player: Player, idx: number): Stack?
	return inv(player).slots[idx]
end

-- Find and use one `item` (arrows): the off hand first, then hotbar, then the bag (Java order).
function InventoryService.takeOne(player: Player, item: string): boolean
	local i = inv(player)
	local order = { OFFHAND }
	for idx = 1, N do
		table.insert(order, idx)
	end
	for _, idx in order do
		local s = i.slots[idx]
		if s and s.item == item then
			s.count -= 1
			if s.count <= 0 then
				i.slots[idx] = nil
			end
			i.dirty = true
			return true
		end
	end
	return false
end

function InventoryService.has(player: Player, item: string): boolean
	local i = inv(player)
	for idx = 1, ALL do
		local s = i.slots[idx]
		if s and s.item == item then
			return true
		end
	end
	return false
end

---------------------------------------------------------------------------------------------
-- Windows
---------------------------------------------------------------------------------------------

-- Put a stack back into the inventory; whatever doesn't fit is dropped at the player's feet.
local function giveOrDrop(player: Player, s: Stack)
	local left = InventoryService.addStack(player, s)
	if left > 0 then
		local pos = feet(player)
		if pos then
			ItemEntityService.spawn(SlotLogic.copy(s, left), pos, Config.ITEM_DROP_PICKUP_DELAY)
		end
	end
end

-- Close the current window: crafting grid and cursor go back to the inventory (or the floor).
local function closeWindow(player: Player, i: Inv)
	for idx, s in i.craft do
		if s then
			giveOrDrop(player, s)
		end
		i.craft[idx] = nil
	end
	if i.cursor then
		giveOrDrop(player, i.cursor)
		i.cursor = nil
	end
	i.window = { kind = "inventory" }
	i.dirty = true
end

-- The block entity behind the current window, if it's a furnace/chest window.
local function windowEntity(i: Inv): BlockEntityService.Entity?
	local w = i.window
	if (w.kind == "furnace" or w.kind == "chest") and w.x then
		return BlockEntityService.get(w.x :: number, w.y :: number, w.z :: number)
	end
	return nil
end

-- Mark everyone who has this container open as needing a sync.
local function touchViewers(e: BlockEntityService.Entity)
	BlockEntityService.markDirty(e.x, e.z)
	for _, other in invs do
		local w = other.window
		if w.x == e.x and w.y == e.y and w.z == e.z then
			other.dirty = true
		end
	end
end
BlockEntityService.setChangedCallback(touchViewers)

local function inReach(player: Player, x: number, y: number, z: number): boolean
	local pos = feet(player)
	if not pos then
		return false
	end
	local center = Vector3.new(x + 0.5, y + 0.5, z + 0.5) * BS
	return (center - pos).Magnitude <= Config.CONTAINER_REACH * BS
end

local function openBlock(player: Player, i: Inv, x: number, y: number, z: number)
	if not inReach(player, x, y, z) then
		return
	end
	local id = WorldService.getBlock(x, y, z)
	local kind: string? = if id == CRAFTING_TABLE then "crafting_table" else BlockEntityService.kindOf(id)
	if not kind then
		return
	end
	closeWindow(player, i)
	if kind ~= "crafting_table" then
		BlockEntityService.ensure(x, y, z, kind)
	end
	i.window = { kind = kind, x = x, y = y, z = z }
	i.dirty = true
end

---------------------------------------------------------------------------------------------
-- Clicks
---------------------------------------------------------------------------------------------

-- Shift-click target ranges for a stack coming from the player inventory.
local function inventoryTargets(i: Inv, from: number): { { slots: SlotLogic.Slots, lo: number, hi: number } }
	local e = windowEntity(i)
	if e and e.kind == "chest" then
		return { { slots = e.slots, lo = 1, hi = BlockEntityService.CHEST_SLOTS } }
	end
	if e and e.kind == "furnace" then
		local s = i.slots[from]
		if s and Crafting.smeltResult(s.item) then
			return { { slots = e.slots, lo = 1, hi = 1 } }
		elseif s and Crafting.fuelSeconds(s.item) > 0 then
			return { { slots = e.slots, lo = 2, hi = 2 } }
		end
	end
	-- Java Edition: with a crafting table open, shift-click from the inventory fills the 3x3
	-- grid first (slots 1..9, merging into matching stacks before empty slots); whatever doesn't
	-- fit moves hotbar <-> inventory as usual. (The 2x2 inventory grid is never a target.)
	if Config.SHIFT_CLICK_INTO_CRAFT_GRID and i.window.kind == "crafting_table" then
		local other = if from <= HOTBAR then { slots = i.slots, lo = HOTBAR + 1, hi = N } else { slots = i.slots, lo = 1, hi = HOTBAR }
		return { { slots = i.craft, lo = 1, hi = 9 }, other }
	end
	-- no container: hotbar <-> main inventory
	if from <= HOTBAR then
		return { { slots = i.slots, lo = HOTBAR + 1, hi = N } }
	end
	return { { slots = i.slots, lo = 1, hi = HOTBAR } }
end

-- Into the player's inventory: main first, then hotbar (classic order for shift-clicks out of
-- containers and the crafting grid).
local function toInventory(i: Inv): { { slots: SlotLogic.Slots, lo: number, hi: number } }
	return { { slots = i.slots, lo = HOTBAR + 1, hi = N }, { slots = i.slots, lo = 1, hi = HOTBAR } }
end

local function takeResult(i: Inv, shift: boolean)
	local w = craftWidth(i)
	local result = Crafting.match(i.craft, w)
	if not result then
		return
	end
	local function consumeGrid()
		for idx = 1, w * w do
			local s = i.craft[idx]
			if s then
				s.count -= 1
				if s.count <= 0 then
					i.craft[idx] = nil
				end
			end
		end
	end
	if shift then
		-- craft as many as fit, one batch at a time
		for _ = 1, 64 do
			local r = Crafting.match(i.craft, w)
			if not r or r.item ~= result.item then
				break
			end
			local made = newStack(r.item, r.count)
			if not SlotLogic.fits(i.slots, 1, N, made) then
				break
			end
			SlotLogic.insert(i.slots, HOTBAR + 1, N, made)
			if made.count > 0 then
				SlotLogic.insert(i.slots, 1, HOTBAR, made)
			end
			consumeGrid()
		end
		return
	end
	local cursor = i.cursor
	if cursor == nil then
		i.cursor = newStack(result.item, result.count)
		consumeGrid()
	elseif cursor.item == result.item and cursor.durability == nil
		and cursor.count + result.count <= SlotLogic.maxStack(cursor.item)
	then
		cursor.count += result.count
		consumeGrid()
	end
end

local function click(player: Player, i: Inv, container: string, index: number, button: string, shift: boolean)
	local leftClick = button ~= "right"
	if container == "inv" then
		if index < 1 or index > ALL then
			return
		end
		local armorSlot = ARMOR_INDEX[index]
		if armorSlot and not shift then
			-- armour slots only take the matching piece, one at a time
			local c = i.cursor
			local def = c and ItemRegistry.get(c.item)
			if c and not (def and def.armor and def.armor.slot == armorSlot) then
				return
			end
		end
		if shift then
			if index > N then
				SlotLogic.quickMove(i.slots, index, toInventory(i)) -- armour / off hand back to the bag
			else
				-- Java: shift-clicking a piece of armour wears it when that slot is free
				local s = i.slots[index]
				local def = s and ItemRegistry.get(s.item)
				local target = def and def.armor and Config.ARMOR_SLOT[def.armor.slot]
				if target and not i.slots[target] and i.window.kind == "inventory" then
					i.slots[target] = s
					i.slots[index] = nil
				else
					SlotLogic.quickMove(i.slots, index, inventoryTargets(i, index))
				end
			end
		elseif leftClick then
			i.cursor = SlotLogic.leftClick(i.slots, index, i.cursor)
		else
			i.cursor = SlotLogic.rightClick(i.slots, index, i.cursor)
		end
		local e = windowEntity(i)
		if e then
			touchViewers(e)
		end
		if index > N or shift then
			armorChanged(player)
		end
	elseif container == "craft" then
		local w = craftWidth(i)
		if i.window.kind ~= "inventory" and i.window.kind ~= "crafting_table" then
			return
		end
		if index < 1 or index > w * w then
			return
		end
		if shift then
			SlotLogic.quickMove(i.craft, index, toInventory(i))
		elseif leftClick then
			i.cursor = SlotLogic.leftClick(i.craft, index, i.cursor)
		else
			i.cursor = SlotLogic.rightClick(i.craft, index, i.cursor)
		end
	elseif container == "result" then
		if i.window.kind == "inventory" or i.window.kind == "crafting_table" then
			takeResult(i, shift)
		end
	elseif container == "block" then
		local e = windowEntity(i)
		if not e then
			return
		end
		local size = if e.kind == "chest" then BlockEntityService.CHEST_SLOTS else 3
		if index < 1 or index > size then
			return
		end
		if shift then
			SlotLogic.quickMove(e.slots, index, toInventory(i))
		elseif e.kind == "furnace" and index == 3 then
			-- output slot: take only
			local out = e.slots[3]
			if out and (i.cursor == nil or (SlotLogic.sameKind(i.cursor :: Stack, out)
				and (i.cursor :: Stack).count + out.count <= SlotLogic.maxStack(out.item)))
			then
				if i.cursor then
					(i.cursor :: Stack).count += out.count
				else
					i.cursor = out
				end
				e.slots[3] = nil
			end
		elseif leftClick then
			i.cursor = SlotLogic.leftClick(e.slots, index, i.cursor)
		else
			i.cursor = SlotLogic.rightClick(e.slots, index, i.cursor)
		end
		touchViewers(e)
	end
	i.dirty = true
end

-- Double-click (Java PICKUP_ALL): gather items matching the carried stack into the cursor, up to a
-- full stack. If nothing is carried yet, the clicked slot's stack is picked up first. Slots are
-- visited in menu order (open container or crafting grid, then main inventory, then hotbar) in two
-- passes: the first skips full stacks. Crafting result slots are never taken from.
local function collect(i: Inv, container: string, index: number)
	local refs: { SlotLogic.SlotRef } = {}
	local e = windowEntity(i)
	if e then
		local size = if e.kind == "chest" then BlockEntityService.CHEST_SLOTS else 3
		for k = 1, size do
			table.insert(refs, { slots = e.slots, index = k })
		end
	elseif i.window.kind == "inventory" or i.window.kind == "crafting_table" then
		for k = 1, craftWidth(i) ^ 2 do
			table.insert(refs, { slots = i.craft, index = k })
		end
	end
	for k = HOTBAR + 1, N do
		table.insert(refs, { slots = i.slots, index = k })
	end
	for k = 1, HOTBAR do
		table.insert(refs, { slots = i.slots, index = k })
	end

	if i.cursor == nil then
		local clicked: { [number]: Stack? }? = nil
		if container == "inv" and index >= 1 and index <= N then
			clicked = i.slots
		elseif container == "craft" and (i.window.kind == "inventory" or i.window.kind == "crafting_table")
			and index >= 1 and index <= craftWidth(i) ^ 2
		then
			clicked = i.craft
		elseif container == "block" and e and index >= 1 and index <= (if e.kind == "chest" then BlockEntityService.CHEST_SLOTS else 3) then
			clicked = e.slots
		end
		if not clicked or not clicked[index] then
			return
		end
		i.cursor = clicked[index]
		clicked[index] = nil
	end
	SlotLogic.collect(refs, i.cursor :: Stack)
	if e then
		touchViewers(e)
	end
	i.dirty = true
end

-- Throw items in front of the player.
local function throw(player: Player, s: Stack)
	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart") :: BasePart?
	if not root then
		return
	end
	local look = root.CFrame.LookVector
	local pos = root.Position + Vector3.new(look.X, 0, look.Z).Unit * (1.6 * BS) + Vector3.new(0, 1, 0)
	ItemEntityService.spawn(s, pos, Config.ITEM_DROP_PICKUP_DELAY)
end

---------------------------------------------------------------------------------------------
-- Sync
---------------------------------------------------------------------------------------------

local function pack(slots: { [number]: Stack? }, n: number): { any }
	-- Remote arrays can't contain nil holes, so empty slots are sent as false.
	local out = table.create(n)
	for idx = 1, n do
		local s = slots[idx]
		out[idx] = if s then { item = s.item, count = s.count, durability = s.durability } else false
	end
	return out
end

local function sync(player: Player)
	local i = inv(player)
	i.dirty = false
	local w = i.window
	local window: { [string]: any } = { kind = w.kind, x = w.x, y = w.y, z = w.z }
	if w.kind == "inventory" or w.kind == "crafting_table" then
		local cw = craftWidth(i)
		window.craftWidth = cw
		window.craft = pack(i.craft, cw * cw)
		local r = Crafting.match(i.craft, cw)
		window.result = if r then { item = r.item, count = r.count } else false
	end
	local e = windowEntity(i)
	if e then
		local size = if e.kind == "chest" then BlockEntityService.CHEST_SLOTS else 3
		window.block = pack(e.slots, size)
		local f = e.furnace
		if f then
			window.burn = f.burn
			window.burnMax = f.burnMax
			window.progress = f.progress
		end
	end
	Remotes.get("InventorySync"):FireClient(player, {
		slots = pack(i.slots, ALL),
		selected = i.selected,
		cursor = if i.cursor then { item = i.cursor.item, count = i.cursor.count, durability = i.cursor.durability } else false,
		window = window,
	})
end

---------------------------------------------------------------------------------------------

local function isInt(v: any): boolean
	return typeof(v) == "number" and v == v and v % 1 == 0 and math.abs(v) < 2 ^ 24
end

local function onAction(player: Player, a: any)
	if typeof(a) ~= "table" or typeof(a.type) ~= "string" then
		return
	end
	local i = inv(player)
	local t = a.type
	if t == "click" then
		if typeof(a.container) ~= "string" or not isInt(a.index) then
			return
		end
		click(player, i, a.container, a.index, if a.button == "right" then "right" else "left", a.shift == true)
	elseif t == "collect" then
		if typeof(a.container) == "string" and isInt(a.index) then
			collect(i, a.container, a.index)
		end
	elseif t == "swapHands" then
		-- F (Java): main hand <-> off hand
		i.slots[i.selected], i.slots[OFFHAND] = i.slots[OFFHAND], i.slots[i.selected]
		i.dirty = true
		armorChanged(player)
	elseif t == "equipHeld" then
		-- right-click with a piece of armour: wear it (swapping out what was worn)
		local s = i.slots[i.selected]
		local def = s and ItemRegistry.get(s.item)
		if def and def.armor then
			local target = Config.ARMOR_SLOT[def.armor.slot]
			i.slots[i.selected], i.slots[target] = i.slots[target], s
			i.dirty = true
			armorChanged(player)
		end
	elseif t == "openInventory" then
		if i.window.kind ~= "inventory" then
			closeWindow(player, i)
		end
		i.dirty = true
	elseif t == "open" then
		if isInt(a.x) and isInt(a.y) and isInt(a.z) then
			openBlock(player, i, a.x, a.y, a.z)
		end
	elseif t == "close" then
		closeWindow(player, i)
	elseif t == "drop" then
		-- drop from the selected hotbar slot (Q / Ctrl+Q)
		local s = i.slots[i.selected]
		if s then
			local n = if a.all == true then s.count else 1
			throw(player, SlotLogic.copy(s, n))
			s.count -= n
			if s.count <= 0 then
				i.slots[i.selected] = nil
			end
			i.dirty = true
		end
	elseif t == "drag" then
		-- Java-style drag over several slots with a carried stack (left: split, right: one each)
		if typeof(a.slots) ~= "table" or #a.slots > N + 27 or not i.cursor then
			return
		end
		local targets: { SlotLogic.DragTarget } = {}
		local e = windowEntity(i)
		for _, ref in a.slots do
			if typeof(ref) == "table" and typeof(ref[1]) == "string" and isInt(ref[2]) then
				local container, index = ref[1], ref[2]
				if container == "inv" and index >= 1 and index <= N then
					table.insert(targets, { slots = i.slots, index = index })
				elseif container == "craft" and (i.window.kind == "inventory" or i.window.kind == "crafting_table")
					and index >= 1 and index <= craftWidth(i) ^ 2
				then
					table.insert(targets, { slots = i.craft, index = index })
				elseif container == "block" and e then
					local size = if e.kind == "chest" then BlockEntityService.CHEST_SLOTS else 2 -- furnace output excluded
					if index >= 1 and index <= size then
						table.insert(targets, { slots = e.slots, index = index })
					end
				end
				-- result slots are never drag targets
			end
		end
		i.cursor = SlotLogic.drag(targets, i.cursor, if a.button == "right" then "right" else "left")
		if e then
			touchViewers(e)
		end
		i.dirty = true
	elseif t == "dropSlot" then
		-- Q over a slot in an open window (Ctrl/Cmd+Q: whole stack)
		if typeof(a.container) ~= "string" or not isInt(a.index) then
			return
		end
		local slots: { [number]: Stack? }? = nil
		local size = 0
		if a.container == "inv" then
			slots, size = i.slots, ALL
		elseif a.container == "craft" then
			slots, size = i.craft, craftWidth(i) ^ 2
		elseif a.container == "block" then
			local e = windowEntity(i)
			if e then
				slots, size = e.slots, if e.kind == "chest" then BlockEntityService.CHEST_SLOTS else 3
				touchViewers(e)
			end
		end
		if slots and a.index >= 1 and a.index <= size then
			local s = slots[a.index]
			if s then
				local n = if a.all == true then s.count else 1
				throw(player, SlotLogic.copy(s, n))
				s.count -= n
				if s.count <= 0 then
					slots[a.index] = nil
				end
				i.dirty = true
			end
		end
	elseif t == "dropCursor" then
		-- clicked outside the window while carrying something
		local c = i.cursor
		if c then
			local n = if a.all == true then c.count else 1
			throw(player, SlotLogic.copy(c, n))
			c.count -= n
			if c.count <= 0 then
				i.cursor = nil
			end
			i.dirty = true
		end
	end
end

-- A container window closes when its block is gone or the player walked away.
local function validateWindows()
	for player, i in invs do
		local w = i.window
		if w.x and player.Parent then
			local id = WorldService.getBlock(w.x :: number, w.y :: number, w.z :: number)
			local expected = if w.kind == "crafting_table" then CRAFTING_TABLE else nil
			local ok = inReach(player, w.x :: number, w.y :: number, w.z :: number)
				and (if expected then id == expected else BlockEntityService.kindOf(id) == w.kind)
			if not ok then
				closeWindow(player, i)
			end
		end
	end
end

function InventoryService.init()
	ItemEntityService.setInventoryAdder(function(player: Player, s: Stack): number
		return InventoryService.addStack(player, s)
	end)

	Remotes.get("SelectSlot").OnServerEvent:Connect(function(player: Player, n: any)
		if isInt(n) and n >= 1 and n <= HOTBAR then
			inv(player).selected = n
		end
	end)
	Remotes.get("InventoryAction").OnServerEvent:Connect(onAction)

	local function onPlayer(player: Player)
		inv(player)
	end
	Players.PlayerAdded:Connect(onPlayer)
	for _, player in Players:GetPlayers() do
		onPlayer(player)
	end
	Players.PlayerRemoving:Connect(function(player)
		-- kept a moment longer so Persistence can save it
		task.delay(30, function()
			invs[player] = nil
		end)
	end)

	local acc = 0
	RunService.Heartbeat:Connect(function(dt)
		acc += dt
		if acc >= 0.5 then
			acc = 0
			validateWindows()
		end
		-- at most one sync per player per frame
		for player, i in invs do
			if i.dirty and player.Parent then
				sync(player)
			end
		end
	end)
end

return InventoryService
