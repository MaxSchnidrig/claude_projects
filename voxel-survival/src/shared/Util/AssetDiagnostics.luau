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

local unresolved: { [string]: boolean } = {}
local reported: { [string]: boolean } = {}

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
	local roots: { Instance } = { workspace, game:GetService("ReplicatedStorage"), game:GetService("StarterPlayer"), game:GetService("Lighting") }
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
		check(root)
		for _, d in root:GetDescendants() do
			check(d)
		end
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
			warn(`[AssetDiagnostics:{side}] rbxassetid://{id} -> {where}`)
		end
	else
		unresolved[id] = true
	end
end

local function onMessage(message: string)
	if string.find(message, "AssetDiagnostics", 1, true) then
		return
	end
	if string.find(message, "does not match", 1, true) or string.find(message, "failed", 1, true) then
		local id = string.match(message, "rbxassetid://(%d+)") or string.match(message, "[?&]id=(%d+)")
		if id then
			task.defer(resolve, id)
		end
	end
end

function AssetDiagnostics.init()
	LogService.MessageOut:Connect(onMessage)
	for _, entry in LogService:GetLogHistory() do
		onMessage(entry.message)
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
			warn(`[AssetDiagnostics:{side}] rbxassetid://{id} is not referenced by any instance in workspace, characters, GUIs or shared folders; it is requested internally (engine/default asset)`)
		end
	end)
end

return AssetDiagnostics
