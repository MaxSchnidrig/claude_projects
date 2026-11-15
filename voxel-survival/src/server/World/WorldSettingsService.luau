--!strict
-- The running world's settings: difficulty, Hardcore, and whether friends may join.
--
--   * loaded from the world meta at startup (Persistence), written back with it
--   * shown to clients as ReplicatedStorage attributes "Difficulty", "Hardcore", "FriendsCanJoin"
--   * changed by the world's owner from the pause menu (remote "WorldSettings"); in Studio by
--     anyone. A Hardcore world is always Hard and its difficulty can't change (Java)
--
-- Remote "WorldSettings":
--   C -> S { type = "difficulty", value = name } | { type = "friends", on = boolean }
--   S -> C { type = "status", text }

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Difficulty = require(Shared.Gameplay.Difficulty)
local Remotes = require(Shared.Net.Remotes)

local WorldSettingsService = {}

local difficulty: Difficulty.Name = Difficulty.DEFAULT
local hardcore = false
local friends = true
local friendsAt = 0 -- os.time() of the last change made here (the lobby can change it too)
local ownerId = 0
local listeners: { (string) -> () } = {}
local onDirty: (() -> ())? = nil

local function publish()
	ReplicatedStorage:SetAttribute("Difficulty", difficulty)
	ReplicatedStorage:SetAttribute("Hardcore", hardcore)
	ReplicatedStorage:SetAttribute("FriendsCanJoin", friends)
end

local function changed(what: string)
	publish()
	for _, fn in listeners do
		task.spawn(fn, what)
	end
	if onDirty then
		(onDirty :: () -> ())()
	end
end

-- From the world meta (Persistence), before anything reads the settings.
function WorldSettingsService.load(m: { difficulty: any?, hardcore: any?, friends: any?, friendsAt: any? }, owner: number)
	hardcore = m.hardcore == true
	difficulty = if hardcore then "hard" else Difficulty.sanitize(m.difficulty)
	friends = m.friends ~= false
	friendsAt = if typeof(m.friendsAt) == "number" then m.friendsAt else 0
	ownerId = owner
	publish()
end

function WorldSettingsService.difficulty(): Difficulty.Name
	return difficulty
end

function WorldSettingsService.difficultyId(): number
	return Difficulty.id(difficulty)
end

function WorldSettingsService.isHardcore(): boolean
	return hardcore
end

function WorldSettingsService.friends(): (boolean, number)
	return friends, friendsAt
end

-- Persistence: a setting changed, the meta needs writing.
function WorldSettingsService.setDirtyHandler(fn: () -> ())
	onDirty = fn
end

-- fn("difficulty" | "friends")
function WorldSettingsService.onChanged(fn: (string) -> ())
	table.insert(listeners, fn)
end

-- Returns false if not allowed (Hardcore).
function WorldSettingsService.setDifficulty(name: Difficulty.Name): boolean
	if hardcore or not Difficulty.valid(name) then
		return false
	end
	if name ~= difficulty then
		difficulty = name
		changed("difficulty")
	end
	return true
end

function WorldSettingsService.setFriends(on: boolean)
	if on ~= friends then
		friends = on
		friendsAt = os.time()
		changed("friends")
	end
end

function WorldSettingsService.canEdit(p: Player): boolean
	return p.UserId == ownerId or RunService:IsStudio()
end

function WorldSettingsService.init()
	publish()
	local remote = Remotes.get("WorldSettings")
	remote.OnServerEvent:Connect(function(p: Player, a: any)
		if typeof(a) ~= "table" then
			return
		end
		if not WorldSettingsService.canEdit(p) then
			remote:FireClient(p, { type = "status", text = "Only the world's owner can change this." })
			return
		end
		if a.type == "difficulty" and Difficulty.valid(a.value) then
			if not WorldSettingsService.setDifficulty(a.value) then
				remote:FireClient(p, { type = "status", text = "A Hardcore world is always Hard." })
				return
			end
			for _, other in Players:GetPlayers() do
				remote:FireClient(other, { type = "status", text = `The difficulty is now {Difficulty.LABEL[difficulty]}` })
			end
		elseif a.type == "friends" and typeof(a.on) == "boolean" then
			WorldSettingsService.setFriends(a.on)
			remote:FireClient(p, { type = "status", text = if a.on then "Friends can join this world." else "This world is private now." })
		end
	end)
end

return WorldSettingsService
