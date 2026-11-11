--!strict
-- Beds, sleeping and respawn points (Phase 8c), with Java rules:
--   * right-clicking a bed sets your respawn point there ("Respawn point set")
--   * you can sleep from tick 12542 to 23459 of the day (no thunderstorms yet); not when the bed
--     is too far (3 blocks across, 2 up / down), obstructed (a solid block above the head), taken,
--     or a monster is within 8 blocks across / 5 up or down of the bed
--   * when every player in the world sleeps for 100 ticks the night is skipped to the next
--     morning; sleeping resets the "time since rest" counter (phantoms, phase 14)
--   * respawning goes to the bed if it still exists and has a free spot next to it; otherwise the
--     world spawn and "You have no home bed or charged respawn anchor, or it was obstructed"

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared.Config)
local Remotes = require(Shared.Net.Remotes)
local BlockRegistry = require(Shared.Blocks.BlockRegistry)
local Placement = require(Shared.Blocks.Placement)
local Shapes = require(Shared.Blocks.Shapes)
local WorldService = require(script.Parent.Parent.World.WorldService)
local SpawnService = require(script.Parent.SpawnService)
local DayNightService = require(script.Parent.Parent.Survival.DayNightService)

local BS = Config.BLOCK_SIZE
local BedService = {}

type Sleep = { head: Vector3, since: number }
local sleeping: { [Player]: Sleep } = {}
local spawns: { [Player]: Vector3 } = {} -- bed head block
local rest: { [Player]: number } = {} -- ticks since last rest
local MobService: any = nil

local function remote(): RemoteEvent
	return Remotes.get("Bed")
end

local function message(p: Player, text: string)
	remote():FireClient(p, { type = "message", text = text })
end

local function bedDef(id: number?): any
	local d = id and BlockRegistry.byId[id]
	return if d and d.shape == "bed" then d else nil
end

-- The head cell of the bed at (x, y, z), or nil.
local function headOf(x: number, y: number, z: number): Vector3?
	local id = WorldService.getBlock(x, y, z)
	local d = bedDef(id)
	if not d then
		return nil
	end
	if d.state.part == "head" then
		return Vector3.new(x, y, z)
	end
	local hx, hy, hz = Placement.bedPartner(id, x, y, z)
	if bedDef(WorldService.getBlock(hx, hy, hz)) then
		return Vector3.new(hx, hy, hz)
	end
	return nil
end

local function free(x: number, y: number, z: number): boolean
	local id = WorldService.getBlock(x, y, z)
	return id ~= nil and not BlockRegistry.isSolid[id + 1] and not BlockRegistry.isLiquid[id + 1]
end

-- Java BedBlock.findStandUpPosition (simplified): a cell around the bed with a floor and two free
-- blocks above it, nearest the head first. Feet position (block units) or nil.
local function standUpSpot(head: Vector3): Vector3?
	local id = WorldService.getBlock(head.X, head.Y, head.Z)
	local d = bedDef(id)
	if not d then
		return nil
	end
	local fx, _, fz = Placement.bedPartner(id, head.X, head.Y, head.Z)
	local candidates = {}
	for _, base in { head, Vector3.new(fx, head.Y, fz) } do
		for dx = -1, 1 do
			for dz = -1, 1 do
				for dy = 0, 1 do
					table.insert(candidates, base + Vector3.new(dx, dy, dz))
				end
			end
		end
	end
	for _, c in candidates do
		local below = WorldService.getBlock(c.X, c.Y - 1, c.Z)
		if below and BlockRegistry.isSolid[below + 1] and free(c.X, c.Y, c.Z) and free(c.X, c.Y + 1, c.Z) then
			return Vector3.new(c.X + 0.5, c.Y, c.Z + 0.5)
		end
	end
	return nil
end

local function rootOf(p: Player): BasePart?
	local c = p.Character
	return c and c:FindFirstChild("HumanoidRootPart") :: BasePart?
end

local function wake(p: Player, reason: string?)
	local s = sleeping[p]
	if not s then
		return
	end
	sleeping[p] = nil
	local root = rootOf(p)
	local spot = standUpSpot(s.head) or s.head + Vector3.new(0.5, 1, 0.5)
	if root then
		-- move it while we still hold it, then let go; the client's movement code is also told
		-- the spot (it never reads the body's position back on its own)
		root.CFrame = CFrame.new(spot.X * BS, spot.Y * BS + 3.05, spot.Z * BS)
		root.Anchored = false
	end
	remote():FireClient(p, { type = "wake", reason = reason, pos = spot + Vector3.new(0, 0.05 / BS, 0) })
end

local function tryUse(p: Player, x: number, y: number, z: number)
	local root = rootOf(p)
	local head = headOf(x, y, z)
	if not root or not head then
		return
	end
	local feet = (root.Position - Vector3.new(0, 3, 0)) / BS
	local c = head + Vector3.new(0.5, 0, 0.5)
	-- Java isReachableBedBlock: within 3 blocks across and 2 up / down of the bed
	if math.abs(feet.X - c.X) > 3.5 or math.abs(feet.Y - c.Y) > 2.5 or math.abs(feet.Z - c.Z) > 3.5 then
		return message(p, "You may not rest now; the bed is too far away")
	end
	local above = WorldService.getBlock(head.X, head.Y + 1, head.Z)
	if above and BlockRegistry.isSolid[above + 1] and BlockRegistry.isCube[above + 1] then
		return message(p, "This bed is obstructed")
	end
	-- the respawn point is set even in the daytime (Java 1.15+)
	local prev = spawns[p]
	if not prev or prev ~= head then
		spawns[p] = head
		message(p, "Respawn point set")
	end
	local t = DayNightService.timeOfDay()
	if t < 12542 or t > 23459 then
		return message(p, "You can only sleep at night and during thunderstorms")
	end
	for other, s in sleeping do
		if other ~= p and s.head == head then
			return message(p, "This bed is occupied")
		end
	end
	if MobService and MobService.anyIn("hostile", c - Vector3.new(8, 5, 8), c + Vector3.new(8, 5, 8)) then
		return message(p, "You may not rest now; there are monsters nearby")
	end
	-- lie down on the bed (anchored; the client lowers the camera)
	local id = WorldService.getBlock(head.X, head.Y, head.Z)
	local d = bedDef(id)
	local v = Shapes.DIR[d.state.facing :: string]
	local dir = Vector3.new(v[1], 0, v[2])
	local mid = (head + Vector3.new(0.5, 0.6, 0.5) - dir * 0.5) * BS
	root.Anchored = true
	root.AssemblyLinearVelocity = Vector3.zero
	-- body along the bed, head on the pillow
	root.CFrame = CFrame.lookAt(mid, mid + Vector3.yAxis, dir) * CFrame.Angles(0, 0, 0)
	sleeping[p] = { head = head, since = os.clock() }
	remote():FireClient(p, { type = "sleep", x = head.X, y = head.Y, z = head.Z, facing = d.state.facing })
end

-- Persistence --------------------------------------------------------------------------------------

function BedService.spawnOf(p: Player): Vector3?
	return spawns[p]
end

function BedService.sinceRest(p: Player): number
	return math.floor(rest[p] or 0)
end

function BedService.restore(p: Player, bed: Vector3?, sinceRest: number)
	spawns[p] = bed
	rest[p] = sinceRest
end

function BedService.isSleeping(p: Player): boolean
	return sleeping[p] ~= nil
end

function BedService.init()
	MobService = require(script.Parent.Parent.Mobs.MobService)
	remote().OnServerEvent:Connect(function(p: Player, m: any)
		if typeof(m) ~= "table" then
			return
		end
		if m.type == "use" and typeof(m.x) == "number" and typeof(m.y) == "number" and typeof(m.z) == "number" then
			if not sleeping[p] then
				tryUse(p, math.floor(m.x), math.floor(m.y), math.floor(m.z))
			end
		elseif m.type == "leave" then
			wake(p)
		end
	end)

	SpawnService.setRespawnResolver(function(p: Player): CFrame?
		local head = spawns[p]
		if not head then
			return nil
		end
		local spot = if headOf(head.X, head.Y, head.Z) then standUpSpot(head) else nil
		if not spot then
			spawns[p] = nil
			task.delay(1, message, p, "You have no home bed or charged respawn anchor, or it was obstructed")
			return nil
		end
		return CFrame.new(spot.X * BS, spot.Y * BS + 3.05, spot.Z * BS)
	end)

	-- sleeping: everyone asleep for 100 ticks skips the night; a broken bed, a monster attack
	-- (damage) or the morning wakes you
	local acc = 0
	RunService.Heartbeat:Connect(function(dt)
		for _, p in Players:GetPlayers() do
			rest[p] = (rest[p] or 0) + dt * 20
		end
		acc += dt
		if acc < 0.25 then
			return
		end
		acc = 0
		local all = #Players:GetPlayers() > 0
		local longEnough = true
		for _, p in Players:GetPlayers() do
			local s = sleeping[p]
			if not s then
				all = false
			elseif os.clock() - s.since < 5 then
				longEnough = false
			end
		end
		for p, s in sleeping do
			local h = p.Character and p.Character:FindFirstChildOfClass("Humanoid")
			if not p.Parent or not h or h.Health <= 0 then
				sleeping[p] = nil
			elseif not headOf(s.head.X, s.head.Y, s.head.Z) then
				wake(p)
			end
		end
		if all and longEnough then
			-- Java: the time jumps to the next morning (tick 0 of the next day)
			local t = DayNightService.ticks()
			DayNightService.addTicks(24000 - t % 24000)
			for p in sleeping do
				rest[p] = 0
				wake(p)
			end
		elseif not all then
			local t = DayNightService.timeOfDay()
			if t < 12542 or t > 23459 then
				for p in sleeping do
					wake(p)
				end
			end
		end
	end)
	Players.PlayerRemoving:Connect(function(p)
		sleeping[p] = nil
		spawns[p] = nil
		rest[p] = nil
	end)
end

-- Hurt while asleep wakes you (SurvivalService calls this).
function BedService.onHurt(p: Player)
	if sleeping[p] then
		wake(p)
	end
end

return BedService
