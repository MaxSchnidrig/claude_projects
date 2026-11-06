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

return SlotLogic
