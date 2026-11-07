--!strict
-- Client side of mobs: builds models from server snapshots (MobSnapshot, 10 Hz, unreliable),
-- interpolates them ~150 ms in the past for smooth motion, animates them (walk cycles, spider
-- legs, wing flaps, shiftling shards, cinderhusk fuse glow), shows effects (hurt tint, burning,
-- death topple, teleport and explosion flashes) and answers "which mob is under the crosshair".

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared.Config)
local Remotes = require(Shared.Net.Remotes)
local MobDefs = require(Shared.Mobs.MobDefs)
local MobModels = require(script.Parent.MobModels)
local MobSnapshotCodec = require(Shared.Mobs.MobSnapshotCodec)

local BS = Config.BLOCK_SIZE
local INTERP_DELAY = 0.15
local FLAG = { BURNING = 1, FUSING = 2, ANGRY = 4, PANIC = 8, STUCK = 32 }

type Sample = { t: number, pos: Vector3, yaw: number, pitch: number, flags: number }
type Mob = {
	id: number,
	def: MobDefs.MobDef,
	built: MobModels.Built,
	samples: { Sample },
	lastSeen: number,
	pos: Vector3, -- current rendered feet position (studs)
	yaw: number,
	pitch: number,
	flags: number,
	walkPhase: number,
	hurtUntil: number,
	dying: number?, -- time of death
	fire: Fire?,
	walkSpeed: number?,
	flagsAirborne: boolean?,
}

local MobClient = {}
MobClient.count = 0
-- Diagnostics for F3: mobs the client knows about vs. mobs with a model in the world.
MobClient.stats = { packets = 0, known = 0, visible = 0, buildErrors = 0, lastBuildError = "" }

local mobs: { [number]: Mob } = {}
local folder: Folder

local function lerpAngle(a: number, b: number, t: number): number
	local d = (b - a + math.pi) % (2 * math.pi) - math.pi
	return a + d * t
end

local function create(id: number, def: MobDefs.MobDef, pos: Vector3): Mob?
	local ok, result = pcall(MobModels.build, def.key)
	local built = if ok then result else nil
	if not built then
		MobClient.stats.buildErrors += 1
		local msg = `model for '{def.key}' failed: {if ok then "no design" else tostring(result)}`
		if MobClient.stats.lastBuildError ~= msg then
			warn(`[MobClient] {msg}`)
		end
		MobClient.stats.lastBuildError = msg
		return nil
	end
	built.model.Parent = folder
	local m: Mob = {
		id = id,
		def = def,
		built = built,
		samples = {},
		lastSeen = os.clock(),
		pos = pos,
		yaw = 0,
		pitch = 0,
		flags = 0,
		walkPhase = 0,
		hurtUntil = 0,
		dying = nil,
		fire = nil,
		walkSpeed = 0,
		flagsAirborne = false,
	}
	mobs[id] = m
	return m
end

local function destroy(m: Mob)
	m.built.model:Destroy()
	mobs[m.id] = nil
end

local function flashAt(pos: Vector3, color: Color3, size: number, duration: number)
	local p = Instance.new("Part")
	p.Anchored = true
	p.CanCollide = false
	p.CanQuery = false
	p.CanTouch = false
	p.CastShadow = false
	p.Shape = Enum.PartType.Ball
	p.Material = Enum.Material.Neon
	p.Color = color
	p.Transparency = 0.2
	p.Size = Vector3.one * size * 0.3
	p.CFrame = CFrame.new(pos)
	p.Parent = folder
	TweenService:Create(p, TweenInfo.new(duration), { Size = Vector3.one * size, Transparency = 1 }):Play()
	task.delay(duration, function()
		p:Destroy()
	end)
end

local function onSnapshot(packet: any)
	if typeof(packet) ~= "buffer" then
		return
	end
	MobClient.stats.packets += 1
	local now = os.clock()
	for _, r in MobSnapshotCodec.decode(packet) do
		local pos = Vector3.new(r.x, r.y, r.z)
		local def = MobDefs.byCode[r.code]
		if def then
			local m = mobs[r.id] or create(r.id, def, pos)
			if m and not m.dying then
				m.lastSeen = now
				table.insert(m.samples, { t = now, pos = pos, yaw = r.yaw, pitch = r.pitch, flags = r.flags })
				while #m.samples > 6 do
					table.remove(m.samples, 1)
				end
			end
		end
	end
end

local function onEvent(e: any)
	if typeof(e) ~= "table" then
		return
	end
	local m = mobs[e.id]
	if e.type == "hurt" and m then
		m.hurtUntil = os.clock() + 0.35
	elseif e.type == "died" and m then
		m.dying = os.clock()
	elseif e.type == "teleport" then
		local c = Color3.fromRGB(170, 140, 255)
		if typeof(e.from) == "Vector3" then
			flashAt(e.from + Vector3.new(0, 4, 0), c, 6, 0.4)
		end
		if typeof(e.to) == "Vector3" then
			flashAt(e.to + Vector3.new(0, 4, 0), c, 6, 0.4)
		end
		if m then
			m.samples = {} -- snap to the new place
		end
	elseif e.type == "explode" then
		if typeof(e.pos) == "Vector3" then
			flashAt(e.pos, Color3.fromRGB(255, 200, 120), 24, 0.45)
			-- shake the camera a little if close
			local cam = workspace.CurrentCamera
			local d = (cam.CFrame.Position - e.pos).Magnitude
			if d < 60 then
				task.spawn(function()
					for _ = 1, 8 do
						cam.CFrame *= CFrame.new((math.random() - 0.5) * 0.6, (math.random() - 0.5) * 0.6, 0)
						RunService.RenderStepped:Wait()
					end
				end)
			end
		end
		if m then
			destroy(m)
		end
	end
end

-- Animate one mob's parts for this frame.
local function pose(m: Mob, now: number)
	local def = m.def
	local root = CFrame.new(m.pos) * CFrame.Angles(0, m.yaw, 0)
	if def.key == "arrow" then
		root = CFrame.new(m.pos) * CFrame.Angles(0, m.yaw, 0) * CFrame.Angles(m.pitch, 0, 0)
	elseif def.key == "shiftling" then
		root *= CFrame.new(0, 0.6 + math.sin(now * 2 + m.id) * 0.25, 0) -- floats
	end
	if m.dying then
		local t = math.clamp((now - m.dying) / 0.5, 0, 1)
		root *= CFrame.Angles(0, 0, t * math.pi / 2)
	end
	local fusing = bit32.band(m.flags, FLAG.FUSING) ~= 0
	local angry = bit32.band(m.flags, FLAG.ANGRY) ~= 0
	local hurt = now < m.hurtUntil or m.dying ~= nil
	local swing = math.sin(m.walkPhase)
	local walking = math.clamp(m.walkSpeed or 0, 0, 1)
	for _, info in m.built.parts do
		local b = info.box
		local localCF = info.local0
		local limb = b.limb
		if limb and b.hinge then
			local hinge = b.hinge * BS
			local sign = if (b.phase or 0) == 1 then -1 else 1
			local angle = 0
			if limb == "legL" or limb == "legR" then
				angle = swing * sign * 0.7 * walking
				localCF = CFrame.new(hinge) * CFrame.Angles(angle, 0, 0) * CFrame.new(-hinge) * localCF
			elseif limb == "armL" or limb == "armR" then
				angle = math.rad(b.restPitch or 0) + swing * sign * 0.5 * walking
				localCF = CFrame.new(hinge) * CFrame.Angles(angle, 0, 0) * CFrame.new(-hinge) * localCF
			elseif limb == "legSpider" then
				angle = swing * sign * 0.35 * walking * (b.side or 1)
				localCF = CFrame.new(hinge) * CFrame.Angles(0, angle * 0.6, angle) * CFrame.new(-hinge) * localCF
			elseif limb == "wing" then
				local flap = if walking > 0.1 or m.flagsAirborne then math.abs(math.sin(now * 18)) * 0.9 else 0
				localCF = CFrame.new(hinge) * CFrame.Angles(0, 0, -(b.side or 1) * flap) * CFrame.new(-hinge) * localCF
			end
		elseif limb == "shard" then
			local theta = now * 1.4 + (b.phase or 0) * math.pi * 2
			localCF = CFrame.new(0, math.sin(theta * 1.3) * 0.15 * BS, 0) * CFrame.Angles(0, theta, 0) * localCF
		elseif limb == "carry" then
			localCF = CFrame.new(0, math.sin(now * 3) * 0.05 * BS, 0) * localCF * CFrame.Angles(0, now, 0)
		end
		info.part.CFrame = root * localCF
		-- colour: hurt tint, fuse glow, angry shiftling core
		local color = info.baseColor
		if limb == "fuse" and fusing then
			local pulse = (math.sin(now * 14) + 1) / 2
			color = color:Lerp(Color3.fromRGB(255, 250, 220), 0.4 + pulse * 0.6)
		elseif limb == "core" and angry and b.glow then
			color = Color3.fromRGB(255, 70, 140)
		end
		if hurt then
			color = color:Lerp(Color3.fromRGB(255, 40, 40), 0.55)
		end
		info.part.Color = color
		if m.dying then
			info.part.Transparency = math.clamp((now - m.dying - 0.4) / 0.6, b.transparency or 0, 1)
		end
	end
	-- burning
	local burning = bit32.band(m.flags, FLAG.BURNING) ~= 0 and not m.dying
	local torso = m.built.torso
	if burning and not m.fire and torso then
		local f = Instance.new("Fire")
		f.Size = 4
		f.Heat = 6
		f.Parent = torso
		m.fire = f
	elseif not burning and m.fire then
		(m.fire :: Fire):Destroy()
		m.fire = nil
	end
end

local function update(dt: number)
	local now = os.clock()
	local renderT = now - INTERP_DELAY
	local count = 0
	for _, m in mobs do
		if m.dying then
			if now - m.dying > 1.0 then
				destroy(m)
				continue
			end
		elseif now - m.lastSeen > 1.5 then
			destroy(m) -- left range / despawned
			continue
		end
		count += 1
		local s = m.samples
		if #s > 0 then
			-- find samples around renderT
			local a, b = s[1], s[#s]
			for i = 1, #s - 1 do
				if s[i].t <= renderT and s[i + 1].t >= renderT then
					a, b = s[i], s[i + 1]
					break
				end
			end
			local pos, yaw, pitch
			if renderT <= a.t or a == b then
				pos, yaw, pitch = a.pos, a.yaw, a.pitch
				if renderT > b.t then
					pos, yaw, pitch = b.pos, b.yaw, b.pitch
				end
			else
				local t = math.clamp((renderT - a.t) / math.max(1e-3, b.t - a.t), 0, 1)
				pos = a.pos:Lerp(b.pos, t)
				yaw = lerpAngle(a.yaw, b.yaw, t)
				pitch = a.pitch + (b.pitch - a.pitch) * t
			end
			local moved = Vector3.new(pos.X - m.pos.X, 0, pos.Z - m.pos.Z).Magnitude
			local speed = moved / math.max(dt, 1e-3) / BS -- blocks/s
			m.walkSpeed = math.clamp(speed / 2, 0, 1)
			m.walkPhase += speed * dt * 3.2
			m.flagsAirborne = math.abs(pos.Y - m.pos.Y) > 0.02
			m.pos, m.yaw, m.pitch = pos, yaw, pitch
			m.flags = s[#s].flags
		end
		pose(m, now)
	end
	MobClient.count = count
	-- known vs visible (a model in the world with at least one part)
	local known, visible = 0, 0
	for _, m in mobs do
		known += 1
		if m.built.model.Parent ~= nil and #m.built.parts > 0 then
			visible += 1
		end
	end
	MobClient.stats.known = known
	MobClient.stats.visible = visible
end

-- Closest mob hit by a ray (studs) within maxDist, as (id, distance) or nil.
function MobClient.raycast(origin: Vector3, dir: Vector3, maxDist: number): (number?, number)
	local bestId, bestT = nil, maxDist
	for id, m in mobs do
		if not m.dying and m.def.category ~= "projectile" then
			local hw = m.def.width / 2 * BS
			local lo = Vector3.new(m.pos.X - hw, m.pos.Y, m.pos.Z - hw)
			local hi = Vector3.new(m.pos.X + hw, m.pos.Y + m.def.height * BS, m.pos.Z + hw)
			if m.def.key == "shiftling" then
				lo += Vector3.new(0, 0.6 * BS, 0)
				hi += Vector3.new(0, 0.6 * BS, 0)
			end
			-- slab test
			local tmin, tmax = 0, bestT
			local ok = true
			for _, axis in { "X", "Y", "Z" } do
				local o, d = (origin :: any)[axis], (dir :: any)[axis]
				local l, h = (lo :: any)[axis], (hi :: any)[axis]
				if math.abs(d) < 1e-9 then
					if o < l or o > h then
						ok = false
						break
					end
				else
					local t1, t2 = (l - o) / d, (h - o) / d
					if t1 > t2 then
						t1, t2 = t2, t1
					end
					tmin = math.max(tmin, t1)
					tmax = math.min(tmax, t2)
					if tmin > tmax then
						ok = false
						break
					end
				end
			end
			if ok and tmin < bestT then
				bestId, bestT = id, tmin
			end
		end
	end
	return bestId, bestT
end

function MobClient.init()
	folder = Instance.new("Folder")
	folder.Name = "Mobs"
	folder.Parent = workspace
	Remotes.getUnreliable("MobSnapshot").OnClientEvent:Connect(onSnapshot)
	Remotes.get("MobEvent").OnClientEvent:Connect(onEvent)
	RunService.RenderStepped:Connect(update)
end

return MobClient
