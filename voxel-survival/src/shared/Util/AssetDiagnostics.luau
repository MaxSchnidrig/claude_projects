--!strict
-- Finds where a failing asset ID comes from.
--
-- Watches Output (including messages logged before this started) for
-- "ContentId: rbxassetid://<id> failed ... Asset type does not match requested type", then searches
-- characters, GUIs and the shared folders for any instance property that references that ID, and
-- prints exactly which instance + property holds it, e.g.
--   [AssetDiagnostics] rbxassetid://123 -> Workspace.Player1.Animate.walk.WalkAnim (Animation.AnimationId)
-- Runs on both server and client (an error can come from either side).

local LogService = game:GetService("LogService")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

local AssetDiagnostics = {}

-- Asset-referencing properties to check, per class.
local PROPS: { [string]: { string } } = {
	Animation = { "AnimationId" },
	Decal = { "Texture" },
	Texture = { "Texture" },
	Shirt = { "ShirtTemplate" },
	Pants = { "PantsTemplate" },
	ShirtGraphic = { "Graphic" },
	SpecialMesh = { "MeshId", "TextureId" },
	FileMesh = { "MeshId", "TextureId" },
	MeshPart = { "MeshId", "TextureID" },
	Sound = { "SoundId" },
	ImageLabel = { "Image" },
	ImageButton = { "Image" },
	Sky = { "SkyboxBk", "SkyboxDn", "SkyboxFt", "SkyboxLf", "SkyboxRt", "SkyboxUp", "SunTextureId", "MoonTextureId" },
	StringValue = { "Value" },
}
local DESCRIPTION_FIELDS = {
	"Face", "Shirt", "Pants", "GraphicTShirt", "Head", "Torso", "LeftArm", "RightArm", "LeftLeg",
	"RightLeg", "ClimbAnimation", "FallAnimation", "IdleAnimation", "JumpAnimation", "MoodAnimation",
	"RunAnimation", "SwimAnimation", "WalkAnimation",
}

-- When this module first loaded (≈ when our scripts started), to tell apart errors that happen
-- before any game code runs (place content, Studio itself).
local scriptsStarted = DateTime.now().UnixTimestampMillis / 1000
local loggedAt: { [string]: number } = {} -- asset id -> log timestamp (from log history)

local unresolved: { [string]: boolean } = {}
local reported: { [string]: boolean } = {}

-- Phases: code that triggers engine asset loads (e.g. building avatars) wraps itself in
-- AssetDiagnostics.phase(name, fn), so an error can be tied to the step that caused it even when
-- no instance keeps the failing ID.
type Phase = { name: string, t0: number, t1: number? }
local phases: { Phase } = {}
local activePhase: string? = nil
local phaseOf: { [string]: string } = {} -- asset id -> phase name it was logged during

local function now(): number
	return DateTime.now().UnixTimestampMillis / 1000
end

function AssetDiagnostics.phase<T...>(name: string, fn: () -> T...): T...
	local p: Phase = { name = name, t0 = now(), t1 = nil }
	table.insert(phases, p)
	if #phases > 200 then
		table.remove(phases, 1)
	end
	local prev = activePhase
	activePhase = name
	local results = table.pack(pcall(fn))
	activePhase = prev
	p.t1 = now()
	if not results[1] then
		error(results[2], 0)
	end
	return table.unpack(results, 2, results.n)
end

-- Which phase was running at time t (epoch seconds)? Small slack for log timestamp rounding.
local function phaseAt(t: number): string?
	for i = #phases, 1, -1 do
		local p = phases[i]
		if t >= p.t0 - 0.05 and t <= (p.t1 or math.huge) + 0.25 then
			return p.name
		end
	end
	return nil
end

local function containsId(value: any, id: string): boolean
	if typeof(value) == "number" then
		return tostring(value) == id
	elseif typeof(value) == "string" then
		return string.find(value, id, 1, true) ~= nil
	end
	return false
end

local function search(id: string): { string }
	local found = {}
	-- Scan every service we're allowed to read (the server can read more than the client).
	local roots: { Instance } = {}
	for _, service in game:GetChildren() do
		local ok = pcall(function()
			return service:GetChildren()
		end)
		if ok then
			table.insert(roots, service)
		end
	end
	for _, p in Players:GetPlayers() do
		local gui = p:FindFirstChildOfClass("PlayerGui")
		if gui then
			table.insert(roots, gui)
		end
		local scripts = p:FindFirstChildOfClass("PlayerScripts")
		if scripts then
			table.insert(roots, scripts)
		end
	end
	local function check(inst: Instance)
		local props = PROPS[inst.ClassName]
		if props then
			for _, prop in props do
				local ok, v = pcall(function()
					return (inst :: any)[prop]
				end)
				if ok and containsId(v, id) then
					table.insert(found, `{inst:GetFullName()} ({inst.ClassName}.{prop})`)
				end
			end
		elseif inst:IsA("HumanoidDescription") then
			for _, field in DESCRIPTION_FIELDS do
				local ok, v = pcall(function()
					return (inst :: any)[field]
				end)
				if ok and containsId(v, id) then
					table.insert(found, `{inst:GetFullName()} (HumanoidDescription.{field})`)
				end
			end
		end
	end
	for _, root in roots do
		pcall(function()
			check(root)
			for _, d in root:GetDescendants() do
				check(d)
			end
		end)
	end
	return found
end

local function resolve(id: string)
	if reported[id] then
		return
	end
	local found = search(id)
	local side = if RunService:IsServer() then "server" else "client"
	if #found > 0 then
		reported[id] = true
		unresolved[id] = nil
		for _, where in found do
			warn(`[AssetDiagnostics:{side}] rbxassetid://{id} -> {where}{describePhase(id)}`)
		end
	else
		unresolved[id] = true
	end
end

local function describePhase(id: string): string
	local p = phaseOf[id]
	local text = if p then `; it was logged during: {p}` else "; it was not logged during any tagged step"
	local t = loggedAt[id]
	if t and math.abs(t - scriptsStarted) < 3600 then -- skip if the log clock isn't epoch seconds
		if t < scriptsStarted - 0.05 then
			text ..= string.format("; logged %.2f s BEFORE our scripts started (so it comes from the place file or Studio itself, not game code)", scriptsStarted - t)
		else
			text ..= string.format("; logged %.2f s after our scripts started", t - scriptsStarted)
		end
	end
	return text
end

local function onMessage(message: string, timestamp: number?)
	if string.find(message, "AssetDiagnostics", 1, true) then
		return
	end
	if string.find(message, "does not match", 1, true) or string.find(message, "failed", 1, true) then
		local id = string.match(message, "rbxassetid://(%d+)") or string.match(message, "[?&]id=(%d+)")
		if id then
			local at = timestamp or now()
			if not loggedAt[id] then
				loggedAt[id] = at
			end
			local p = if timestamp then phaseAt(timestamp) else activePhase or phaseAt(now())
			if p and not phaseOf[id] then
				phaseOf[id] = p
			end
			task.defer(resolve, id)
		end
	end
end

function AssetDiagnostics.init()
	LogService.MessageOut:Connect(function(message)
		onMessage(message, nil)
	end)
	for _, entry in LogService:GetLogHistory() do
		onMessage(entry.message, entry.timestamp)
	end
	-- An ID may belong to something that appears later (e.g. the character): retry for a while,
	-- then say clearly that it isn't referenced by any instance we can see.
	task.spawn(function()
		for _ = 1, 10 do
			task.wait(3)
			for id in unresolved do
				resolve(id)
			end
		end
		local side = if RunService:IsServer() then "server" else "client"
		for id in unresolved do
			warn(`[AssetDiagnostics:{side}] rbxassetid://{id} is not referenced by any instance in any readable service; it is requested internally (engine/default asset){describePhase(id)}`)
		end
	end)
end

return AssetDiagnostics
