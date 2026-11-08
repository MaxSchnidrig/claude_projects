--!strict
-- Falling blocks (sand, gravel) and primed TNT, Java Edition rules:
--   falling   a gravity block with free space below (air, fire, fluid) becomes a falling entity
--             2 ticks after a neighbour changes. It falls with gravity 0.04 blocks/tick^2 and
--             drag 0.98; when it lands it becomes a block again, or drops as an item if its
--             landing spot is taken (e.g. by a torch)
--   TNT       lit by fire, flint and steel or an explosion; 80-tick fuse (explosions: 10-29
--             ticks), a small hop when lit, gravity and drag like above, bounces softly; explodes
--             with power 4. In water it doesn't break blocks.
-- Clients get a spawn event and simulate the same motion; a remove event ends it.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared.Config)
local Remotes = require(Shared.Net.Remotes)
local BlockRegistry = require(Shared.Blocks.BlockRegistry)
local Shapes = require(Shared.Blocks.Shapes)
local MobPhysics = require(Shared.Mobs.MobPhysics)
local WorldService = require(script.Parent.Parent.World.WorldService)
local BlockUpdates = require(script.Parent.Parent.World.BlockUpdates)
local ItemEntityService = require(script.Parent.Parent.World.ItemEntityService)
local ExplosionService = require(script.Parent.Parent.World.ExplosionService)

local BS = Config.BLOCK_SIZE
local TNT = BlockRegistry.id("tnt")
local FIRE = BlockRegistry.id("fire")
local isSolid = BlockRegistry.isSolid
local isLiquid = BlockRegistry.isLiquid

local EntityService = {}
EntityService.stats = { falling = 0, tnt = 0 }

type Entity = { id: number, kind: string, block: number, x: number, y: number, z: number, vx: number, vy: number, vz: number, fuse: number }
local entities: { [number]: Entity } = {}
local nextId = 1

local function solid(x: number, y: number, z: number): boolean
	local id = WorldService.getBlockIfLoaded(x, y, z)
	return id == nil or isSolid[id + 1]
end

local shapeSolid = Shapes.physicsFn(WorldService.getBlockIfLoaded)

-- Room to fall into (Java FallingBlock.isFree): air, fire or fluid.
local function free(id: number?): boolean
	return id ~= nil and (id == 0 or id == FIRE or isLiquid[id + 1])
end

local function broadcast(e: { [string]: any })
	local remote = Remotes.get("EntityEvent")
	for _, p in Players:GetPlayers() do
		remote:FireClient(p, e)
	end
end

local function spawn(kind: string, block: number, x: number, y: number, z: number, vx: number, vy: number, vz: number, fuse: number): Entity
	local e: Entity = { id = nextId, kind = kind, block = block, x = x, y = y, z = z, vx = vx, vy = vy, vz = vz, fuse = fuse }
	nextId = nextId % 1000000 + 1
	entities[e.id] = e
	broadcast({ type = "spawn", id = e.id, kind = kind, block = block, pos = Vector3.new(x, y, z), vel = Vector3.new(vx, vy, vz), fuse = fuse })
	return e
end

local function remove(e: Entity)
	entities[e.id] = nil
	broadcast({ type = "remove", id = e.id, pos = Vector3.new(e.x, e.y, e.z) })
end

-- Light TNT at a block position (the block itself must already be gone).
function EntityService.primeTnt(x: number, y: number, z: number, fuse: number?)
	local angle = math.random() * math.pi * 2
	spawn("tnt", TNT, x + 0.5, y, z + 0.5, -math.sin(angle) * 0.02, 0.2, -math.cos(angle) * 0.02, fuse or 80)
end

-- Light a TNT block in the world (flint and steel, fire).
function EntityService.igniteBlock(x: number, y: number, z: number)
	if WorldService.getBlockIfLoaded(x, y, z) == TNT then
		BlockUpdates.set(x, y, z, 0)
		EntityService.primeTnt(x, y, z)
	end
end

local function step(e: Entity)
	-- Java entity tick: gravity, move with collisions, drag
	e.vy -= 0.04
	local nx, ny, nz, rvx, rvy, rvz, onGround = MobPhysics.move(shapeSolid, e.x, e.y, e.z, e.vx * 20, e.vy * 20, e.vz * 20, 0.98, 0.98, 0.05)
	e.x, e.y, e.z = nx, ny, nz
	e.vx, e.vy, e.vz = rvx / 20 * 0.98, rvy / 20 * 0.98, rvz / 20 * 0.98
	if e.y < -64 then
		remove(e)
		return
	end
	if e.kind == "falling" then
		if onGround then
			local bx, by, bz = math.floor(e.x), math.floor(e.y + 0.01), math.floor(e.z)
			remove(e)
			local here = WorldService.getBlockIfLoaded(bx, by, bz)
			if free(here) then
				BlockUpdates.set(bx, by, bz, e.block)
			else
				local def = BlockRegistry.byId[e.block]
				if def and def.drop then
					ItemEntityService.spawn({ item = def.drop, count = 1 }, Vector3.new(e.x, e.y + 0.5, e.z) * BS)
				end
			end
		end
	else
		if onGround then
			e.vx *= 0.7
			e.vz *= 0.7
			e.vy *= -0.5
		end
		e.fuse -= 1
		if e.fuse <= 0 then
			remove(e)
			local center = Vector3.new(e.x, e.y + 0.0625, e.z)
			local here = WorldService.getBlockIfLoaded(math.floor(center.X), math.floor(center.Y), math.floor(center.Z))
			local inWater = here ~= nil and isLiquid[here + 1]
			ExplosionService.explode(center, 4, "was blown up by TNT", { breakBlocks = not inWater })
		end
	end
end

function EntityService.init()
	ExplosionService.setTntHook(function(x, y, z)
		EntityService.primeTnt(x, y, z, math.random(0, 19) + 10)
	end)
	BlockUpdates.register("fall", function(x, y, z)
		local id = WorldService.getBlockIfLoaded(x, y, z)
		local def = id and BlockRegistry.byId[id]
		if def and def.gravity and y > 0 and free(WorldService.getBlockIfLoaded(x, y - 1, z)) then
			BlockUpdates.set(x, y, z, 0)
			spawn("falling", id :: number, x + 0.5, y, z + 0.5, 0, 0, 0, 0)
		end
	end)
	BlockUpdates.onNeighbourChanged(function(x, y, z)
		local id = WorldService.getBlockIfLoaded(x, y, z)
		local def = id and BlockRegistry.byId[id]
		if def and def.gravity then
			BlockUpdates.schedule(x, y, z, 2, "fall")
		end
	end)
	BlockUpdates.onTick(function()
		local nf, nt = 0, 0
		for _, e in entities do
			step(e)
			if e.kind == "falling" then
				nf += 1
			else
				nt += 1
			end
		end
		EntityService.stats.falling, EntityService.stats.tnt = nf, nt
	end)
	-- late joiners see entities already in flight
	Players.PlayerAdded:Connect(function(p)
		task.wait(2)
		for _, e in entities do
			Remotes.get("EntityEvent"):FireClient(p, { type = "spawn", id = e.id, kind = e.kind, block = e.block,
				pos = Vector3.new(e.x, e.y, e.z), vel = Vector3.new(e.vx, e.vy, e.vz), fuse = e.fuse })
		end
	end)
end

return EntityService
