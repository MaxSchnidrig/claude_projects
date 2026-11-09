--!strict
-- Block particles: small squares in colours taken from the block's own texture pixels.
--   breakBlock  a 3x3x3 burst when a block breaks
--   dig         one or two flecks from the face being mined, every dig tick
-- Particles are pooled anchored Parts moved by hand (gravity, drag, they stop on solid ground),
-- so no physics bodies are created.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared.Config)
local BlockRegistry = require(Shared.Blocks.BlockRegistry)
local TextureAtlas = require(script.Parent.TextureAtlas)
local Shapes = require(Shared.Blocks.Shapes)

local BS = Config.BLOCK_SIZE
local GRAVITY = 0.04 * 20 * 20 * BS -- Java particle gravity 0.04 blocks/tick^2, in studs/s^2
local MAX = 160

local Particles = {}

type P = { part: Part, vel: Vector3, life: number, alive: boolean, resting: boolean }
local pool: { P } = {}
local active: { P } = {}
local folder: Folder
local getBlock: ((number, number, number) -> number?)? = nil

local function take(): P?
	local p = table.remove(pool)
	if p then
		return p
	end
	if #active >= MAX then
		return nil
	end
	local part = Instance.new("Part")
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.CastShadow = false
	part.Material = Enum.Material.SmoothPlastic
	part.Parent = folder
	return { part = part, vel = Vector3.zero, life = 0, alive = false, resting = false }
end

local function emit(pos: Vector3, vel: Vector3, color: Color3, size: number, life: number)
	local p = take()
	if not p then
		return
	end
	p.part.Color = color
	p.part.Size = Vector3.one * size
	p.part.CFrame = CFrame.new(pos)
	p.part.Transparency = 0
	p.vel = vel
	p.life = life
	p.alive = true
	p.resting = false
	table.insert(active, p)
end

local function texOf(id: number, dir: number?): number
	local def = BlockRegistry.byId[id]
	return if def then def.faceTexture[dir or BlockRegistry.Dir.TOP] else 0
end

-- The part of the cell a block fills (a slab's half, a fence's post and rails...). The block
-- may already be gone (break effects run after it), so `id` is passed in.
local function boundsOf(x: number, y: number, z: number, id: number): (Vector3, Vector3)
	if not BlockRegistry.isBoxShape[id + 1] then
		return Vector3.zero, Vector3.one
	end
	local gb = getBlock
	return Shapes.bounds(Shapes.boxes(id, function(dx, dy, dz)
		return if gb then gb(x + dx, y + dy, z + dz) else 0
	end, false))
end

function Particles.breakBlock(x: number, y: number, z: number, id: number)
	local tex = texOf(id, BlockRegistry.Dir.EAST)
	local lo, hi = boundsOf(x, y, z, id)
	for i = 0, 2 do
		for j = 0, 2 do
			for k = 0, 2 do
				local local3 = Vector3.new((i + 0.5) / 3, (j + 0.5) / 3, (k + 0.5) / 3)
				local pos = (Vector3.new(x, y, z) + lo + (hi - lo) * local3) * BS
				local out = (local3 - Vector3.new(0.5, 0.5, 0.5)) * 2
				local vel = (out * 0.08 + Vector3.new((math.random() - 0.5) * 0.08, math.random() * 0.1, (math.random() - 0.5) * 0.08)) * 20 * BS
				emit(pos, vel, TextureAtlas.randomColor(tex), BS * (0.08 + math.random() * 0.06), 0.5 + math.random() * 0.7)
			end
		end
	end
end

-- Flecks from the mined face: `normal` points out of the face towards the player.
function Particles.dig(x: number, y: number, z: number, id: number, normal: Vector3)
	local tex = texOf(id, BlockRegistry.Dir.EAST)
	local lo, hi = boundsOf(x, y, z, id)
	for _ = 1, 2 do
		local r = lo + (hi - lo) * Vector3.new(math.random(), math.random(), math.random())
		local p = Vector3.new(
			if normal.X ~= 0 then (if normal.X > 0 then hi.X + 0.02 else lo.X - 0.02) else r.X,
			if normal.Y ~= 0 then (if normal.Y > 0 then hi.Y + 0.02 else lo.Y - 0.02) else r.Y,
			if normal.Z ~= 0 then (if normal.Z > 0 then hi.Z + 0.02 else lo.Z - 0.02) else r.Z
		)
		local pos = (Vector3.new(x, y, z) + p) * BS
		local vel = (normal * 0.05 + Vector3.new((math.random() - 0.5) * 0.04, math.random() * 0.06, (math.random() - 0.5) * 0.04)) * 20 * BS
		emit(pos, vel, TextureAtlas.randomColor(tex), BS * (0.06 + math.random() * 0.05), 0.4 + math.random() * 0.4)
	end
end

function Particles.init(blockAt: (number, number, number) -> number?)
	getBlock = blockAt
	local f = Instance.new("Folder")
	f.Name = "Particles"
	f.Parent = workspace
	folder = f
	RunService.Heartbeat:Connect(function(dt)
		local i = 1
		while i <= #active do
			local p = active[i]
			p.life -= dt
			if p.life <= 0 then
				p.part.Transparency = 1
				p.alive = false
				table.insert(pool, p)
				active[i] = active[#active]
				active[#active] = nil
			else
				if not p.resting then
					p.vel = Vector3.new(p.vel.X * 0.98 ^ (dt * 20), p.vel.Y - GRAVITY * dt, p.vel.Z * 0.98 ^ (dt * 20))
					local pos = p.part.Position + p.vel * dt
					local gb = getBlock
					if gb then
						local id = gb(math.floor(pos.X / BS), math.floor(pos.Y / BS), math.floor(pos.Z / BS))
						if id ~= nil and BlockRegistry.isSolid[id + 1] then
							p.resting = true -- landed on a block
							pos = p.part.Position
						end
					end
					p.part.CFrame = CFrame.new(pos)
				end
				i += 1
			end
		end
	end)
end

return Particles
