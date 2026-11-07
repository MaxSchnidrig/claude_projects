--!strict
-- Mob data (one entry per mob). Models live in client/Mobs/MobModels (original blocky designs).
--
--   category     "hostile" | "passive" | "projectile"
--   behavior     "wander" (passive), "melee", "ranged", "exploder", "teleporter", "projectile"
--   width/height hitbox in blocks (feet-centred box)
--   speed        blocks/s when chasing/panicking; wandering uses half
--   attack       damage per hit (Normal difficulty); reach in blocks
--   followRange  blocks within which a hostile notices a player
--   undead       burns in daylight under open sky
--   neutralInLight  only hostile in darkness or when hurt (spiders, shiftlings)
--   drops        { item, min, max }
--   spawn        weight / group size for the natural spawner

export type Drop = { item: string, min: number, max: number }
export type MobDef = {
	key: string,
	name: string,
	code: number, -- small integer sent over the network
	category: string,
	behavior: string,
	health: number,
	width: number,
	height: number,
	speed: number,
	attack: number,
	reach: number,
	attackCooldown: number,
	followRange: number,
	undead: boolean,
	neutralInLight: boolean,
	canClimb: boolean,
	drops: { Drop },
	spawnWeight: number,
	groupMin: number,
	groupMax: number,
	-- behaviour extras
	fuseSeconds: number?,
	explosionPower: number?,
	shootRange: number?,
}

local list: { MobDef } = {
	{
		key = "zombie", name = "Zombie", code = 1, category = "hostile", behavior = "melee",
		health = 20, width = 0.6, height = 1.95, speed = 2.3, attack = 3, reach = 1.0, attackCooldown = 1.0,
		followRange = 24, undead = true, neutralInLight = false, canClimb = false,
		drops = { { item = "rotten_flesh", min = 0, max = 2 } },
		spawnWeight = 100, groupMin = 2, groupMax = 4,
	},
	{
		key = "skeleton", name = "Skeleton", code = 2, category = "hostile", behavior = "ranged",
		health = 20, width = 0.6, height = 1.95, speed = 2.5, attack = 3, reach = 1.0, attackCooldown = 2.0,
		followRange = 16, undead = true, neutralInLight = false, canClimb = false, shootRange = 14,
		drops = { { item = "bone", min = 0, max = 2 }, { item = "arrow", min = 0, max = 2 } },
		spawnWeight = 100, groupMin = 2, groupMax = 4,
	},
	{
		key = "spider", name = "Spider", code = 3, category = "hostile", behavior = "melee",
		health = 16, width = 1.4, height = 0.9, speed = 3.0, attack = 2, reach = 1.2, attackCooldown = 1.0,
		followRange = 16, undead = false, neutralInLight = true, canClimb = true,
		drops = { { item = "string", min = 0, max = 2 } },
		spawnWeight = 100, groupMin = 1, groupMax = 3,
	},
	{
		key = "cinderhusk", name = "Cinderhusk", code = 4, category = "hostile", behavior = "exploder",
		health = 20, width = 0.7, height = 1.5, speed = 2.5, attack = 0, reach = 3.0, attackCooldown = 0,
		followRange = 16, undead = false, neutralInLight = false, canClimb = false,
		fuseSeconds = 1.5, explosionPower = 3,
		drops = { { item = "gunpowder", min = 0, max = 2 } },
		spawnWeight = 100, groupMin = 1, groupMax = 3,
	},
	{
		key = "shiftling", name = "Shiftling", code = 5, category = "hostile", behavior = "teleporter",
		health = 40, width = 0.6, height = 2.6, speed = 3.0, attack = 7, reach = 1.2, attackCooldown = 1.0,
		followRange = 24, undead = false, neutralInLight = true, canClimb = false,
		drops = { { item = "rift_shard", min = 0, max = 1 } },
		spawnWeight = 10, groupMin = 1, groupMax = 2,
	},
	{
		key = "cow", name = "Cow", code = 10, category = "passive", behavior = "wander",
		health = 10, width = 0.9, height = 1.4, speed = 2.0, attack = 0, reach = 0, attackCooldown = 0,
		followRange = 0, undead = false, neutralInLight = false, canClimb = false,
		drops = { { item = "raw_beef", min = 1, max = 3 }, { item = "leather", min = 0, max = 2 } },
		spawnWeight = 8, groupMin = 2, groupMax = 4,
	},
	{
		key = "pig", name = "Pig", code = 11, category = "passive", behavior = "wander",
		health = 10, width = 0.9, height = 0.9, speed = 2.0, attack = 0, reach = 0, attackCooldown = 0,
		followRange = 0, undead = false, neutralInLight = false, canClimb = false,
		drops = { { item = "raw_porkchop", min = 1, max = 3 } },
		spawnWeight = 10, groupMin = 2, groupMax = 4,
	},
	{
		key = "sheep", name = "Sheep", code = 12, category = "passive", behavior = "wander",
		health = 8, width = 0.9, height = 1.3, speed = 2.0, attack = 0, reach = 0, attackCooldown = 0,
		followRange = 0, undead = false, neutralInLight = false, canClimb = false,
		drops = { { item = "white_wool", min = 1, max = 1 }, { item = "raw_mutton", min = 1, max = 2 } },
		spawnWeight = 12, groupMin = 2, groupMax = 4,
	},
	{
		key = "chicken", name = "Chicken", code = 13, category = "passive", behavior = "wander",
		health = 4, width = 0.4, height = 0.7, speed = 2.0, attack = 0, reach = 0, attackCooldown = 0,
		followRange = 0, undead = false, neutralInLight = false, canClimb = false,
		drops = { { item = "raw_chicken", min = 1, max = 1 }, { item = "feather", min = 0, max = 2 } },
		spawnWeight = 10, groupMin = 2, groupMax = 4,
	},
	{
		key = "arrow", name = "Arrow", code = 20, category = "projectile", behavior = "projectile",
		health = 1, width = 0.2, height = 0.2, speed = 0, attack = 0, reach = 0, attackCooldown = 0,
		followRange = 0, undead = false, neutralInLight = false, canClimb = false,
		drops = {}, spawnWeight = 0, groupMin = 0, groupMax = 0,
	},
}

local MobDefs = {}
MobDefs.list = list
MobDefs.byKey = {} :: { [string]: MobDef }
MobDefs.byCode = {} :: { [number]: MobDef }
for _, d in list do
	assert(not MobDefs.byKey[d.key] and not MobDefs.byCode[d.code], `MobDefs: duplicate {d.key}`)
	MobDefs.byKey[d.key] = d
	MobDefs.byCode[d.code] = d
end

return MobDefs
