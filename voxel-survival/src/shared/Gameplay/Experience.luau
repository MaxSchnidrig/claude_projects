--!strict
-- Experience (Phase 10a): Java Edition rules, checked against the Minecraft Wiki "Experience"
-- page and the Java classes Player / ExperienceOrb / AbstractFurnaceBlockEntity. Pure and shared:
-- the server runs it, tests check it, the client uses `needed` / `orbIcon` for drawing.
--
--   levels     points for the next level: 2L + 7 (L 0-15), 5L - 38 (16-30), 9L - 158 (31+)
--              (getXpNeededForNextLevel), progress kept as a 32-bit float like Java
--   orbs       an amount is split into Java's orb values (2477, 1237, ... 3, 1); orbs fall
--              (0.03/tick), float up in water, pop in lava (and burn), follow the nearest
--              player within 8 blocks (re-checked every 20 ticks), merge with same-value orbs
--              (every 20 ticks, within 0.5 blocks, ids equal mod 40), vanish after 6000 ticks
--   pickup     a player takes one orb every 2 ticks (takeXpDelay 2), touching it with their box
--              grown by 1 block sideways and 0.5 up/down
--   sources    mobs (player kills only, adults): monsters 5, animals 1-3; breeding 1-7 (one orb);
--              fishing 1-6 (one orb); ores (right tool): coal 0-2, lapis 2-5, volt (redstone-role)
--              1-5, diamond / emerald 3-7; smelting: each recipe's value, paid out when the
--              output is taken (or the furnace is broken), fractions rounded by chance
--   death      drops 7 x level points, at most 100; everything else is lost

local Experience = {}

-- Floats like Java's `float` (experienceProgress is one).
local f32buf = buffer.create(4)
local function f32(x: number): number
	buffer.writef32(f32buf, 0, x)
	return buffer.readf32(f32buf, 0)
end
Experience.f32 = f32

function Experience.needed(level: number): number
	if level >= 30 then
		return 112 + (level - 30) * 9
	elseif level >= 15 then
		return 37 + (level - 15) * 5
	end
	return 7 + level * 2
end

-- Total points to reach `level` from 0 (the wiki's formulas).
function Experience.totalFor(level: number): number
	local t = 0
	for l = 0, level - 1 do
		t += Experience.needed(l)
	end
	return t
end

export type State = { level: number, progress: number, total: number, score: number }

function Experience.new(): State
	return { level = 0, progress = 0, total = 0, score = 0 }
end

-- Player.giveExperienceLevels. Returns nothing; level sounds are the caller's job.
function Experience.addLevels(s: State, levels: number)
	s.level += levels
	if s.level < 0 then
		s.level = 0
		s.progress = 0
		s.total = 0
	end
end

-- Player.giveExperiencePoints. Returns how many levels were gained (for the level-up sound).
function Experience.addPoints(s: State, points: number): number
	local before = s.level
	s.score += points
	s.progress = f32(s.progress + f32(points / Experience.needed(s.level)))
	s.total = math.clamp(s.total + points, 0, 2147483647)
	while s.progress < 0 do
		local f = f32(s.progress * Experience.needed(s.level))
		if s.level > 0 then
			Experience.addLevels(s, -1)
			s.progress = f32(1 + f / Experience.needed(s.level))
		else
			Experience.addLevels(s, -1)
			s.progress = 0
		end
	end
	while s.progress >= 1 do
		s.progress = f32((s.progress - 1) * Experience.needed(s.level))
		Experience.addLevels(s, 1)
		s.progress = f32(s.progress / Experience.needed(s.level))
	end
	return s.level - before
end

-- Player.getBaseExperienceReward: what a dying player drops.
function Experience.deathDrop(level: number): number
	return math.min(level * 7, 100)
end

-- ExperienceOrb.getExperienceValue: the largest orb value that fits.
local VALUES = { 2477, 1237, 617, 307, 149, 73, 37, 17, 7, 3, 1 }
function Experience.orbValue(amount: number): number
	for _, v in VALUES do
		if amount >= v then
			return v
		end
	end
	return 1
end

-- ExperienceOrb.award: the orb values an amount splits into.
function Experience.split(amount: number): { number }
	local out = {}
	while amount > 0 do
		local v = Experience.orbValue(amount)
		amount -= v
		table.insert(out, v)
	end
	return out
end

-- ExperienceOrb.getIcon: 0 (smallest) .. 10, for drawing.
function Experience.orbIcon(value: number): number
	for i, v in VALUES do
		if value >= v then
			return 11 - i
		end
	end
	return 0
end

-- Sources ----------------------------------------------------------------------------------

-- Mob kills: monsters a fixed amount, animals 1 + rand(3) (Animal.getBaseExperienceReward).
Experience.MOB = { zombie = 5, skeleton = 5, spider = 5, sneaker = 5, voidling = 5 } :: { [string]: number }
Experience.ANIMALS = { cow = true, pig = true, sheep = true, chicken = true } :: { [string]: boolean }

-- `rand(a, b)` inclusive integer
function Experience.mobReward(key: string, rand: (number, number) -> number): number
	if Experience.ANIMALS[key] then
		return rand(1, 3)
	end
	return Experience.MOB[key] or 0
end

-- Ores: UniformInt ranges (dropped only when the block drops its items).
Experience.ORE = {
	coal_ore = { 0, 2 },
	lapis_ore = { 2, 5 },
	volt_ore = { 1, 5 }, -- redstone-role
	diamond_ore = { 3, 7 },
	emerald_ore = { 3, 7 },
} :: { [string]: { number } }

Experience.BREED = { 1, 7 }
Experience.FISH = { 1, 6 }

-- Smelting: each recipe's experience (Java recipe JSON), by result. Inputs listed in
-- SMELT_INPUT override the result's value.
Experience.SMELT = {
	iron_ingot = 0.7,
	gold_ingot = 1.0,
	copper_ingot = 0.7,
	glass = 0.1,
	stone = 0.1,
	charcoal = 0.15,
	cooked_porkchop = 0.35,
	baked_potato = 0.35,
	steak = 0.35,
	cooked_chicken = 0.35,
	cooked_mutton = 0.35,
	cooked_fish = 0.35,
	green_dye = 1.0,
	coal = 0.1, -- coal ore (silk touch, 10c)
	diamond = 1.0,
	emerald = 1.0,
	lapis_lazuli = 0.2,
	volt_dust = 0.7,
} :: { [string]: number }
Experience.SMELT_INPUT = {} :: { [string]: number }

function Experience.smeltValue(input: string, result: string): number
	return Experience.SMELT_INPUT[input] or Experience.SMELT[result] or 0
end

-- AbstractFurnaceBlockEntity.createExperience for every recipe used: count x value, the
-- fraction rounded up by chance. `used` = { [input] = count }, `results` maps input -> result,
-- `random()` in [0, 1).
function Experience.furnacePayout(used: { [string]: number }, results: (string) -> string?, random: () -> number): number
	local total = 0
	for input, count in used do
		local result = results(input)
		local xp = if result then Experience.smeltValue(input, result) else 0
		local amount = f32(count * xp)
		local whole = math.floor(amount)
		local frac = amount - whole
		if frac ~= 0 and random() < frac then
			whole += 1
		end
		total += whole
	end
	return total
end

-- Orb motion (ExperienceOrb.tick), block units per tick -------------------------------------

Experience.ORB_SIZE = 0.5
Experience.FOLLOW_RANGE = 8
Experience.DESPAWN_TICKS = 6000
Experience.MERGE_EVERY = 20
Experience.PICKUP_DELAY = 2

export type Orb = {
	id: number,
	value: number,
	count: number, -- one entity can stand for several orbs of the same value
	x: number, y: number, z: number, -- feet centre
	vx: number, vy: number, vz: number, -- blocks per tick
	age: number,
	ticks: number, -- tickCount
	onGround: boolean,
	lavaTicks: number,
}

-- Java's starting motion: random sideways +-0.2, up to 0.4 upward (blocks/tick).
function Experience.newOrb(id: number, value: number, x: number, y: number, z: number, random: () -> number): Orb
	return {
		id = id, value = value, count = 1,
		x = x, y = y, z = z,
		vx = (random() * 0.2 - 0.1) * 2, vy = random() * 0.2 * 2, vz = (random() * 0.2 - 0.1) * 2,
		age = 0, ticks = 0, onGround = false, lavaTicks = 0,
	}
end

-- One tick of an orb. `move(o, dx, dy, dz)` moves it against the blocks and returns the moved
-- distances and onGround; `fluidAt(x, y, z)` = "water" | "lava" | nil; `target` = the followed
-- player's feet and eye height (blocks) or nil. Returns false when the orb is gone.
function Experience.stepOrb(
	o: Orb,
	move: (Orb, number, number, number) -> (number, number, number, boolean),
	fluidAt: (number, number, number) -> string?,
	target: Vector3?, eyeHeight: number,
	random: () -> number
): boolean
	o.ticks += 1
	if fluidAt(o.x, o.y + Experience.ORB_SIZE * 0.85, o.z) == "water" then
		o.vx *= 0.99
		o.vy = math.min(o.vy + 5.0E-4, 0.06)
		o.vz *= 0.99
	else
		o.vy -= 0.03
	end
	if fluidAt(o.x, o.y, o.z) == "lava" then
		o.vx = (random() - random()) * 0.2
		o.vy = 0.2
		o.vz = (random() - random()) * 0.2
		-- lava hurts it for 4 a tick; an orb has 5 health
		o.lavaTicks += 1
		if o.lavaTicks >= 2 then
			return false
		end
	end
	if target then
		local dx, dy, dz = target.X - o.x, target.Y + eyeHeight / 2 - o.y, target.Z - o.z
		local d2 = dx * dx + dy * dy + dz * dz
		if d2 < 64 then
			local d = math.sqrt(d2)
			local e = 1 - d / 8
			if d > 1e-9 then
				local k = e * e * 0.1 / d
				o.vx += dx * k
				o.vy += dy * k
				o.vz += dz * k
			end
		end
	end
	local mx, my, mz, ground = move(o, o.vx, o.vy, o.vz)
	if math.abs(mx - o.vx) > 1e-9 then
		o.vx = 0
	end
	if math.abs(mz - o.vz) > 1e-9 then
		o.vz = 0
	end
	if math.abs(my - o.vy) > 1e-9 then
		o.vy = 0
	end
	o.onGround = ground
	local f = if ground then 0.6 * 0.98 else 0.98
	o.vx *= f
	o.vy *= 0.98
	o.vz *= f
	if ground then
		o.vy *= -0.9
	end
	o.age += 1
	return o.age < Experience.DESPAWN_TICKS
end

-- ExperienceOrb.canMerge: same value, ids equal mod 40.
function Experience.canMerge(a: Orb, b: Orb): boolean
	return a ~= b and a.value == b.value and (a.id - b.id) % 40 == 0
end

-- Does a player box (feet centre, 0.6 x 1.8) grown by (1, 0.5, 1) touch the orb's box?
function Experience.touches(o: Orb, feet: Vector3): boolean
	local h = Experience.ORB_SIZE / 2
	local px0, px1 = feet.X - 0.3 - 1, feet.X + 0.3 + 1
	local py0, py1 = feet.Y - 0.5, feet.Y + 1.8 + 0.5
	local pz0, pz1 = feet.Z - 0.3 - 1, feet.Z + 0.3 + 1
	return o.x + h > px0 and o.x - h < px1 and o.y + Experience.ORB_SIZE > py0 and o.y < py1
		and o.z + h > pz0 and o.z - h < pz1
end

return Experience
