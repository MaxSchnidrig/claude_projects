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
}

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
else
	folder = ReplicatedStorage:WaitForChild("Remotes") :: Folder
end

function Remotes.get(name: string): RemoteEvent
	assert(table.find(NAMES, name), `Remotes: unknown remote '{name}'`)
	return folder:WaitForChild(name) :: RemoteEvent
end

return Remotes
