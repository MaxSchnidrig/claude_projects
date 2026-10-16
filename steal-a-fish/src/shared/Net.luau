--!strict
--[[
	Net
	===
	One place to create and find RemoteEvents and RemoteFunctions, the
	"phone lines" between the server and the clients.

	How it works:
	  - The SERVER creates every remote listed in Net.Names when it starts
	    (Net.createAll(), called by the server bootstrap). So the client never
	    has to wait for a remote that doesn't exist yet.
	  - On the SERVER, Net.event("Name") returns the remote (creating it if needed).
	  - On the CLIENT, Net.event("Name") waits for it, but at most
	    CLIENT_WAIT_SECONDS. If it's still missing, it raises a clear error
	    instead of hanging forever.
	All remotes live in a folder: ReplicatedStorage.Remotes

	When you add a new remote: add its name to Net.Names below. That's all.

	Security reminder: anything a client sends through a remote can be faked by
	an exploiter. The server must validate every request (see RateLimiter and
	the checks inside each service).

	Usage:
		local Net = require(ReplicatedStorage.Shared.Net)
		local notify = Net.event(Net.Names.Notify)
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local FOLDER_NAME = "Remotes"
local CLIENT_WAIT_SECONDS = 15
local IS_SERVER = RunService:IsServer()

local Net = {}

-- Every remote name in the game. Using these constants instead of typing
-- strings by hand avoids typos. Later milestones add more names here.
Net.Names = {
	Notify = "Notify", -- server -> client: (message, kind) show a notification
	Knockback = "Knockback", -- server -> client: push your own character (Vector3 velocity)
	SpeedGained = "SpeedGained", -- server -> client: show a "+X Speed" popup (number)
	StopTraining = "StopTraining", -- client -> server: "I pressed jump, let me off the treadmill"
	PetHatched = "PetHatched", -- server -> ALL clients: (position, rarity) for the hatch burst effect
	HatchReveal = "HatchReveal", -- server -> owner: (petName, rarity, income) for the "You hatched!" card
	MoneyCollected = "MoneyCollected", -- server -> owner: (amount) for a "+$X" popup
	BuyUpgrade = "BuyUpgrade", -- client -> server: ("Pads" or "Treadmill") please buy the next level
	PetAction = "PetAction", -- client -> server: (padIndex, "Upgrade" or "Sell") from the Pets window
	TutorialFinished = "TutorialFinished", -- client -> server: the new-player tutorial is done
	EggSaved = "EggSaved", -- server -> owner: (rarity) you reached the safe zone with an egg (celebration)
	IndexSync = "IndexSync", -- server -> owner: (data) found fish and claimed rewards, for the Index window
	IndexClaim = "IndexClaim", -- client -> server: ("Fish", name) / ("Zone", zoneIndex) / ("All") / ("Sync")
	DailyGiftClaim = "DailyGiftClaim", -- client -> server: claim the free daily gift
	ShopBuy = "ShopBuy", -- client -> server: (itemKey) buy a Robux item (Monetization milestone)
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
	local folder = ReplicatedStorage:WaitForChild(FOLDER_NAME, CLIENT_WAIT_SECONDS)
	if not (folder and folder:IsA("Folder")) then
		error(`[Net] ReplicatedStorage.{FOLDER_NAME} was not found. Did the server start correctly?`)
	end
	return folder
end

-- Client side: wait (with a time limit) for a remote the server created.
local function waitForRemote(name: string, className: string): Instance
	local remote = getFolder():WaitForChild(name, CLIENT_WAIT_SECONDS)
	if not (remote and remote:IsA(className)) then
		error(`[Net] Remote "{name}" ({className}) was not found after {CLIENT_WAIT_SECONDS}s. Is it listed in Net.Names?`)
	end
	return remote
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
	return waitForRemote(name, "RemoteEvent") :: RemoteEvent
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
	return waitForRemote(name, "RemoteFunction") :: RemoteFunction
end

-- Server only: create every RemoteEvent in Net.Names right away.
function Net.createAll()
	assert(IS_SERVER, "Net.createAll() must be called on the server")
	local names: { [string]: string } = Net.Names
	for _, name in names do
		Net.event(name)
	end
end

return Net
