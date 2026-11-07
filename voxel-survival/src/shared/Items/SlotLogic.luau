--!strict
-- Pure inventory-slot rules (classic click semantics). The server runs these on its own data;
-- the client never changes slots itself.
--
--   left click   empty cursor: pick up the stack | cursor on empty slot: put all down
--                same item: merge as much as fits  | different item: swap
--   right click  empty cursor: pick up half (rounded up)
--                cursor: put ONE item down (empty slot or same item with room), else swap
--   quickMove    (shift-click) move a whole stack into other slot ranges: first merge into
--                matching stacks, then fill empty slots
--   drag         (Java Edition "quick craft") press with a carried stack and drag over slots:
--                left = split evenly (each slot gets floor(count / slots), capped at the stack
--                limit; the rest stays on the cursor), right = one item per slot. Only slots that
--                are empty or hold the same item with room count.

local ItemRegistry = require(script.Parent.ItemRegistry)

export type Stack = { item: string, count: number, durability: number? }
export type Slots = { [number]: Stack? }

local SlotLogic = {}

function SlotLogic.maxStack(item: string): number
	local def = ItemRegistry.get(item)
	return if def then def.stack else 64
end

function SlotLogic.copy(s: Stack, count: number?): Stack
	return { item = s.item, count = count or s.count, durability = s.durability }
end

-- Can `b` be merged onto `a`? (Tools never stack: their max stack is 1.)
function SlotLogic.sameKind(a: Stack, b: Stack): boolean
	return a.item == b.item and a.durability == b.durability
end

-- Returns the new cursor stack.
function SlotLogic.leftClick(slots: Slots, i: number, cursor: Stack?): Stack?
	local s = slots[i]
	if not cursor then
		slots[i] = nil
		return s
	end
	if not s then
		slots[i] = cursor
		return nil
	end
	if SlotLogic.sameKind(s, cursor) then
		local move = math.min(SlotLogic.maxStack(s.item) - s.count, cursor.count)
		if move > 0 then
			s.count += move
			cursor.count -= move
			return if cursor.count > 0 then cursor else nil
		end
		return cursor
	end
	slots[i] = cursor
	return s
end

function SlotLogic.rightClick(slots: Slots, i: number, cursor: Stack?): Stack?
	local s = slots[i]
	if not cursor then
		if not s then
			return nil
		end
		local take = math.ceil(s.count / 2)
		local picked = SlotLogic.copy(s, take)
		s.count -= take
		if s.count <= 0 then
			slots[i] = nil
		end
		return picked
	end
	if not s then
		slots[i] = SlotLogic.copy(cursor, 1)
		cursor.count -= 1
		return if cursor.count > 0 then cursor else nil
	end
	if SlotLogic.sameKind(s, cursor) then
		if s.count < SlotLogic.maxStack(s.item) then
			s.count += 1
			cursor.count -= 1
		end
		return if cursor.count > 0 then cursor else nil
	end
	slots[i] = cursor
	return s
end

-- Put `stack` into slots[lo..hi]: merge first, then empty slots. Mutates `stack.count`;
-- returns the number of items that didn't fit.
function SlotLogic.insert(slots: Slots, lo: number, hi: number, stack: Stack): number
	local max = SlotLogic.maxStack(stack.item)
	if max > 1 then
		for i = lo, hi do
			local s = slots[i]
			if s and SlotLogic.sameKind(s, stack) and s.count < max then
				local move = math.min(max - s.count, stack.count)
				s.count += move
				stack.count -= move
				if stack.count == 0 then
					return 0
				end
			end
		end
	end
	for i = lo, hi do
		if not slots[i] then
			local n = math.min(max, stack.count)
			slots[i] = SlotLogic.copy(stack, n)
			stack.count -= n
			if stack.count == 0 then
				return 0
			end
		end
	end
	return stack.count
end

-- Would `stack` fit entirely into slots[lo..hi]?
function SlotLogic.fits(slots: Slots, lo: number, hi: number, stack: Stack): boolean
	local left = stack.count
	local max = SlotLogic.maxStack(stack.item)
	for i = lo, hi do
		local s = slots[i]
		if not s then
			left -= max
		elseif SlotLogic.sameKind(s, stack) then
			left -= max - s.count
		end
		if left <= 0 then
			return true
		end
	end
	return false
end

-- Shift-click: move slots[i] into the target ranges, in order. Returns true if anything moved.
function SlotLogic.quickMove(from: Slots, i: number, targets: { { slots: Slots, lo: number, hi: number } }): boolean
	local s = from[i]
	if not s then
		return false
	end
	local before = s.count
	for _, t in targets do
		if s.count == 0 then
			break
		end
		SlotLogic.insert(t.slots, t.lo, t.hi, s)
	end
	if s.count == 0 then
		from[i] = nil
	end
	return s.count ~= before
end

export type DragTarget = { slots: Slots, index: number }

-- Can `stack` be dropped into this slot during a drag?
function SlotLogic.dragAccepts(slot: Stack?, stack: Stack): boolean
	return slot == nil or (SlotLogic.sameKind(slot, stack) and slot.count < SlotLogic.maxStack(stack.item))
end

-- Apply a drag. `targets` in visit order (duplicates ignored). Returns the new cursor.
function SlotLogic.drag(targets: { DragTarget }, cursor: Stack?, button: string): Stack?
	if not cursor or cursor.count <= 0 then
		return cursor
	end
	local c = cursor :: Stack
	local seen: { [any]: { [number]: boolean } } = {}
	local eligible: { DragTarget } = {}
	for _, t in targets do
		seen[t.slots] = seen[t.slots] or {}
		if not seen[t.slots][t.index] then
			seen[t.slots][t.index] = true
			if SlotLogic.dragAccepts(t.slots[t.index], c) then
				table.insert(eligible, t)
			end
		end
	end
	if #eligible == 0 then
		return c
	end
	local max = SlotLogic.maxStack(c.item)
	if button == "right" then
		for _, t in eligible do
			if c.count <= 0 then
				break
			end
			local s = t.slots[t.index]
			if s then
				s.count += 1
			else
				t.slots[t.index] = SlotLogic.copy(c, 1)
			end
			c.count -= 1
		end
	else
		local per = c.count // #eligible
		if per == 0 then
			return c -- more slots than items: classic clients prevent this; do nothing
		end
		for _, t in eligible do
			local s = t.slots[t.index]
			local have = if s then s.count else 0
			local add = math.min(per, max - have)
			if add > 0 then
				if s then
					s.count += add
				else
					t.slots[t.index] = SlotLogic.copy(c, add)
				end
				c.count -= add
			end
		end
	end
	return if c.count > 0 then c else nil
end

return SlotLogic
