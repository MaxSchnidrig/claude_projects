--!nocheck
-- Runs the REAL title screen (Lobby/LobbyUI), pause menu (UI/PauseMenu), options (UI/SettingsUI)
-- and touch controls (UI/TouchControls) in a fake Roblox (FakeRoblox.luau): their buttons are
-- pressed and what they send to the server is checked. Every GUI property they set is checked
-- against Roblox's real class database, so a misspelled property fails here, not in Studio.
--
-- Usage (from run.luau):  require("./ClientMenuTests")(test, eq)

local Loader = require("./Loader")
local Fake = require("./FakeRoblox")

local Vector3, Enum = Fake.Vector3, Fake.Enum
local roblox = require("@lune/roblox") :: any

return function(test: (string, () -> ()) -> (), eq: (any, any, string?) -> ())
	print("Client menus (real title screen, pause menu, options, touch controls in a fake Roblox)")

	type T = { G: any, remotes: { [string]: any }, stubs: { [string]: any } }

	local STUB_PATHS = {
		"src/shared/Net/Remotes.luau", "src/client/Player/InventoryClient.luau", "src/client/Player/CameraController.luau",
		"src/client/Survival/SurvivalClient.luau", "src/client/Player/MovementController.luau",
		"src/client/Interaction/BlockInteraction.luau",
	}

	local function boot(): T
		local G = Fake.newGame()
		for k, v in G.env do
			Loader.globals[k] = v
		end
		Loader.forget("src/client/")
		local t: T = { G = G, remotes = {}, stubs = {} }
		Loader.stubs["src/shared/Net/Remotes.luau"] = {
			get = function(name: string)
				local r = t.remotes[name]
				if not r then
					r = Fake.Instance.new("RemoteEvent")
					r.Name = name
					t.remotes[name] = r
				end
				return r
			end,
		}
		local changed = Fake.Instance.new("BindableEvent")
		t.stubs.inventory = { uiOpen = false }
		t.stubs.camera = { mouseUnlocked = false, touchOwned = false, aimOverride = nil, turned = { 0, 0 } }
		function t.stubs.camera.turn(dx: number, dy: number)
			t.stubs.camera.turned[1] += dx
			t.stubs.camera.turned[2] += dy
		end
		t.stubs.survival = { dead = false, Changed = changed.Event, fire = changed }
		t.stubs.movement = { touch = nil, sneaking = false, sneaks = 0, sprints = 0 }
		function t.stubs.movement.toggleSneak()
			t.stubs.movement.sneaks += 1
			t.stubs.movement.sneaking = not t.stubs.movement.sneaking
		end
		function t.stubs.movement.touchSprint()
			t.stubs.movement.sprints += 1
		end
		t.stubs.block = { log = {} }
		for _, name in { "aimAt", "touchTap", "touchHold", "touchRelease" } do
			t.stubs.block[name] = function(p)
				table.insert(t.stubs.block.log, name)
			end
		end
		Loader.stubs["src/client/Player/InventoryClient.luau"] = t.stubs.inventory
		Loader.stubs["src/client/Player/CameraController.luau"] = t.stubs.camera
		Loader.stubs["src/client/Survival/SurvivalClient.luau"] = t.stubs.survival
		Loader.stubs["src/client/Player/MovementController.luau"] = t.stubs.movement
		Loader.stubs["src/client/Interaction/BlockInteraction.luau"] = t.stubs.block
		Fake.mount(G.game:GetService("ReplicatedStorage"), "Shared", Loader.node("src/shared"))
		return t
	end

	local function cleanup()
		for _, p in STUB_PATHS do
			Loader.stubs[p] = nil
		end
	end

	local function sent(t: T, remote: string): { any }
		local r = t.remotes[remote]
		return if r then rawget(r, "__sent") else {}
	end
	local function lastSent(t: T, remote: string): any
		local list = sent(t, remote)
		return list[#list] and list[#list][1]
	end

	-- the visible GuiObject (in `root`) whose Text starts with `prefix`
	local function visible(o: any): boolean
		local a = o
		while a do
			if a:IsA("GuiObject") and not a.Visible then
				return false
			end
			if a:IsA("ScreenGui") then
				return a.Enabled
			end
			a = a.Parent
		end
		return true
	end
	local function find(root: any, prefix: string, onlyVisible: boolean?): any
		for _, d in root:GetDescendants() do
			if (d:IsA("TextButton") or d:IsA("TextLabel")) and string.sub(d.Text, 1, #prefix) == prefix
				and (onlyVisible == false or visible(d))
			then
				return d
			end
		end
		return nil
	end
	local function click(root: any, prefix: string)
		local b = find(root, prefix)
		assert(b, `no visible button "{prefix}"`)
		assert(b:IsA("TextButton"), `"{prefix}" is not a button`)
		b.Activated:Fire()
	end

	test("client: title screen: worlds, create (Survival / Hardcore), delete, options", function()
		local t = boot()
		local LobbyUI = Loader.require("src/client/Lobby/LobbyUI")
		LobbyUI.init()
		local gui = t.G.player.PlayerGui:FindFirstChild("TitleScreen")
		assert(gui, "title screen shown")
		assert(find(gui, "Play"), "Play button")
		eq(lastSent(t, "Lobby").type, "state")
		-- Play -> the world list, filled from the server's answer
		click(gui, "Play")
		local remote = t.remotes.Lobby
		remote.OnClientEvent:Fire({
			type = "state", max = 10, studio = true, listOk = true, saving = true, friendsWorlds = {},
			worlds = {
				{ key = "1", name = "My World", played = 2000, hardcore = false, difficulty = "normal", friends = true },
				{ key = "1_2", name = "Brave", played = 1000, hardcore = true, difficulty = "hard", friends = false },
			},
		})
		assert(find(gui, "My World"), "first world listed")
		assert(find(gui, "Brave"), "second world listed")
		assert(find(gui, "Hardcore"), "hardcore shown")
		assert(find(gui, "Friends can join: ON"), "first world selected")
		-- select the second, then play it (tapping the selected row again also plays)
		local row = find(gui, "Brave").Parent
		row.Activated:Fire()
		assert(find(gui, "Friends can join: OFF"), "second world selected")
		click(gui, "Play Selected World")
		local m = lastSent(t, "Lobby")
		eq(m.type, "play"); eq(m.world, "1_2")
		row = find(gui, "Brave").Parent
		row.Activated:Fire()
		eq(lastSent(t, "Lobby").world, "1_2")
		-- friends toggle for the selected world
		click(gui, "Friends can join: OFF")
		m = lastSent(t, "Lobby")
		eq(m.type, "setFriends"); eq(m.on, true)
		-- create: name, Hardcore locks the difficulty to Hard
		click(gui, "Create New World")
		assert(find(gui, "World Name"), "create page")
		local boxes = {}
		for _, d in gui:GetDescendants() do
			if d:IsA("TextBox") and visible(d) then
				table.insert(boxes, d)
			end
		end
		eq(#boxes, 2)
		boxes[1].Text = "  Castle  "
		boxes[2].Text = "hello"
		click(gui, "Difficulty: Normal")
		assert(find(gui, "Difficulty: Hard"), "difficulty cycles")
		click(gui, "Game Mode: Survival")
		assert(find(gui, "Game Mode: Hardcore"), "hardcore chosen")
		assert(find(gui, "Difficulty: Hard (Hardcore)"), "locked to Hard")
		assert(find(gui, "Same as Survival"), "hardcore explained")
		click(gui, "Difficulty: Hard (Hardcore)") -- does nothing
		assert(find(gui, "Difficulty: Hard (Hardcore)"), "still Hard")
		local createButtons = {}
		for _, d in gui:GetDescendants() do
			if d:IsA("TextButton") and d.Text == "Create New World" and visible(d) then
				table.insert(createButtons, d)
			end
		end
		eq(#createButtons, 1)
		createButtons[1].Activated:Fire()
		m = lastSent(t, "Lobby")
		eq(m.type, "create"); eq(m.name, "  Castle  "); eq(m.hardcore, true); eq(m.seed, "hello")
		-- the name box is 32 characters at most
		boxes[1].Text = string.rep("x", 40)
		eq(#boxes[1].Text, 32)
		-- the server answers: back to the list with the new world selected
		remote.OnClientEvent:Fire({ type = "created", world = "1_3" })
		assert(find(gui, "Select World"), "back to the list")
		remote.OnClientEvent:Fire({
			type = "state", max = 10, studio = true, listOk = true, saving = true, friendsWorlds = {},
			worlds = {
				{ key = "1_3", name = "Castle", played = 3000, hardcore = true, difficulty = "hard", friends = true },
				{ key = "1", name = "My World", played = 2000, hardcore = false, difficulty = "normal", friends = true },
			},
		})
		assert(find(gui, "Castle"), "the new world is listed")
		-- delete asks first
		click(gui, "Delete")
		assert(find(gui, 'Delete "'), "asks before deleting")
		local before = #sent(t, "Lobby")
		click(gui, "Cancel")
		eq(#sent(t, "Lobby"), before, "cancel sends nothing")
		click(gui, "Delete")
		local yes = nil
		for _, d in gui:GetDescendants() do
			if d:IsA("TextButton") and d.Text == "Delete" and d.ZIndex > 50 then
				yes = d
			end
		end
		assert(yes, "confirm button")
		yes.Activated:Fire()
		eq(lastSent(t, "Lobby").type, "delete")
		-- errors from the server show in the status line
		remote.OnClientEvent:Fire({ type = "status", text = "You already have 10 worlds.", error = true })
		assert(find(gui, "You already have 10 worlds."), "status shown")
		-- options: the FOV slider changes the setting and it is saved a moment later
		click(gui, "Back")
		click(gui, "Options")
		local fov = find(gui, "FOV: Normal")
		assert(fov, "FOV slider")
		local bar = fov.Parent
		rawset(bar, "__absPos", roblox.Vector2.new(100, 0))
		rawset(bar, "__absSize", roblox.Vector2.new(400, 44))
		bar.InputBegan:Fire({ UserInputType = Enum.UserInputType.MouseButton1, Position = Vector3.new(500, 10, 0) })
		assert(find(gui, "FOV: Quake Pro"), "slider moved to 110")
		local Settings = Loader.require("src/client/Player/Settings")
		eq(Settings.get("fov"), 110)
		for _ = 1, 80 do
			t.G.frame(1 / 60)
		end
		local save = lastSent(t, "Settings")
		eq(save.type, "save"); eq(save.settings.fov, 110)
		click(gui, "View Bobbing: ON")
		eq(Settings.get("bobbing"), false)
		assert(find(gui, "Touch Sensitivity", false) == nil, "no touch options on a computer")
		click(gui, "Done")
		assert(find(gui, "Play"), "back home")
		LobbyUI.close()
		eq(t.G.player.PlayerGui:FindFirstChild("TitleScreen"), nil)
		cleanup()
	end)

	test("client: pause menu: P opens it, world settings (owner), quit, not over other windows", function()
		local t = boot()
		local rs = t.G.game:GetService("ReplicatedStorage")
		rs:SetAttribute("Difficulty", "normal")
		rs:SetAttribute("Hardcore", false)
		rs:SetAttribute("FriendsCanJoin", true)
		rs:SetAttribute("WorldOwner", t.G.player.UserId)
		local PauseMenu = Loader.require("src/client/UI/PauseMenu")
		PauseMenu.init()
		local gui = t.G.player.PlayerGui:FindFirstChild("PauseMenu")
		assert(gui, "pause menu gui")
		assert(find(gui, "Back to Game") == nil, "closed at first")
		t.G.press(Enum.KeyCode.P)
		eq(PauseMenu.open, true)
		eq(t.stubs.inventory.uiOpen, true, "gameplay input stops")
		eq(t.stubs.camera.mouseUnlocked, true, "the mouse is free")
		click(gui, "World Settings")
		click(gui, "Difficulty: Normal")
		local m = lastSent(t, "WorldSettings")
		eq(m.type, "difficulty"); eq(m.value, "hard")
		rs:SetAttribute("Difficulty", "hard")
		assert(find(gui, "Difficulty: Hard"), "shows the new difficulty")
		click(gui, "Friends can join: ON")
		m = lastSent(t, "WorldSettings")
		eq(m.type, "friends"); eq(m.on, false)
		-- Hardcore: locked
		rs:SetAttribute("Hardcore", true)
		assert(find(gui, "Difficulty: Hard (Hardcore)"), "locked label")
		local n = #sent(t, "WorldSettings")
		click(gui, "Difficulty: Hard (Hardcore)")
		eq(#sent(t, "WorldSettings"), n, "nothing sent in Hardcore")
		click(gui, "Done")
		click(gui, "Back to Game")
		eq(PauseMenu.open, false)
		eq(t.stubs.inventory.uiOpen, false)
		eq(t.stubs.camera.mouseUnlocked, false)
		-- the button at the top opens it too; Save and Quit sends quit
		eq(find(gui, "II"), nil, "no pause button on a computer (the mouse is locked; P opens it)")
		PauseMenu.setOpen(true)
		eq(PauseMenu.open, true)
		click(gui, "Save and Quit to Title")
		eq(lastSent(t, "Menu").type, "quit")
		t.remotes.Menu.OnClientEvent:Fire({ type = "status", text = "Saving..." })
		assert(find(gui, "Saving..."), "status")
		-- dying closes it
		t.stubs.survival.fire:Fire("died")
		eq(PauseMenu.open, false)
		-- with the inventory open, P does nothing
		t.stubs.inventory.uiOpen = true
		t.G.press(Enum.KeyCode.P)
		eq(PauseMenu.open, false)
		t.stubs.inventory.uiOpen = false
		-- a visitor can't change world settings (nothing sent)
		rs:SetAttribute("WorldOwner", 999)
		rs:SetAttribute("Hardcore", false)
		PauseMenu.setOpen(true)
		click(gui, "World Settings")
		-- (Studio counts as owner; the label says who can change it)
		click(gui, "Done")
		PauseMenu.setOpen(false)
		cleanup()
	end)

	test("client: touch controls: arrows, sneak, sprint, jump, tap, hold, drag", function()
		local t = boot()
		local uis = t.G.game:GetService("UserInputService")
		uis.TouchEnabled = true
		local TouchControls = Loader.require("src/client/UI/TouchControls")
		TouchControls.init()
		eq(TouchControls.active, true)
		local state = t.stubs.movement.touch
		assert(state, "movement reads our controls")
		eq(t.stubs.camera.touchOwned, true)
		local gui = t.G.player.PlayerGui:FindFirstChild("TouchControls")
		-- lay the pad and the jump button out like on a phone (the fake has no layout engine)
		local pad = find(gui, "▲").Parent
		rawset(pad, "__absPos", roblox.Vector2.new(16, 500))
		rawset(pad, "__absSize", roblox.Vector2.new(150, 150))
		local up = find(gui, "◆")
		rawset(up, "__absPos", roblox.Vector2.new(66, 550))
		rawset(up, "__absSize", roblox.Vector2.new(50, 50))
		local jump = find(gui, "⬆")
		rawset(jump, "__absPos", roblox.Vector2.new(1180, 560))
		rawset(jump, "__absSize", roblox.Vector2.new(80, 80))
		local function touch(x: number, y: number)
			return { UserInputType = Enum.UserInputType.Touch, Position = Vector3.new(x, y, 0),
				Delta = Vector3.zero, UserInputState = Enum.UserInputState.Begin }
		end
		-- forward, then slide to the right arrow
		local f = touch(91, 520)
		uis.TouchStarted:Fire(f, false)
		eq(state.forward, 1); eq(state.strafe, 0)
		f.Position = Vector3.new(150, 575, 0)
		uis.TouchMoved:Fire(f, false)
		eq(state.forward, 0); eq(state.strafe, 1)
		f.Position = Vector3.new(150, 520, 0) -- forward-right diagonal
		uis.TouchMoved:Fire(f, false)
		eq(state.forward, 1); eq(state.strafe, 1)
		uis.TouchEnded:Fire(f, false)
		eq(state.forward, 0); eq(state.strafe, 0)
		-- double tap forward sprints
		for _ = 1, 2 do
			local d = touch(91, 520)
			uis.TouchStarted:Fire(d, false)
			t.G.frame(0.05)
			uis.TouchEnded:Fire(d, false)
			t.G.frame(0.05)
		end
		eq(t.stubs.movement.sprints, 1)
		-- the middle button sneaks (toggle)
		uis.TouchStarted:Fire(touch(91, 575), false)
		eq(t.stubs.movement.sneaks, 1)
		eq(state.forward, 0)
		-- jump: held while the finger is on it, while walking with the other
		local mv = touch(91, 520)
		uis.TouchStarted:Fire(mv, false)
		local j = touch(1220, 600)
		uis.TouchStarted:Fire(j, false)
		eq(state.jump, true); eq(state.forward, 1)
		uis.TouchEnded:Fire(j, false)
		eq(state.jump, false); eq(state.forward, 1)
		uis.TouchEnded:Fire(mv, false)
		-- the world: a quick tap uses / places where it was tapped
		local w = touch(640, 300)
		uis.TouchStarted:Fire(w, false)
		t.G.frame(0.1)
		uis.TouchEnded:Fire(w, false)
		eq(t.stubs.block.log[#t.stubs.block.log], "touchTap")
		-- a still finger breaks (hold), letting go stops
		w = touch(640, 300)
		uis.TouchStarted:Fire(w, false)
		for _ = 1, 30 do
			t.G.frame(1 / 60)
		end
		eq(t.stubs.block.log[#t.stubs.block.log], "touchHold")
		local turnedBefore = t.stubs.camera.turned[1]
		w.Position = Vector3.new(660, 310, 0)
		uis.TouchMoved:Fire(w, false)
		eq(t.stubs.block.log[#t.stubs.block.log], "touchHold") -- still breaking at the crosshair
		assert(t.stubs.camera.turned[1] > turnedBefore, "moving the finger while breaking turns the view")
		uis.TouchEnded:Fire(w, false)
		eq(t.stubs.block.log[#t.stubs.block.log], "touchRelease")
		-- a drag turns the camera and doesn't tap
		local n = #t.stubs.block.log
		w = touch(640, 300)
		uis.TouchStarted:Fire(w, false)
		w.Position = Vector3.new(700, 320, 0)
		uis.TouchMoved:Fire(w, false)
		w.Position = Vector3.new(720, 330, 0)
		uis.TouchMoved:Fire(w, false)
		uis.TouchEnded:Fire(w, false)
		eq(#t.stubs.block.log, n, "a drag is not a tap")
		assert(t.stubs.camera.turned[1] > 0, "the camera turned")
		-- touches on buttons (processed) don't reach the world
		uis.TouchStarted:Fire(touch(640, 300), true)
		t.G.frame(0.5)
		eq(#t.stubs.block.log, n)
		-- a window open: the controls hide and do nothing
		t.stubs.inventory.uiOpen = true
		t.G.frame(1 / 60)
		eq(gui.Enabled, false)
		uis.TouchStarted:Fire(touch(91, 520), false)
		eq(state.forward, 0)
		t.stubs.inventory.uiOpen = false
		t.G.frame(1 / 60)
		eq(gui.Enabled, true)
		cleanup()
	end)

	for _, k in { "game", "workspace", "Instance", "Enum", "CFrame", "Vector2", "Color3", "UDim2", "UDim", "task", "os", "time", "tick", "warn", "Random" } do
		Loader.globals[k] = nil
	end
	Loader.forget("src/client/")
end
