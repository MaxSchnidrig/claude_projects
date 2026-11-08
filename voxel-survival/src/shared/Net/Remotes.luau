--!strict
-- Single place where every RemoteEvent is declared. The server creates them; clients wait for them.
--
--   ChunkRequest  C -> S  { load = {chunkKey...}, unload = {chunkKey...} }
--   ChunkDiffs    S -> C  { {chunkKey, packedDiffs}, ... }   (reply to load requests)
--   WorldReady    C -> S  ()  client has collision around the spawn point
--   BlockChanged  S -> C  (x, y, z, id)        authoritative block state (also corrects predictions)
--   BlockAction   C -> S  (action, x, y, z)    "start" | "cancel" | "finish" | "place"
--   InventorySync S -> C  { slots = {stack|false ...}, selected = n }
--   SelectSlot    C -> S  (n)                  hotbar slot 1..9
--   InventoryAction C -> S { type = "click" | "collect" | "open" | "openInventory" | "close" | "drop" | "dropSlot" | "dropCursor", ... }
--   SurvivalSync  S -> C  { food, saturation, air, maxAir, canSprint, event? = "hurt" | "died", cause? }
--   SurvivalAction C -> S { type = "sprint", on } | { type = "eatStart" | "eatFinish" | "eatCancel" } | { type = "respawn" }
--   DebugAction   C -> S  { type = "skipTime" | "hurtSelf" }  (Studio only)
--   MobSnapshot   S -> C  (unreliable, 10 Hz) flat list: id, code, x, y, z, yaw, pitch, flags, ...
--   MobEvent      S -> C  { type = "hurt" | "died" | "explode" | "teleport" | "crit" | "angry", id, ... }
--   AttackMob     C -> S  (mobId, crit: boolean)  crit = the client saw a critical-hit state
--   Lobby         both    lobby menu (see server/Lobby/LobbyService)
--   BlockBatch    S -> C  { x, y, z, id, x, y, z, id, ... } world changes made by game systems
--   UseItem       C -> S  { x, y, z, nx, ny, nz } right-click use of the held item / a block
--                         (buckets, flint and steel, campfires)
--   EntityEvent   S -> C  { type = "spawn" | "remove" | "fizz", ... } falling blocks and primed TNT
--   CampfireState S -> C  (x, y, z, { item keys }) what's cooking on a campfire
--   Decor         S -> C  { type = "sign", x, y, z, front, back } | { type = "signRemove", x, y, z }
--                         | { type = "frame", key, x, y, z, facing, item, rot } | { type = "frameRemove", key }
--                         | { type = "signEditor", x, y, z, side }
--                 C -> S  { type = "signEdit", x, y, z, side, lines } | { type = "framePlace", x, y, z, nx, ny, nz }
--                         | { type = "frameUse", key } | { type = "frameHit", key }
--   StareMob      C -> S  (mobId)  the player has looked a voidling in the eyes for 5 ticks
--   Knockback     S -> C  { dir = Vector3, strength } (Java hit knockback, blocks/tick) or
--                         { add = Vector3 } (explosion push, blocks/tick)

local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local NAMES = {
	"ChunkRequest",
	"ChunkDiffs",
	"WorldReady",
	"BlockChanged",
	"BlockAction",
	"InventorySync",
	"SelectSlot",
	"InventoryAction",
	"SurvivalSync",
	"SurvivalAction",
	"DebugAction",
	"MobEvent",
	"AttackMob",
	"Knockback",
	"StareMob",
	"Lobby",
	"BlockBatch",
	"UseItem",
	"EntityEvent",
	"CampfireState",
	"Decor",
}
-- High-frequency state where a lost packet doesn't matter (the next one replaces it).
local UNRELIABLE = { "MobSnapshot" }

local Remotes = {}

local folder: Folder
if RunService:IsServer() then
	local existing = ReplicatedStorage:FindFirstChild("Remotes")
	if existing then
		folder = existing :: Folder
	else
		folder = Instance.new("Folder")
		folder.Name = "Remotes"
		folder.Parent = ReplicatedStorage
	end
	for _, name in NAMES do
		if not folder:FindFirstChild(name) then
			local r = Instance.new("RemoteEvent")
			r.Name = name
			r.Parent = folder
		end
	end
	for _, name in UNRELIABLE do
		if not folder:FindFirstChild(name) then
			local r = Instance.new("UnreliableRemoteEvent")
			r.Name = name
			r.Parent = folder
		end
	end
else
	folder = ReplicatedStorage:WaitForChild("Remotes") :: Folder
end

function Remotes.getUnreliable(name: string): UnreliableRemoteEvent
	assert(table.find(UNRELIABLE, name), `Remotes: unknown unreliable remote '{name}'`)
	return folder:WaitForChild(name) :: UnreliableRemoteEvent
end

function Remotes.get(name: string): RemoteEvent
	assert(table.find(NAMES, name), `Remotes: unknown remote '{name}'`)
	return folder:WaitForChild(name) :: RemoteEvent
end

return Remotes
