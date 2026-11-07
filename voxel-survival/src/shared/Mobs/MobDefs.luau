--!strict
-- Mob data (one entry per mob), Java Edition values from minecraft.wiki. Models live in
-- client/Mobs/MobModels (original blocky designs). Sneaker uses the Creeper's stats, Voidling
-- the Enderman's.
--
--   category     "hostile" | "passive" | "projectile"
--   behavior     "wander" (passive), "melee", "ranged", "exploder", "teleporter", "projectile"
--   width/height hitbox in blocks (feet-centred box)
--   speedAttr    Java movement_speed attribute. Ground speed in blocks/s is
--                MobDefs.blocksPerSecond(attr * goalModifier) = 43.17 * (attr * modifier)^2
--                (mobs feed their speed in as both input and acceleration; 0.98 input damping,
--                ground friction 0.546 per tick)
--   chase/wander/panic   Java goal speed modifiers (melee/bow goal, random stroll, panic)
--   attack       melee damage per hit on Normal; attackCooldown in seconds
--   followRange  blocks within which a hostile can pick a target (vertical search +-4 blocks)
--   armor        armor points (damage reduction)
--   undead       burns in daylight under open sky
--   drops        { item, min, max, chance?, playerKill? }  count = random(min, max), <= 0 drops
--                nothing; `chance` rolls first; `playerKill` drops only when a player killed it
--   spawn        weight / group size for the natural spawner (Java overworld lists)

export type Drop = { item: string, min: number, max: number, chance: number?, playerKill: boolean? }
export type MobDef = {
	key: string,
	name: string,
	code: number, -- small integer sent over the network
	category: string,
	behavior: string,
	health: number,
	width: number,
	height: number,
	speedAttr: number,
	chase: number,
	wander: number,
	panic: number,
	speed: number, -- derived: blocks/s at chase modifier
	attack: number,
	attackCooldown: number,
	followRange: number,
	armor: number,
	undead: boolean,
	canClimb: boolean,
	drops: { Drop },
	spawnWeight: number,
	groupMin: number,
	groupMax: number,
	-- behaviour extras
	fuseSeconds: number?,
	explosionPower: number?,
	shootRange: number?,
	angrySpeedAttr: number?,
	eyeHeight: number?,
}

local list: { MobDef } = {
	{
		key = "zombie", name = "Zombie", code = 1, category = "hostile", behavior = "melee",
		health = 20, width = 0.6, height = 1.95, speedAttr = 0.23, chase = 1.0, wander = 1.0, panic = 1.0,
		speed = 0, attack = 3, attackCooldown = 1.0, followRange = 35, armor = 2, undead = true, canClimb = false,
		drops = {
			{ item = "rotten_flesh", min = 0, max = 2 },
			-- rare drop: 2.5 % for one of these three (player kills only)
			{ item = "iron_ingot", min = 1, max = 1, chance = 0.025 / 3, playerKill = true },
			{ item = "carrot", min = 1, max = 1, chance = 0.025 / 3, playerKill = true },
			{ item = "potato", min = 1, max = 1, chance = 0.025 / 3, playerKill = true },
		},
		spawnWeight = 95, groupMin = 4, groupMax = 4, eyeHeight = 1.74,
	},
	{
		key = "skeleton", name = "Skeleton", code = 2, category = "hostile", behavior = "ranged",
		health = 20, width = 0.6, height = 1.99, speedAttr = 0.25, chase = 1.0, wander = 1.0, panic = 1.0,
		speed = 0, attack = 2, attackCooldown = 2.0, followRange = 16, armor = 0, undead = true, canClimb = false,
		shootRange = 15,
		drops = { { item = "bone", min = 0, max = 2 }, { item = "arrow", min = 0, max = 2 } },
		spawnWeight = 100, groupMin = 4, groupMax = 4, eyeHeight = 1.74,
	},
	{
		key = "spider", name = "Spider", code = 3, category = "hostile", behavior = "melee",
		health = 16, width = 1.4, height = 0.9, speedAttr = 0.3, chase = 1.0, wander = 0.8, panic = 1.0,
		speed = 0, attack = 2, attackCooldown = 1.0, followRange = 16, armor = 0, undead = false, canClimb = true,
		drops = { { item = "string", min = 0, max = 2 }, { item = "spider_eye", min = -1, max = 1, playerKill = true } },
		spawnWeight = 100, groupMin = 4, groupMax = 4, eyeHeight = 0.65,
	},
	{
		key = "sneaker", name = "Sneaker", code = 4, category = "hostile", behavior = "exploder",
		health = 20, width = 0.6, height = 1.7, speedAttr = 0.25, chase = 1.0, wander = 0.8, panic = 1.0,
		speed = 0, attack = 0, attackCooldown = 0, followRange = 16, armor = 0, undead = false, canClimb = false,
		fuseSeconds = 1.5, explosionPower = 3,
		drops = { { item = "gunpowder", min = 0, max = 2 } },
		spawnWeight = 100, groupMin = 4, groupMax = 4, eyeHeight = 1.445,
	},
	{
		key = "voidling", name = "Voidling", code = 5, category = "hostile", behavior = "teleporter",
		health = 40, width = 0.6, height = 2.9, speedAttr = 0.3, chase = 1.0, wander = 1.0, panic = 1.0,
		speed = 0, attack = 7, attackCooldown = 1.0, followRange = 64, armor = 0, undead = false, canClimb = false,
		angrySpeedAttr = 0.45,
		drops = { { item = "void_shard", min = 0, max = 1 } },
		spawnWeight = 10, groupMin = 1, groupMax = 4, eyeHeight = 2.55,
	},
	{
		key = "cow", name = "Cow", code = 10, category = "passive", behavior = "wander",
		health = 10, width = 0.9, height = 1.4, speedAttr = 0.2, chase = 1.0, wander = 1.0, panic = 2.0,
		speed = 0, attack = 0, attackCooldown = 0, followRange = 0, armor = 0, undead = false, canClimb = false,
		drops = { { item = "raw_beef", min = 1, max = 3 }, { item = "leather", min = 0, max = 2 } },
		spawnWeight = 8, groupMin = 4, groupMax = 4,
	},
	{
		key = "pig", name = "Pig", code = 11, category = "passive", behavior = "wander",
		health = 10, width = 0.9, height = 0.9, speedAttr = 0.25, chase = 1.0, wander = 1.0, panic = 1.25,
		speed = 0, attack = 0, attackCooldown = 0, followRange = 0, armor = 0, undead = false, canClimb = false,
		drops = { { item = "raw_porkchop", min = 1, max = 3 } },
		spawnWeight = 10, groupMin = 4, groupMax = 4,
	},
	{
		key = "sheep", name = "Sheep", code = 12, category = "passive", behavior = "wander",
		health = 8, width = 0.9, height = 1.3, speedAttr = 0.23, chase = 1.0, wander = 1.0, panic = 1.25,
		speed = 0, attack = 0, attackCooldown = 0, followRange = 0, armor = 0, undead = false, canClimb = false,
		drops = { { item = "white_wool", min = 1, max = 1 }, { item = "raw_mutton", min = 1, max = 2 } },
		spawnWeight = 12, groupMin = 4, groupMax = 4,
	},
	{
		key = "chicken", name = "Chicken", code = 13, category = "passive", behavior = "wander",
		health = 4, width = 0.4, height = 0.7, speedAttr = 0.25, chase = 1.0, wander = 1.0, panic = 1.4,
		speed = 0, attack = 0, attackCooldown = 0, followRange = 0, armor = 0, undead = false, canClimb = false,
		drops = { { item = "raw_chicken", min = 1, max = 1 }, { item = "feather", min = 0, max = 2 } },
		spawnWeight = 10, groupMin = 4, groupMax = 4,
	},
	{
		key = "arrow", name = "Arrow", code = 20, category = "projectile", behavior = "projectile",
		health = 1, width = 0.5, height = 0.5, speedAttr = 0, chase = 0, wander = 0, panic = 0,
		speed = 0, attack = 0, attackCooldown = 0, followRange = 0, armor = 0, undead = false, canClimb = false,
		drops = {}, spawnWeight = 0, groupMin = 0, groupMax = 0,
	},
}

local MobDefs = {}

-- Steady ground speed (blocks/s) of a mob moving with Java speed value `s` (= attribute * modifier).
function MobDefs.blocksPerSecond(s: number): number
	return 0.98 * s * s / (1 - 0.546) * 20
end

for _, d in list do
	d.speed = MobDefs.blocksPerSecond(d.speedAttr * d.chase)
end

MobDefs.list = list
MobDefs.byKey = {} :: { [string]: MobDef }
MobDefs.byCode = {} :: { [number]: MobDef }
for _, d in list do
	assert(not MobDefs.byKey[d.key] and not MobDefs.byCode[d.code], `MobDefs: duplicate {d.key}`)
	MobDefs.byKey[d.key] = d
	MobDefs.byCode[d.code] = d
end

return MobDefs
