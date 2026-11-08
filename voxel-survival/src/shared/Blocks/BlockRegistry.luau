--!strict
--!native
-- Block registry: turns BlockDefs into fast lookup tables.
--
-- Hot loops (generation, meshing) use the flat arrays (isSolid, isOpaque, faceTexture...) indexed
-- by block ID, never the def tables, to avoid hash lookups per block.

local BlockDefs = require(script.Parent.BlockDefs)
local TexturePalette = require(script.Parent.TexturePalette)

export type BlockDef = {
	id: number,
	key: string,
	name: string,
	hardness: number,
	tool: string?,
	minTier: number,
	drop: string?, -- nil = drops nothing
	dropMin: number,
	dropMax: number,
	solid: boolean,
	transparent: boolean,
	liquid: boolean,
	cullSelf: boolean,
	bonusDrops: { { item: string, chance: number } },
	-- texture index per face direction (see Directions below)
	faceTexture: { number },
	light: number, -- emitted light 0-15
	sound: string, -- sound group (Audio/SoundConfig)
	shape: string, -- "cube" | "torch" | "wall_torch" | "fire" | "campfire"
	facing: string?, -- wall torches
	fluid: string?,
	fluidLevel: number?,
	gravity: boolean,
	flammable: { number }?,
	altDrop: { item: string, chance: number }?,
}

local BlockRegistry = {}

-- Face directions. Index order is used everywhere (mesher, raycast normals).
-- +Z is "south", -Z is "north", +X "east", -X "west" (matches the usual voxel-game convention).
BlockRegistry.Dir = {
	EAST = 1, -- +X
	WEST = 2, -- -X
	TOP = 3, -- +Y
	BOTTOM = 4, -- -Y
	SOUTH = 5, -- +Z
	NORTH = 6, -- -Z
}
BlockRegistry.DIR_NAMES = { "east", "west", "top", "bottom", "south", "north" }
BlockRegistry.DIR_VECTORS = {
	{ 1, 0, 0 },
	{ -1, 0, 0 },
	{ 0, 1, 0 },
	{ 0, -1, 0 },
	{ 0, 0, 1 },
	{ 0, 0, -1 },
}

BlockRegistry.AIR = 0
BlockRegistry.MAX_ID = 4095 -- ids are stored as u16; 4095 keeps the lookup arrays small

-- Texture registry: texture key <-> numeric index (1-based). Index 0 means "no face".
local textureKeys: { string } = {}
local textureIndex: { [string]: number } = {}
local function texId(key: string): number
	local idx = textureIndex[key]
	if idx then
		return idx
	end
	assert(TexturePalette[key], `BlockRegistry: texture '{key}' has no entry in TexturePalette`)
	table.insert(textureKeys, key)
	idx = #textureKeys
	textureIndex[key] = idx
	return idx
end
BlockRegistry.textureKeys = textureKeys
BlockRegistry.textureIndex = textureIndex

-- Flat lookup arrays, indexed by block id (0..MAX_ID). Air (0) is non-solid, transparent.
local byId: { [number]: BlockDef } = {}
local byKey: { [string]: BlockDef } = {}
local isSolid = table.create(4096, false) :: { boolean }
local isOpaque = table.create(4096, false) :: { boolean }
local isLiquid = table.create(4096, false) :: { boolean }
local cullSelf = table.create(4096, true) :: { boolean }
local isTransparentGroup = table.create(4096, false) :: { boolean }
local lightEmission = table.create(4096, 0) :: { number }
local lightOpacity = table.create(4096, 0) :: { number }
local isCube = table.create(4096, true) :: { boolean }

-- Sound group when a block doesn't name one: by its preferred tool.
local SOUND_BY_TOOL = { pickaxe = "stone", axe = "wood", shovel = "gravel", hoe = "grass", shears = "wool" }

for _, d in BlockDefs do
	assert(d.id > 0 and d.id <= BlockRegistry.MAX_ID, `BlockRegistry: bad id {d.id} for {d.key}`)
	assert(byId[d.id] == nil, `BlockRegistry: duplicate id {d.id} ({d.key})`)
	assert(byKey[d.key] == nil, `BlockRegistry: duplicate key {d.key}`)

	local t = d.textures
	local top = t.top or t.all
	local side = t.side or t.all
	local bottom = t.bottom or t.all
	assert(top and side and bottom, `BlockRegistry: incomplete textures for {d.key}`)

	local drop: string?
	if d.drop == nil then
		drop = d.key -- drops itself
	elseif d.drop == false then
		drop = nil
	else
		drop = d.drop :: string
	end

	local sideTex = texId(side)
	local def: BlockDef = {
		id = d.id,
		key = d.key,
		name = d.name,
		hardness = d.hardness,
		tool = d.tool,
		minTier = d.minTier or 0,
		drop = drop,
		dropMin = d.dropMin or 1,
		dropMax = d.dropMax or d.dropMin or 1,
		solid = if d.solid == nil then true else d.solid,
		transparent = d.transparent == true,
		liquid = d.liquid == true,
		cullSelf = if d.cullSelf == nil then true else d.cullSelf,
		bonusDrops = d.bonusDrops or {},
		faceTexture = { sideTex, sideTex, texId(top), texId(bottom), sideTex, sideTex },
		light = d.light or 0,
		sound = d.sound or (d.tool and SOUND_BY_TOOL[d.tool]) or "stone",
		shape = d.shape or "cube",
		facing = d.facing,
		fluid = d.fluid,
		fluidLevel = d.fluidLevel,
		gravity = d.gravity == true,
		flammable = d.flammable,
		altDrop = d.altDrop,
	}
	byId[d.id] = def
	byKey[d.key] = def
	-- arrays are 1-based in Luau; store at id + 1 so id 0 (air) has a slot
	isSolid[d.id + 1] = def.solid
	isOpaque[d.id + 1] = def.solid and not def.transparent
	isLiquid[d.id + 1] = def.liquid
	cullSelf[d.id + 1] = def.cullSelf
	isTransparentGroup[d.id + 1] = def.transparent
	lightEmission[d.id + 1] = def.light
	lightOpacity[d.id + 1] = d.opacity or (if isOpaque[d.id + 1] then 15 else 0)
	isCube[d.id + 1] = def.shape == "cube"
end

BlockRegistry.byId = byId
BlockRegistry.byKey = byKey
-- NOTE: these arrays are indexed by (id + 1).
BlockRegistry.isSolid = isSolid
BlockRegistry.isOpaque = isOpaque
BlockRegistry.isLiquid = isLiquid
BlockRegistry.cullSelf = cullSelf
BlockRegistry.isTransparent = isTransparentGroup
BlockRegistry.lightEmission = lightEmission
BlockRegistry.lightOpacity = lightOpacity
BlockRegistry.isCube = isCube

-- Look up an ID by key; errors on typos so mistakes surface at load time.
function BlockRegistry.id(key: string): number
	local d = byKey[key]
	assert(d, `BlockRegistry: unknown block '{key}'`)
	return d.id
end

function BlockRegistry.get(id: number): BlockDef?
	return byId[id]
end

-- RGB (0-255) placeholder colour for a texture index.
function BlockRegistry.textureColor(texIndex: number): { number }
	return TexturePalette[textureKeys[texIndex]]
end

return BlockRegistry
