--!strict
-- Explosions (Sneaker; TNT later). Classic rules, simplified:
--   * blocks within a randomised radius (power x 0.7..1.3) are destroyed, except very blast-resistant
--     ones (bedrock, obsidian, liquids); each destroyed block drops its item with chance 1/power
--   * entities within 2 x power blocks take damage: Combat.explosionDamage(power, distance), and are
--     knocked away from the centre
-- No occlusion rays (walls don't shield you) yet.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared.Config)
local Remotes = require(Shared.Net.Remotes)
local BlockRegistry = require(Shared.Blocks.BlockRegistry)
local Combat = require(Shared.Gameplay.Combat)
local WorldService = require(script.Parent.WorldService)
local ItemEntityService = require(script.Parent.ItemEntityService)
local ChunkStreamer = require(script.Parent.ChunkStreamer)
local BlockEntityService = require(script.Parent.BlockEntityService)

local BS = Config.BLOCK_SIZE
local RESISTANT = {
	[BlockRegistry.id("bedrock")] = true,
	[BlockRegistry.id("obsidian")] = true,
}

local ExplosionService = {}

-- Hooks set by other services (avoid require cycles).
local damagePlayer: ((Player, number, string) -> ())? = nil
local damageMobs: ((center: Vector3, power: number) -> ())? = nil
local primeTnt: ((x: number, y: number, z: number) -> ())? = nil
local TNT = BlockRegistry.id("tnt")

-- Explosions don't destroy TNT: they light it with a short fuse (EntityService).
function ExplosionService.setTntHook(fn: (x: number, y: number, z: number) -> ())
	primeTnt = fn
end
function ExplosionService.setHooks(playerDamage: (Player, number, string) -> (), mobDamage: (Vector3, number) -> ())
	damagePlayer = playerDamage
	damageMobs = mobDamage
end

-- `center` in BLOCK units.
export type Options = { breakBlocks: boolean? }

function ExplosionService.explode(center: Vector3, power: number, cause: string, opts: Options?)
	-- the flash for everyone nearby
	for _, p in Players:GetPlayers() do
		Remotes.get("MobEvent"):FireClient(p, { type = "explode", pos = center * BS })
	end
	-- 1. blocks (not when the explosion is in water: Java's water absorbs the blast)
	local breakBlocks = not opts or opts.breakBlocks ~= false
	local r = math.ceil(power * 1.3)
	local cx, cy, cz = math.floor(center.X), math.floor(center.Y), math.floor(center.Z)
	local changed: { { number } } = {}
	for x = cx - r, cx + r do
		for y = math.max(1, cy - r), math.min(Config.WORLD_HEIGHT - 1, cy + r) do
			for z = cz - r, cz + r do
				local id = WorldService.getBlockIfLoaded(x, y, z)
				if breakBlocks and id == TNT and primeTnt then
					local d = (Vector3.new(x + 0.5, y + 0.5, z + 0.5) - center).Magnitude
					if d <= power then
						WorldService.setBlock(x, y, z, 0)
						table.insert(changed, { x, y, z })
						primeTnt(x, y, z)
					end
				elseif breakBlocks and id and id ~= 0 and not RESISTANT[id] and not BlockRegistry.isLiquid[id + 1] then
					local d = (Vector3.new(x + 0.5, y + 0.5, z + 0.5) - center).Magnitude
					if d <= power * (0.7 + math.random() * 0.6) then
						WorldService.setBlock(x, y, z, 0)
						table.insert(changed, { x, y, z })
						local def = BlockRegistry.get(id)
						local pos = Vector3.new(x + 0.5, y + 0.5, z + 0.5) * BS
						if def and def.drop and math.random() < 1 / power then
							ItemEntityService.spawn({ item = def.drop, count = 1 }, pos)
						end
						if BlockEntityService.kindOf(id) then
							ItemEntityService.spawnAround(BlockEntityService.remove(x, y, z), pos)
						end
					end
				end
			end
		end
	end
	-- tell clients that have those chunks
	local remote = Remotes.get("BlockChanged")
	local byPlayer: { [Player]: boolean } = {}
	for _, c in changed do
		local ccx, ccz = c[1] // Config.CHUNK_SIZE, c[3] // Config.CHUNK_SIZE
		local key = (ccx + 1048576) * 2097152 + (ccz + 1048576)
		for _, p in ChunkStreamer.playersWithChunk(key) do
			remote:FireClient(p, c[1], c[2], c[3], 0)
			byPlayer[p] = true
		end
	end

	-- 2. players
	for _, p in Players:GetPlayers() do
		local character = p.Character
		local root = character and character:FindFirstChild("HumanoidRootPart") :: BasePart?
		if root then
			local pos = root.Position / BS
			local d = (pos - center).Magnitude
			local dmg = Combat.explosionDamage(power, d)
			if dmg > 0 then
				if damagePlayer then
					(damagePlayer :: (Player, number, string) -> ())(p, dmg, cause)
				end
				local dir = (pos - center)
				dir = if dir.Magnitude > 0.01 then dir.Unit else Vector3.yAxis
				-- Java: velocity += direction * impact (blocks/tick), on top of the damage
				local impact = 1 - d / (2 * power)
				Remotes.get("Knockback"):FireClient(p, { add = dir * impact })
			end
		end
	end
	-- 3. mobs
	if damageMobs then
		(damageMobs :: (Vector3, number) -> ())(center, power)
	end
	return byPlayer
end

return ExplosionService
