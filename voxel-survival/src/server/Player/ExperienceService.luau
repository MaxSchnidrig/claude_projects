--!strict
-- Experience (Phase 10a): every player's level / progress / total / score, and the experience
-- orbs lying in the world. Java rules live in Gameplay/Experience; this runs them 20 times a
-- second, owns the orb Parts (workspace.XPOrbs, drawn by the client's XPOrbVisuals) and tells
-- each client its numbers through the "Experience" remote:
--   S -> C { type = "sync", level, progress, total, score } | { type = "pickup" } | { type = "levelup", volume }
-- Sources call ExperienceService.award (split into orbs) or .orb (one orb of a value).
-- "/xp add|set <amount> [points|levels]" and "/xp query" (Java's /experience) for the world's
-- owner, or anyone in Studio.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared.Config)
local Experience = require(Shared.Gameplay.Experience)
local Shapes = require(Shared.Blocks.Shapes)
local Physics = require(Shared.Mobs.MobPhysics)
local Fluids = require(Shared.World.Fluids)
local Remotes = require(Shared.Net.Remotes)
local WorldService = require(script.Parent.Parent.World.WorldService)

local BS = Config.BLOCK_SIZE
local EYE = 1.62 -- player eye height, blocks
local MAX_ORBS = 400

local ExperienceService = {}
ExperienceService.stats = { orbs = 0, merged = 0 }

type Entry = { orb: Experience.Orb, part: Part, target: Player? }
-- seed: the enchanting seed (Java XpSeed): which offers the enchanting table shows; new after
-- every enchantment
type PState = { xp: Experience.State, takeDelay: number, lastLevelUp: number, lastSent: string, seed: number }

local orbs: { Entry } = {}
local players: { [Player]: PState } = {}
local folder: Folder
local nextId = 0
local tick = 0
local rng = Random.new()
local function random(): number
	return rng:NextNumber()
end

local solid = Shapes.physicsFn(WorldService.getBlock)

local function pstate(p: Player): PState
	local s = players[p]
	if not s then
		s = { xp = Experience.new(), takeDelay = 0, lastLevelUp = -1000, lastSent = "", seed = rng:NextInteger(-2147483648, 2147483647) }
		players[p] = s
	end
	return s
end

local function send(p: Player, force: boolean?)
	local s = pstate(p)
	local x = s.xp
	local key = `{x.level}|{x.progress}|{x.total}|{x.score}`
	if force or key ~= s.lastSent then
		s.lastSent = key
		Remotes.get("Experience"):FireClient(p, { type = "sync", level = x.level, progress = x.progress, total = x.total, score = x.score })
	end
end

-- Feet position of a living, non-spectating player (block units), or nil.
local function feetOf(p: Player): Vector3?
	if p:GetAttribute("Spectator") == true then
		return nil
	end
	local c = p.Character
	local root = c and c:FindFirstChild("HumanoidRootPart") :: BasePart?
	local h = c and c:FindFirstChildOfClass("Humanoid")
	if not root or not h or h.Health <= 0 then
		return nil
	end
	return (root.Position - Vector3.new(0, BS, 0)) / BS
end

local function fluidAt(x: number, y: number, z: number): string?
	if y < 0 or y >= Config.WORLD_HEIGHT then
		return nil
	end
	local fluid = Fluids.info(WorldService.getBlock(math.floor(x), math.floor(y), math.floor(z)))
	return fluid
end

local function move(o: Experience.Orb, dx: number, dy: number, dz: number): (number, number, number, boolean)
	local s = Experience.ORB_SIZE
	local x, y, z = o.x, o.y, o.z
	local nx, ny, nz, _, _, _, ground = Physics.move(solid, x, y, z, dx, dy, dz, s, s, 1)
	o.x, o.y, o.z = nx, ny, nz
	return nx - x, ny - y, nz - z, ground
end

local function sizeOf(value: number): number
	return (0.12 + Experience.orbIcon(value) * 0.025) * BS
end

local function place(e: Entry)
	local o = e.orb
	e.part.CFrame = CFrame.new(o.x * BS, (o.y + Experience.ORB_SIZE / 2) * BS, o.z * BS)
end

local function makeEntry(o: Experience.Orb): Entry
	local part = Instance.new("Part")
	part.Name = "XPOrb"
	part.Shape = Enum.PartType.Ball
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.CastShadow = false
	part.Material = Enum.Material.Neon
	part.Color = Color3.fromRGB(190, 255, 60)
	part.Size = Vector3.one * sizeOf(o.value)
	part:SetAttribute("Value", o.value)
	local e = { orb = o, part = part, target = nil }
	place(e)
	part.Parent = folder
	return e
end

local function removeAt(i: number)
	orbs[i].part:Destroy()
	table.remove(orbs, i)
end

-- One orb of `value` at `pos` (block units) with Java's random starting motion.
function ExperienceService.orb(pos: Vector3, value: number)
	if value <= 0 then
		return
	end
	if #orbs >= MAX_ORBS then
		removeAt(1)
	end
	nextId += 1
	local o = Experience.newOrb(nextId, value, pos.X, pos.Y, pos.Z, random)
	table.insert(orbs, makeEntry(o))
end

-- ExperienceOrb.award: split `amount` into orbs; each joins a matching orb within half a block
-- (random id class, Java's tryMergeToExisting) or becomes a new one.
function ExperienceService.award(pos: Vector3, amount: number)
	amount = math.floor(amount)
	for _, v in Experience.split(amount) do
		local merged = false
		local cls = rng:NextInteger(0, 39)
		for _, e in orbs do
			local o = e.orb
			-- (orb boxes touching a 1-block box around `pos`)
			if o.value == v and (o.id - cls) % 40 == 0 and math.abs(o.x - pos.X) < 0.75
				and o.y > pos.Y - 1 and o.y < pos.Y + 0.5 and math.abs(o.z - pos.Z) < 0.75
			then
				o.count += 1
				o.age = 0
				merged = true
				ExperienceService.stats.merged += 1
				break
			end
		end
		if not merged then
			ExperienceService.orb(pos, v)
		end
	end
end

-- Points straight to a player (orb pickup, /xp, furnace output). Plays the level-up sound on
-- every 5th level like Java (not more than once in 100 ticks).
function ExperienceService.givePoints(p: Player, points: number)
	local s = pstate(p)
	local gained = Experience.addPoints(s.xp, points)
	if gained > 0 and s.xp.level % 5 == 0 and s.lastLevelUp < tick - 100 then
		s.lastLevelUp = tick
		local volume = (if s.xp.level > 30 then 1 else s.xp.level / 30) * 0.75
		Remotes.get("Experience"):FireClient(p, { type = "levelup", volume = volume })
	end
	send(p)
end

function ExperienceService.giveLevels(p: Player, levels: number)
	local s = pstate(p)
	local before = s.xp.level
	Experience.addLevels(s.xp, levels)
	if s.xp.level > before and s.xp.level % 5 == 0 and s.lastLevelUp < tick - 100 then
		s.lastLevelUp = tick
		Remotes.get("Experience"):FireClient(p, { type = "levelup", volume = (if s.xp.level > 30 then 1 else s.xp.level / 30) * 0.75 })
	end
	send(p)
end

function ExperienceService.get(p: Player): Experience.State
	return pstate(p).xp
end

-- The enchanting seed (Java Player.getEnchantmentSeed).
function ExperienceService.seed(p: Player): number
	return pstate(p).seed
end

-- Java Player.onEnchantmentPerformed: pay the levels, roll a new seed.
function ExperienceService.enchanted(p: Player, levels: number)
	local s = pstate(p)
	Experience.addLevels(s.xp, -levels)
	s.seed = rng:NextInteger(-2147483648, 2147483647)
	send(p)
end

-- Death (Java Player.dropExperience): 7 x level points (max 100) drop as orbs where the player
-- died; the rest is lost. Returns the score for the death screen.
function ExperienceService.onDeath(p: Player, feet: Vector3?, keep: boolean?): number
	local s = pstate(p)
	local score = s.xp.score
	if keep then
		return score
	end
	if feet then
		ExperienceService.award(feet, Experience.deathDrop(s.xp.level))
	end
	s.xp = Experience.new()
	send(p)
	return score
end

-- Persistence --------------------------------------------------------------------------------

export type Saved = { level: number, progress: number, total: number, score: number, seed: number? }

function ExperienceService.snapshot(p: Player): Saved
	local s = pstate(p)
	local x = s.xp
	return { level = x.level, progress = x.progress, total = x.total, score = x.score, seed = s.seed }
end

function ExperienceService.restore(p: Player, saved: Saved?)
	if not saved then
		return
	end
	local s = pstate(p)
	s.xp = { level = saved.level, progress = Experience.f32(saved.progress), total = saved.total, score = saved.score }
	if saved.seed then
		s.seed = saved.seed
	end
	send(p, true)
end

-- Furnace output taken: pay out what its recipes stored (AbstractFurnaceBlockEntity
-- .awardUsedRecipesAndPopExperience) as orbs at the player.
function ExperienceService.furnacePayout(p: Player?, at: Vector3, used: { [string]: number }, results: (string) -> string?)
	local amount = Experience.furnacePayout(used, results, random)
	table.clear(used)
	if amount <= 0 then
		return
	end
	local pos = at
	if p then
		pos = feetOf(p) or at
	end
	ExperienceService.award(pos, amount)
end

-- The orb tick ------------------------------------------------------------------------------

local function nearestPlayer(o: Experience.Orb, feet: { [Player]: Vector3 }): Player?
	local best, bestD = nil, Experience.FOLLOW_RANGE * Experience.FOLLOW_RANGE
	for p, f in feet do
		local dx, dy, dz = f.X - o.x, f.Y - o.y, f.Z - o.z
		local d = dx * dx + dy * dy + dz * dz
		if d < bestD then
			best, bestD = p, d
		end
	end
	return best
end

local function step()
	tick += 1
	local feet: { [Player]: Vector3 } = {}
	for _, p in Players:GetPlayers() do
		local f = feetOf(p)
		if f then
			feet[p] = f
		end
		local s = players[p]
		if s and s.takeDelay > 0 then
			s.takeDelay -= 1
		end
	end
	-- move, follow, merge
	local i = 1
	while i <= #orbs do
		local e = orbs[i]
		local o = e.orb
		local gone = false
		if (o.ticks + 1) % Experience.MERGE_EVERY == 1 then
			local t = e.target
			local tf = t and feet[t]
			if not tf or (tf - Vector3.new(o.x, o.y, o.z)).Magnitude > 8 then
				e.target = nearestPlayer(o, feet)
			end
			-- merge same-value orbs whose boxes touch this one grown by 0.5 (ids equal mod 40)
			for j = #orbs, 1, -1 do
				local other = orbs[j]
				if j ~= i and Experience.canMerge(o, other.orb) and math.abs(other.orb.x - o.x) < 1
					and math.abs(other.orb.y - o.y) < 1 and math.abs(other.orb.z - o.z) < 1
				then
					o.count += other.orb.count
					o.age = math.min(o.age, other.orb.age)
					other.part:Destroy()
					table.remove(orbs, j)
					ExperienceService.stats.merged += 1
					if j < i then
						i -= 1
					end
				end
			end
		end
		local t = e.target
		local tf = t and feet[t]
		if t and not tf then
			e.target = nil -- spectating or dead
		end
		if o.y < -64 then
			gone = true
		else
			gone = not Experience.stepOrb(o, move, fluidAt, tf, EYE, random)
		end
		if gone then
			removeAt(i)
		else
			place(e)
			i += 1
		end
	end
	-- pickup: each player takes one random touching orb when their delay is over
	for p, f in feet do
		local s = pstate(p)
		if s.takeDelay == 0 then
			local touching = {}
			for k, e in orbs do
				if Experience.touches(e.orb, f) then
					table.insert(touching, k)
				end
			end
			if #touching > 0 then
				local k = touching[rng:NextInteger(1, #touching)]
				local e = orbs[k]
				s.takeDelay = Experience.PICKUP_DELAY
				Remotes.get("Experience"):FireClient(p, { type = "pickup" })
				-- (Mending repairs items first: Phase 10c)
				ExperienceService.givePoints(p, e.orb.value)
				e.orb.count -= 1
				if e.orb.count <= 0 then
					removeAt(k)
				end
			end
		end
	end
	ExperienceService.stats.orbs = #orbs
end
ExperienceService.step = step

-- Commands ----------------------------------------------------------------------------------

local function allowed(p: Player): boolean
	return RunService:IsStudio() or ReplicatedStorage:GetAttribute("WorldOwner") == p.UserId
end

local function reply(p: Player, text: string)
	print(`[XP] {p.Name}: {text}`)
	Remotes.get("Experience"):FireClient(p, { type = "message", text = text })
end

-- /xp add <n> [points|levels], /xp set <n> [points|levels], /xp query [points|levels]
function ExperienceService.command(p: Player, args: { string })
	if not allowed(p) then
		reply(p, "Only the world's owner can use /xp")
		return
	end
	local verb = args[1] or "query"
	local n = tonumber(args[2] or "")
	local unit = if args[3] == "levels" or args[3] == "l" then "levels" else "points"
	if verb == "query" then
		local x = pstate(p).xp
		reply(p, `Level {x.level}, {math.floor(x.progress * Experience.needed(x.level))} / {Experience.needed(x.level)} points, total {x.total}`)
		return
	end
	if not n or n ~= n then
		reply(p, "Usage: /xp add|set <amount> [points|levels], /xp query")
		return
	end
	n = math.clamp(math.floor(n), -1000000, 1000000)
	if verb == "add" then
		if unit == "levels" then
			ExperienceService.giveLevels(p, n)
		else
			ExperienceService.givePoints(p, n)
		end
		reply(p, `Gave {n} experience {unit}`)
	elseif verb == "set" then
		local s = pstate(p)
		if unit == "levels" then
			Experience.addLevels(s.xp, n - s.xp.level)
		else
			-- Java /experience set points: only within the current level
			local need = Experience.needed(s.xp.level)
			if n < 0 or n > need then
				reply(p, `Points must be 0 to {need} at this level`)
				return
			end
			s.xp.progress = Experience.f32(n / need)
		end
		send(p)
		reply(p, `Set experience {unit} to {n}`)
	else
		reply(p, "Usage: /xp add|set <amount> [points|levels], /xp query")
	end
end

function ExperienceService.init()
	folder = Instance.new("Folder")
	folder.Name = "XPOrbs"
	folder.Parent = workspace
	Players.PlayerRemoving:Connect(function(p)
		players[p] = nil
	end)
	Remotes.get("XpCommand").OnServerEvent:Connect(function(p: Player, args: any)
		if typeof(args) ~= "table" or #args > 4 then
			return
		end
		local clean = {}
		for _, a in args do
			if typeof(a) ~= "string" or #a > 16 then
				return
			end
			table.insert(clean, string.lower(a))
		end
		ExperienceService.command(p, clean)
	end)
	local function chatted(p: Player)
		p.Chatted:Connect(function(msg: string)
			local words = string.split(string.lower(msg), " ")
			if words[1] == "/xp" or words[1] == "/experience" then
				table.remove(words, 1)
				ExperienceService.command(p, words)
			end
		end)
	end
	for _, p in Players:GetPlayers() do
		chatted(p)
	end
	Players.PlayerAdded:Connect(chatted)
	Remotes.get("Experience").OnServerEvent:Connect(function(p: Player, a: any)
		if typeof(a) == "table" and a.type == "hello" then
			send(p, true) -- the client asks once it's listening
		end
	end)
	local acc = 0
	RunService.Heartbeat:Connect(function(dt)
		acc += dt
		local n = 0
		while acc >= 0.05 and n < 5 do
			acc -= 0.05
			n += 1
			step()
		end
		if n >= 5 then
			acc = 0
		end
	end)
end

return ExperienceService
