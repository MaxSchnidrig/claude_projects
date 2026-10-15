--!strict
--[[
	Net
	===
	One place to create and find RemoteEvents and RemoteFunctions, the
	"phone lines" between the server and the clients.

	How it works:
	  - On the SERVER, Net.event("Name") creates the remote if it doesn't exist yet.
	  - On the CLIENT, Net.event("Name") waits until the server has created it.
	All remotes live in a folder: ReplicatedStorage.Remotes

	Security reminder: anything a client sends through a remote can be faked by
	an exploiter. The server must validate every request (see RateLimiter and
	the checks inside each service).

	Usage:
		local Net = require(ReplicatedStorage.Shared.Net)
		local pickup = Net.event(Net.Names.PickupEgg)
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local FOLDER_NAME = "Remotes"
local IS_SERVER = RunService:IsServer()

local Net = {}

-- Every remote name in the game. Using these constants instead of typing
-- strings by hand avoids typos. Later milestones add more names here.
Net.Names = {
	Notify = "Notify", -- server -> client: show a notification message
}

local function getFolder(): Folder
	if IS_SERVER then
		local existing = ReplicatedStorage:FindFirstChild(FOLDER_NAME)
		if existing and existing:IsA("Folder") then
			return existing
		end
		local folder = Instance.new("Folder")
		folder.Name = FOLDER_NAME
		folder.Parent = ReplicatedStorage
		return folder
	end
	return ReplicatedStorage:WaitForChild(FOLDER_NAME) :: Folder
end

-- Get (or on the server, create) a RemoteEvent by name.
function Net.event(name: string): RemoteEvent
	local folder = getFolder()
	if IS_SERVER then
		local existing = folder:FindFirstChild(name)
		if existing and existing:IsA("RemoteEvent") then
			return existing
		end
		local remote = Instance.new("RemoteEvent")
		remote.Name = name
		remote.Parent = folder
		return remote
	end
	return folder:WaitForChild(name) :: RemoteEvent
end

-- Get (or on the server, create) a RemoteFunction by name.
function Net.func(name: string): RemoteFunction
	local folder = getFolder()
	if IS_SERVER then
		local existing = folder:FindFirstChild(name)
		if existing and existing:IsA("RemoteFunction") then
			return existing
		end
		local remote = Instance.new("RemoteFunction")
		remote.Name = name
		remote.Parent = folder
		return remote
	end
	return folder:WaitForChild(name) :: RemoteFunction
end

return Net
