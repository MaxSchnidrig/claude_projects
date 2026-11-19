--!strict
-- Status effects with Java's rules (MobEffect / MobEffectInstance), pure so they run headless.
--
-- An effect has an amplifier (0 = level I) and a duration in ticks (20 per second).
--   poison           1 damage every (25 >> amp) ticks, never below 1 health (it can't kill)
--   regeneration     +1 health every (50 >> amp) ticks
--   hunger           0.005 * (amp + 1) exhaustion every tick
--   absorption       4 * (amp + 1) extra health that takes damage first; the effect ends early
--                    once that extra health is used up
--   resistance       damage x (25 - 5 * (amp + 1)) / 25 (not the void)
--   fire_resistance  no damage from fire, lava, burning or campfires
--
-- Adding an effect the player already has (Java MobEffectInstance.update):
--   * a higher level replaces it; if the new one is shorter, the old one waits underneath
--     ("hidden") and comes back when the new one runs out
--   * the same level only ever extends the time
--   * a lower but longer one waits underneath
-- Hidden effects run down their time too.

local Effects = {}

export type Inst = { amp: number, ticks: number, hidden: Inst? }
export type List = { [string]: Inst }

export type Def = { name: string, harmful: boolean, color: { number } }
Effects.DEFS = {
	speed = { name = "Speed", harmful = false, color = { 61, 207, 230 } },
	strength = { name = "Strength", harmful = false, color = { 218, 102, 61 } },
	poison = { name = "Poison", harmful = true, color = { 120, 160, 40 } },
	regeneration = { name = "Regeneration", harmful = false, color = { 220, 110, 170 } },
	hunger = { name = "Hunger", harmful = true, color = { 110, 130, 70 } },
	absorption = { name = "Absorption", harmful = false, color = { 240, 196, 60 } },
	resistance = { name = "Resistance", harmful = false, color = { 140, 150, 170 } },
	fire_resistance = { name = "Fire Resistance", harmful = false, color = { 230, 120, 40 } },
} :: { [string]: Def }
-- the order they're listed in on screen (Java sorts by kind; we keep it fixed and simple)
Effects.ORDER = { "speed", "strength", "regeneration", "absorption", "resistance", "fire_resistance", "poison", "hunger" }

local ROMAN = { "I", "II", "III", "IV", "V", "VI", "VII", "VIII", "IX", "X" }
function Effects.label(id: string, amp: number): string
	local d = Effects.DEFS[id]
	local name = if d then d.name else id
	return if amp > 0 then `{name} {ROMAN[amp + 1] or tostring(amp + 1)}` else name
end

-- "m:ss" like Java's effect timer
function Effects.timeText(ticks: number): string
	local s = math.max(0, math.floor(ticks / 20))
	return string.format("%d:%02d", s // 60, s % 60)
end

local function copy(e: Inst): Inst
	return { amp = e.amp, ticks = e.ticks, hidden = e.hidden }
end

-- Java MobEffectInstance.update: merge `new` into `cur`. Returns true if `cur` changed.
local function update(cur: Inst, new: Inst): boolean
	if new.amp > cur.amp then
		if new.ticks < cur.ticks then
			local old = cur.hidden
			local h = copy(cur)
			h.hidden = old
			cur.hidden = h
		end
		cur.amp = new.amp
		cur.ticks = new.ticks
		return true
	elseif cur.ticks < new.ticks then
		if new.amp == cur.amp then
			cur.ticks = new.ticks
			return true
		elseif cur.hidden == nil then
			cur.hidden = { amp = new.amp, ticks = new.ticks }
		else
			update(cur.hidden :: Inst, new)
		end
	end
	return false
end

-- Give an effect. Returns true if it's new or its visible level/time changed.
function Effects.add(list: List, id: string, amp: number, ticks: number): boolean
	local cur = list[id]
	if not cur then
		list[id] = { amp = amp, ticks = ticks }
		return true
	end
	return update(cur, { amp = amp, ticks = ticks })
end

function Effects.has(list: List, id: string): boolean
	return list[id] ~= nil
end

function Effects.amp(list: List, id: string): number?
	local e = list[id]
	return e and e.amp
end

function Effects.clear(list: List)
	table.clear(list)
end

-- Does this effect act on this tick? (Java shouldApplyEffectTickThisTick)
function Effects.actsNow(id: string, ticks: number, amp: number): boolean
	if id == "poison" then
		local i = bit32.rshift(25, amp)
		return if i > 0 then ticks % i == 0 else true
	elseif id == "regeneration" then
		local i = bit32.rshift(50, amp)
		return if i > 0 then ticks % i == 0 else true
	elseif id == "hunger" or id == "absorption" then
		return true
	end
	return false
end

export type Hooks = {
	health: () -> number,
	maxHealth: () -> number,
	hurt: (amount: number) -> (), -- poison (magic damage: no armour)
	heal: (amount: number) -> (),
	exhaust: (amount: number) -> (),
	absorption: () -> number, -- the extra health left
}

local function tickDown(e: Inst)
	if e.hidden then
		tickDown(e.hidden :: Inst)
	end
	e.ticks -= 1
end

-- One game tick for every effect. Returns the ids that ended (ran out or were used up).
function Effects.tick(list: List, h: Hooks): { string }
	local ended = {}
	for _, id in Effects.ORDER do
		local e = list[id]
		if e and e.ticks > 0 then
			local keep = true
			if Effects.actsNow(id, e.ticks, e.amp) then
				if id == "poison" then
					if h.health() > 1 then
						h.hurt(1)
					end
				elseif id == "regeneration" then
					if h.health() < h.maxHealth() then
						h.heal(1)
					end
				elseif id == "hunger" then
					h.exhaust(0.005 * (e.amp + 1))
				elseif id == "absorption" then
					keep = h.absorption() > 0 -- Java: the effect ends when its hearts are gone
				end
			end
			if not keep then
				list[id] = nil
				table.insert(ended, id)
			else
				tickDown(e)
				if e.ticks <= 0 then
					local hid = e.hidden
					if hid and hid.ticks > 0 then
						e.amp, e.ticks, e.hidden = hid.amp, hid.ticks, hid.hidden
					else
						list[id] = nil
						table.insert(ended, id)
					end
				end
			end
		elseif e then
			list[id] = nil
			table.insert(ended, id)
		end
	end
	return ended
end

-- Extra health an absorption level gives (Java: 4 per level).
function Effects.absorptionMax(list: List): number
	local e = list.absorption
	return if e then 4 * (e.amp + 1) else 0
end

-- Resistance (after armour): damage x (25 - 5 * (amp + 1)) / 25, never below 0.
function Effects.resist(list: List, damage: number): number
	local e = list.resistance
	if not e then
		return damage
	end
	local j = 25 - (e.amp + 1) * 5
	return math.max(damage * j / 25, 0)
end

-- Save format: { {id, amp, ticks, hidden...}, ... } (hidden levels as a nested list).
local function encodeInst(e: Inst): { any }
	local out: { any } = { e.amp, e.ticks }
	if e.hidden then
		out[3] = encodeInst(e.hidden :: Inst)
	end
	return out
end
function Effects.encode(list: List): { [string]: any }
	local out = {}
	for id, e in list do
		out[id] = encodeInst(e)
	end
	return out
end
local function decodeInst(t: any, depth: number): Inst?
	if typeof(t) ~= "table" or typeof(t[1]) ~= "number" or typeof(t[2]) ~= "number" or depth > 8 then
		return nil
	end
	local amp, ticks = math.clamp(math.floor(t[1]), 0, 255), math.floor(t[2])
	if ticks <= 0 then
		return nil
	end
	return { amp = amp, ticks = ticks, hidden = decodeInst(t[3], depth + 1) }
end
function Effects.decode(t: any): List
	local list: List = {}
	if typeof(t) == "table" then
		for id, v in t do
			if typeof(id) == "string" and Effects.DEFS[id] then
				local e = decodeInst(v, 0)
				if e then
					list[id] = e
				end
			end
		end
	end
	return list
end

-- Effects foods give (Java Foods / Consumables). chance 1 = always.
export type FoodEffect = { id: string, amp: number, ticks: number, chance: number }
Effects.FOOD = {
	pufferfish = { { id = "poison", amp = 1, ticks = 300, chance = 1 } },
	potion_speed = { { id = "speed", amp = 0, ticks = 3600, chance = 1 } },
	potion_strength = { { id = "strength", amp = 0, ticks = 3600, chance = 1 } },
	potion_regeneration = { { id = "regeneration", amp = 0, ticks = 900, chance = 1 } },

	golden_apple = {
		{ id = "regeneration", amp = 1, ticks = 100, chance = 1 },
		{ id = "absorption", amp = 0, ticks = 2400, chance = 1 },
	},
	enchanted_golden_apple = {
		{ id = "regeneration", amp = 1, ticks = 400, chance = 1 },
		{ id = "resistance", amp = 0, ticks = 6000, chance = 1 },
		{ id = "fire_resistance", amp = 0, ticks = 6000, chance = 1 },
		{ id = "absorption", amp = 3, ticks = 2400, chance = 1 },
	},
	rotten_flesh = { { id = "hunger", amp = 0, ticks = 600, chance = 0.8 } },
	spider_eye = { { id = "poison", amp = 0, ticks = 100, chance = 1 } },
	poisonous_potato = { { id = "poison", amp = 0, ticks = 100, chance = 0.6 } },
	raw_chicken = { { id = "hunger", amp = 0, ticks = 600, chance = 0.3 } },
} :: { [string]: { FoodEffect } }

return Effects
