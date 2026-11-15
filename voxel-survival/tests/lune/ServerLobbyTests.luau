--!nocheck
-- Runs the REAL server/Lobby/LobbyService (with the real Persistence and DataStoreQueue, on the
-- queue's in-memory store) in a fake Roblox: the world list, creating, playing (Studio: in the
-- same server), deleting, friends access, and refusing other people's worlds.
--
-- Usage (from run.luau):  require("./ServerLobbyTests")(test, eq)

local Loader = require("./Loader")
local Fake = require("./FakeRoblox")

return function(test: (string, () -> ()) -> (), eq: (any, any, string?) -> ())
	print("Server lobby (real LobbyService + Persistence in a fake Roblox)")

	test("server: world list (old world kept), create, Hardcore, play in place, delete, limits", function()
		local G = Fake.newGame()
		for k, v in G.env do
			Loader.globals[k] = v
		end
		Loader.forget("src/server/")
		local remotes = {}
		Loader.stubs["src/shared/Net/Remotes.luau"] = {
			get = function(name: string)
				local r = remotes[name]
				if not r then
					r = Fake.Instance.new("RemoteEvent")
					r.Name = name
					remotes[name] = r
				end
				return r
			end,
		}
		Fake.mount(G.game:GetService("ReplicatedStorage"), "Shared", Loader.node("src/shared"))
		local SaveFormat = Loader.require("src/shared/Persistence/SaveFormat")
		local Persistence = Loader.require("src/server/Persistence/Persistence")
		local mode, owner = Persistence.resolve()
		eq(mode, "lobby", "Studio starts at the title screen")
		local player = G.player
		eq(owner, player.UserId)
		local q = Persistence.queue()
		eq(q:isPersistent(), false) -- the fake has no DataStore: in-memory store
		-- a world saved before world lists existed (just w:<owner>:meta)
		q.memory[SaveFormat.metaKey(player.UserId)] = { v = 3, seed = 42, friends = true, regions = { "0,0" } }
		q.memory[SaveFormat.regionKey(SaveFormat.mainWorld(player.UserId), 0, 0)] = { some = "edits" }

		local LobbyService = Loader.require("src/server/Lobby/LobbyService")
		local opened = {}
		LobbyService.init(function(p, o, w)
			table.insert(opened, { p, o, w })
		end)
		local remote = remotes.Lobby
		local function ask(msg)
			remote.OnServerEvent:Fire(player, msg)
		end
		local function replies(kind: string): { any }
			local out = {}
			for _, r in rawget(remote, "__toClient") or {} do
				if r[2].type == kind then
					table.insert(out, r[2])
				end
			end
			return out
		end
		local function lastState()
			local s = replies("state")
			return s[#s]
		end
		local function lastStatus(): string
			local s = replies("status")
			return if s[#s] then s[#s].text else ""
		end

		ask({ type = "state" })
		local st = lastState()
		eq(#st.worlds, 1, "the old world is in the list")
		eq(st.worlds[1].key, tostring(player.UserId))
		eq(st.worlds[1].name, "My World")
		eq(st.worlds[1].difficulty, "normal")
		eq(st.studio, true)

		-- create a Hardcore world: name trimmed and filtered, Java seed from text, always Hard
		ask({ type = "create", name = "  bad Castle  ", hardcore = true, difficulty = "easy", seed = "hello" })
		local key = `{player.UserId}_2`
		local meta = Persistence.decodeMeta(q.memory[SaveFormat.metaKey(key)])
		assert(meta, "the new world's record")
		eq(meta.name, "### Castle")
		eq(meta.hardcore, true)
		eq(meta.difficulty, "hard")
		eq(meta.seed, 99162322)
		eq(replies("created")[1].world, key)
		-- Studio: it opens right here
		eq(#opened, 1)
		eq(opened[1][3], key)
		-- the list now has both, newest first
		st = lastState()
		eq(#st.worlds, 2)
		eq(st.worlds[1].key, key)
		eq(st.worlds[1].hardcore, true)
		-- (in Studio only one world opens per test session)
		ask({ type = "play", world = tostring(player.UserId) })
		eq(#opened, 1)
		assert(string.find(lastStatus(), "already open", 1, true), lastStatus())

		-- a normal world with a blank seed (random) and a bad difficulty value (-> Normal)
		ask({ type = "create", name = "", hardcore = false, difficulty = "nightmare", seed = "" })
		local key3 = `{player.UserId}_3`
		local m3 = Persistence.decodeMeta(q.memory[SaveFormat.metaKey(key3)])
		eq(m3.name, "New World")
		eq(m3.hardcore, false)
		eq(m3.difficulty, "normal")
		assert(m3.seed >= 0, "random seed")

		-- friends access per world
		ask({ type = "setFriends", world = key3, on = false })
		eq(Persistence.decodeMeta(q.memory[SaveFormat.metaKey(key3)]).friends, false)

		-- someone else's world can't be touched
		ask({ type = "delete", world = "999" })
		ask({ type = "setFriends", world = "999_2", on = false })
		ask({ type = "play", world = "999" })
		eq(#lastState().worlds, 3)

		-- delete the old world: off the list, its data removed
		ask({ type = "delete", world = tostring(player.UserId) })
		eq(#lastState().worlds, 2)
		eq(q.memory[SaveFormat.metaKey(player.UserId)], nil)
		eq(q.memory[SaveFormat.regionKey(SaveFormat.mainWorld(player.UserId), 0, 0)], nil)
		local list = SaveFormat.decodeWorldList(q.memory[SaveFormat.worldsKey(player.UserId)], player.UserId, false)
		eq(table.find(list.worlds, tostring(player.UserId)), nil)
		-- a new world never reuses a deleted world's key
		ask({ type = "create", name = "Again" })
		eq(replies("created")[3].world, `{player.UserId}_4`)

		-- at most 10 worlds
		for i = 1, 12 do
			ask({ type = "create", name = `W{i}` })
		end
		eq(#lastState().worlds, SaveFormat.MAX_WORLDS)
		assert(string.find(lastStatus(), "already have", 1, true), lastStatus())

		Loader.stubs["src/shared/Net/Remotes.luau"] = nil
	end)

	for _, k in { "game", "workspace", "Instance", "Enum", "CFrame", "Vector2", "Color3", "UDim2", "UDim", "task", "os", "time", "tick", "warn", "Random" } do
		Loader.globals[k] = nil
	end
	Loader.forget("src/server/")
end
