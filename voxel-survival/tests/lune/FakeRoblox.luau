--!nocheck
-- A small fake Roblox for headless tests of client code (Lune): enough of the DataModel to run
-- the real client modules frame by frame and catch what compiling can't: calling something that
-- is nil, a misspelt Roblox member, waiting forever on a child that never comes, state that
-- goes wrong over many frames.
--
-- It is strict on purpose:
--   * only the classes, properties and methods listed here exist; anything else raises the same
--     kind of error Roblox would ("X is not a valid member of Y")
--   * WaitForChild without a timeout on a missing child raises (in Roblox it would hang)
--   * yielding inside a render step raises
-- and it models the one piece of physics the movement code has to live with: an unanchored
-- part falls under workspace.Gravity between frames (less any VectorForce on it) and moves by
-- its velocity, in 32-bit floats.
--
-- Datatypes (Vector3, CFrame, Enum, ...) are Lune's real implementations.

local roblox = require("@lune/roblox")
local Vector3, CFrame, Enum = roblox.Vector3, roblox.CFrame, roblox.Enum

local Fake = {}
Fake.Vector3, Fake.CFrame, Fake.Enum = Vector3, CFrame, Enum
Fake.Vector2, Fake.Color3, Fake.UDim2, Fake.UDim = roblox.Vector2, roblox.Color3, roblox.UDim2, roblox.UDim

local NIL = newproxy(false) -- "this property exists and is nil"

-- Signals --------------------------------------------------------------------------------------

local Signal = {}
Signal.__index = Signal
function Signal.new(name: string?)
	return setmetatable({ name = name or "signal", handlers = {} }, Signal)
end
function Signal:Connect(fn)
	assert(type(fn) == "function", "Connect expects a function")
	local c = { Connected = true }
	function c.Disconnect(conn)
		conn.Connected = false
	end
	c.fn = fn
	table.insert(self.handlers, c)
	return c
end
function Signal:Once(fn)
	local c
	c = self:Connect(function(...)
		c:Disconnect()
		fn(...)
	end)
	return c
end
function Signal:Wait()
	error(`FakeRoblox: {self.name}:Wait() would block the test`, 2)
end
function Signal:Fire(...)
	for _, c in table.clone(self.handlers) do
		if c.Connected then
			c.fn(...)
		end
	end
end
Fake.Signal = Signal

-- Classes --------------------------------------------------------------------------------------

type Class = { parent: string?, props: { [string]: any }?, getters: any?, setters: any?, methods: any?, signals: { string }? }
local CLASSES: { [string]: Class } = {}

local InstanceMeta = {}

local function classChain(name: string)
	local list = {}
	local c = CLASSES[name]
	local n: string? = name
	while c do
		table.insert(list, { name = n, def = c })
		n = c.parent
		c = n and CLASSES[n]
	end
	return list
end

local function describe(self): string
	return `{rawget(self, "__class")} "{rawget(self, "__props").Name}"`
end

local function signalOf(self, name: string)
	local signals = rawget(self, "__signals")
	local s = signals[name]
	if not s then
		s = Signal.new(name)
		signals[name] = s
	end
	return s
end

local function fireAdded(parent, inst)
	signalOf(parent, "ChildAdded"):Fire(inst)
	local list = { inst }
	for _, d in InstanceMeta.__index(inst, "GetDescendants")(inst) do
		table.insert(list, d)
	end
	local a = parent
	while a do
		for _, d in list do
			signalOf(a, "DescendantAdded"):Fire(d)
		end
		a = rawget(a, "__parent")
	end
end

local function setParent(self, parent)
	local old = rawget(self, "__parent")
	if old == parent then
		return
	end
	if rawget(self, "__destroyed") and parent ~= nil then
		error(`The Parent property of {describe(self)} is locked (it was destroyed)`, 3)
	end
	if old then
		local list = rawget(old, "__children")
		local i = table.find(list, self)
		if i then
			table.remove(list, i)
		end
		signalOf(old, "ChildRemoved"):Fire(self)
	end
	rawset(self, "__parent", parent)
	if parent then
		table.insert(rawget(parent, "__children"), self)
		fireAdded(parent, self)
	end
	signalOf(self, "AncestryChanged"):Fire(self, parent)
end

local COMMON_SIGNALS = {
	ChildAdded = true, ChildRemoved = true, DescendantAdded = true, DescendantRemoving = true,
	AncestryChanged = true, Destroying = true, Changed = true, AttributeChanged = true,
}

local COMMON_METHODS = {}
function COMMON_METHODS.GetChildren(self)
	return table.clone(rawget(self, "__children"))
end
function COMMON_METHODS.GetDescendants(self)
	local out = {}
	local function walk(n)
		for _, c in rawget(n, "__children") do
			table.insert(out, c)
			walk(c)
		end
	end
	walk(self)
	return out
end
function COMMON_METHODS.FindFirstChild(self, name: string, recursive: boolean?)
	local foreign = rawget(self, "__foreign")
	if foreign and foreign[name] ~= nil then
		return foreign[name]
	end
	for _, c in rawget(self, "__children") do
		if rawget(c, "__props").Name == name then
			return c
		end
	end
	if recursive then
		for _, c in COMMON_METHODS.GetDescendants(self) do
			if rawget(c, "__props").Name == name then
				return c
			end
		end
	end
	return nil
end
function COMMON_METHODS.IsA(self, className: string): boolean
	for _, c in classChain(rawget(self, "__class")) do
		if c.name == className then
			return true
		end
	end
	return false
end
function COMMON_METHODS.FindFirstChildOfClass(self, className: string)
	for _, c in rawget(self, "__children") do
		if rawget(c, "__class") == className then
			return c
		end
	end
	return nil
end
function COMMON_METHODS.FindFirstChildWhichIsA(self, className: string)
	for _, c in rawget(self, "__children") do
		if COMMON_METHODS.IsA(c, className) then
			return c
		end
	end
	return nil
end
function COMMON_METHODS.FindFirstAncestorOfClass(self, className: string)
	local a = rawget(self, "__parent")
	while a do
		if rawget(a, "__class") == className then
			return a
		end
		a = rawget(a, "__parent")
	end
	return nil
end
function COMMON_METHODS.IsDescendantOf(self, other): boolean
	local a = rawget(self, "__parent")
	while a do
		if a == other then
			return true
		end
		a = rawget(a, "__parent")
	end
	return false
end
function COMMON_METHODS.WaitForChild(self, name: string, timeout: number?)
	local c = COMMON_METHODS.FindFirstChild(self, name)
	if c then
		return c
	end
	if timeout then
		return nil -- (after `timeout` seconds in Roblox)
	end
	error(`Infinite yield possible on '{describe(self)}:WaitForChild("{name}")' (the child never appears)`, 2)
end
function COMMON_METHODS.Destroy(self)
	if rawget(self, "__destroyed") then
		return
	end
	signalOf(self, "Destroying"):Fire()
	for _, c in table.clone(rawget(self, "__children")) do
		COMMON_METHODS.Destroy(c)
	end
	setParent(self, nil)
	rawset(self, "__destroyed", true)
end
function COMMON_METHODS.ClearAllChildren(self)
	for _, c in table.clone(rawget(self, "__children")) do
		COMMON_METHODS.Destroy(c)
	end
end
function COMMON_METHODS.SetAttribute(self, name: string, value: any)
	rawget(self, "__attrs")[name] = value
	signalOf(self, "AttributeChanged"):Fire(name)
	local s = rawget(self, "__signals")["attr:" .. name]
	if s then
		s:Fire()
	end
end
function COMMON_METHODS.GetAttribute(self, name: string)
	return rawget(self, "__attrs")[name]
end
function COMMON_METHODS.GetAttributes(self)
	return table.clone(rawget(self, "__attrs"))
end
function COMMON_METHODS.GetAttributeChangedSignal(self, name: string)
	return signalOf(self, "attr:" .. name)
end
function COMMON_METHODS.GetPropertyChangedSignal(self, name: string)
	return signalOf(self, "prop:" .. name)
end
function COMMON_METHODS.GetFullName(self): string
	local parts = {}
	local a = self
	while a do
		table.insert(parts, 1, rawget(a, "__props").Name)
		a = rawget(a, "__parent")
	end
	return table.concat(parts, ".")
end

InstanceMeta.__index = function(self, key)
	if key == "ClassName" then
		return rawget(self, "__class")
	elseif key == "Parent" then
		return rawget(self, "__parent")
	end
	local props = rawget(self, "__props")
	local v = props[key]
	if v ~= nil then
		return if v == NIL then nil else v
	end
	for _, c in classChain(rawget(self, "__class")) do
		local def = c.def
		local getter = def.getters and def.getters[key]
		if getter then
			return getter(self)
		end
		local d = def.props and def.props[key]
		if d ~= nil then
			return if d == NIL then nil else d
		end
		local m = def.methods and def.methods[key]
		if m then
			return m
		end
		if def.signals and table.find(def.signals, key) then
			return signalOf(self, key)
		end
	end
	if COMMON_METHODS[key] then
		return COMMON_METHODS[key]
	end
	if COMMON_SIGNALS[key] then
		return signalOf(self, key)
	end
	for _, c in rawget(self, "__children") do
		if rawget(c, "__props").Name == key then
			return c
		end
	end
	local foreign = rawget(self, "__foreign")
	if foreign and foreign[key] ~= nil then
		return foreign[key]
	end
	error(`{tostring(key)} is not a valid member of {describe(self)}`, 2)
end

InstanceMeta.__newindex = function(self, key, value)
	if key == "Parent" then
		setParent(self, value)
		return
	end
	local props = rawget(self, "__props")
	if key == "Name" then
		props.Name = tostring(value)
		return
	end
	for _, c in classChain(rawget(self, "__class")) do
		local def = c.def
		local setter = def.setters and def.setters[key]
		if setter then
			setter(self, value)
			signalOf(self, "prop:" .. key):Fire()
			return
		end
		if def.props and def.props[key] ~= nil then
			props[key] = if value == nil then NIL else value
			signalOf(self, "prop:" .. key):Fire()
			signalOf(self, "Changed"):Fire(key)
			return
		end
		if def.getters and def.getters[key] then
			error(`Unable to assign property {key} of {describe(self)}: it is read only`, 2)
		end
	end
	error(`{tostring(key)} is not a valid member of {describe(self)}`, 2)
end
InstanceMeta.__tostring = function(self)
	return rawget(self, "__props").Name
end

local function new(className: string, parent: any?)
	if not CLASSES[className] then
		error(`FakeRoblox: class {className} is not modelled yet (add it to tests/lune/FakeRoblox.luau)`, 2)
	end
	local self = setmetatable({
		__class = className, __props = { Name = className }, __children = {}, __signals = {}, __attrs = {},
	}, InstanceMeta)
	local init = CLASSES[className].init
	if init then
		init(self)
	end
	if parent then
		setParent(self, parent)
	end
	return self
end
Fake.Instance = { new = new }

-- Put something that isn't a fake Instance under one, by name (the module tree: what
-- ReplicatedStorage:WaitForChild("Shared") returns is the test loader's node for src/shared).
function Fake.mount(parent, name: string, object: any)
	local foreign = rawget(parent, "__foreign")
	if not foreign then
		foreign = {}
		rawset(parent, "__foreign", foreign)
	end
	foreign[name] = object
end

-- Class definitions (extend as the tests need more) ---------------------------------------------

CLASSES.Instance = { props = { Archivable = true } }
CLASSES.Folder = { parent = "Instance" }
CLASSES.Model = { parent = "Instance", props = { PrimaryPart = NIL } }
CLASSES.Configuration = { parent = "Instance" }
CLASSES.StringValue = { parent = "Instance", props = { Value = "" } }
CLASSES.Animation = { parent = "Instance", props = { AnimationId = "" } }
CLASSES.BaseScript = { parent = "Instance", props = { Enabled = true, Disabled = false } }
CLASSES.LocalScript = { parent = "BaseScript" }
CLASSES.Script = { parent = "BaseScript" }
CLASSES.Attachment = { parent = "Instance", props = { CFrame = CFrame.new(), Visible = false } }
CLASSES.Constraint = { parent = "Instance", props = { Enabled = true, Attachment0 = NIL, Attachment1 = NIL, Visible = false } }
CLASSES.VectorForce = {
	parent = "Constraint",
	props = { Force = Vector3.zero, RelativeTo = Enum.ActuatorRelativeTo.Attachment0, ApplyAtCenterOfMass = false },
}
CLASSES.Motor6D = { parent = "Instance", props = { C0 = CFrame.new(), C1 = CFrame.new(), Part0 = NIL, Part1 = NIL } }
CLASSES.WeldConstraint = { parent = "Instance", props = { Part0 = NIL, Part1 = NIL, Enabled = true } }
CLASSES.BindableEvent = {
	parent = "Instance",
	signals = { "Event" },
	methods = {
		Fire = function(self, ...)
			signalOf(self, "Event"):Fire(...)
		end,
	},
}
CLASSES.RemoteEvent = {
	parent = "Instance",
	signals = { "OnClientEvent", "OnServerEvent" },
	init = function(self)
		rawset(self, "__sent", {})
	end,
	methods = {
		FireServer = function(self, ...)
			table.insert(rawget(self, "__sent"), { ... })
		end,
	},
}

CLASSES.BasePart = {
	parent = "Instance",
	props = {
		Anchored = false, CanCollide = true, CanQuery = true, CanTouch = true, CollisionGroup = "Default",
		Massless = false, CastShadow = true, Transparency = 0, LocalTransparencyModifier = 0, Reflectance = 0,
		Size = Vector3.new(2, 2, 1), Color = roblox.Color3.new(1, 1, 1), Material = Enum.Material.Plastic,
		CFrame = CFrame.new(), AssemblyLinearVelocity = Vector3.zero, AssemblyAngularVelocity = Vector3.zero,
		CustomPhysicalProperties = NIL, TopSurface = Enum.SurfaceType.Smooth, BottomSurface = Enum.SurfaceType.Smooth,
	},
	getters = {
		Position = function(self)
			return InstanceMeta.__index(self, "CFrame").Position
		end,
		AssemblyMass = function(_self)
			return 9.8 -- an R6 character, about
		end,
	},
	setters = {
		Position = function(self, v)
			local cf = InstanceMeta.__index(self, "CFrame")
			rawget(self, "__props").CFrame = (cf - cf.Position) + v
		end,
	},
	signals = { "Touched" },
}
CLASSES.Part = { parent = "BasePart", props = { Shape = Enum.PartType.Block } }
CLASSES.MeshPart = { parent = "BasePart" }

CLASSES.Humanoid = {
	parent = "Instance",
	props = {
		Health = 100, MaxHealth = 100, WalkSpeed = 16, JumpHeight = 7.2, JumpPower = 50, UseJumpPower = true,
		AutoRotate = true, Jump = false, MoveDirection = Vector3.zero, FloorMaterial = Enum.Material.Air,
		HipHeight = 0, PlatformStand = false, Sit = false, BreakJointsOnDeath = true, RigType = Enum.HumanoidRigType.R6,
		DisplayDistanceType = Enum.HumanoidDisplayDistanceType.Viewer,
	},
	setters = {
		Health = function(self, v)
			local props = rawget(self, "__props")
			local was = props.Health or 100
			props.Health = math.max(0, v)
			if was > 0 and props.Health <= 0 then
				rawset(self, "__state", Enum.HumanoidStateType.Dead)
				signalOf(self, "Died"):Fire()
			end
		end,
	},
	signals = { "Died", "StateChanged", "Running", "HealthChanged", "Jumping", "FreeFalling" },
	init = function(self)
		rawset(self, "__state", Enum.HumanoidStateType.Freefall)
		rawset(self, "__enabled", {})
	end,
	methods = {
		GetState = function(self)
			return rawget(self, "__state")
		end,
		ChangeState = function(self, state)
			local old = rawget(self, "__state")
			if old == Enum.HumanoidStateType.Dead then
				return
			end
			rawset(self, "__state", state)
			if old ~= state then
				signalOf(self, "StateChanged"):Fire(old, state)
			end
		end,
		SetStateEnabled = function(self, state, enabled: boolean)
			rawget(self, "__enabled")[state] = enabled
		end,
		GetStateEnabled = function(self, state): boolean
			return rawget(self, "__enabled")[state] ~= false
		end,
		Move = function(self, dir, _relativeToCamera)
			rawget(self, "__props").MoveDirection = dir
		end,
	},
}

CLASSES.Animator = {
	parent = "Instance",
	init = function(self)
		rawset(self, "__tracks", {})
	end,
	methods = {
		LoadAnimation = function(self, animation)
			assert(animation and animation:IsA("Animation"), "LoadAnimation expects an Animation")
			local track = { Name = animation.Name, IsPlaying = false, Speed = 1, Looped = true, plays = 0 }
			function track.Play(t, _fade)
				t.IsPlaying = true
				t.plays += 1
			end
			function track.Stop(t, _fade)
				t.IsPlaying = false
			end
			function track.AdjustSpeed(t, s)
				t.Speed = s
			end
			table.insert(rawget(self, "__tracks"), track)
			return track
		end,
		GetPlayingAnimationTracks = function(self)
			local out = {}
			for _, t in rawget(self, "__tracks") do
				if t.IsPlaying then
					table.insert(out, t)
				end
			end
			return out
		end,
	},
}

CLASSES.Camera = {
	parent = "Instance",
	props = {
		CFrame = CFrame.new(), Focus = CFrame.new(), FieldOfView = 70, CameraType = Enum.CameraType.Custom,
		ViewportSize = roblox.Vector2.new(1280, 720), CameraSubject = NIL,
	},
}

CLASSES.Player = {
	parent = "Instance",
	props = { Character = NIL, DisplayName = "Tester", UserId = 1 },
	signals = { "CharacterAdded", "CharacterRemoving" },
}
CLASSES.PlayerGui = { parent = "Instance" }
CLASSES.PlayerScripts = { parent = "Instance" }

-- Services -------------------------------------------------------------------------------------

CLASSES.Workspace = {
	parent = "Instance",
	props = { Gravity = 196.2, CurrentCamera = NIL, FallenPartsDestroyHeight = -500 },
	methods = {
		Raycast = function()
			return nil
		end,
		GetServerTimeNow = function()
			return Fake.now
		end,
	},
}
CLASSES.Players = { parent = "Instance", props = { LocalPlayer = NIL, CharacterAutoLoads = true }, signals = { "PlayerAdded", "PlayerRemoving" } }
CLASSES.ReplicatedStorage = { parent = "Instance" }
CLASSES.GuiService = { parent = "Instance", props = { MenuIsOpen = false } }
CLASSES.RunService = {
	parent = "Instance",
	signals = { "Heartbeat", "RenderStepped", "Stepped", "PreRender", "PreSimulation", "PostSimulation" },
	init = function(self)
		rawset(self, "__bound", {})
	end,
	methods = {
		BindToRenderStep = function(self, name: string, priority: number, fn)
			assert(type(name) == "string" and type(priority) == "number" and type(fn) == "function", "BindToRenderStep(name, priority, function)")
			local bound = rawget(self, "__bound")
			for _, b in bound do
				assert(b.name ~= name, `BindToRenderStep: '{name}' is already bound`)
			end
			table.insert(bound, { name = name, priority = priority, fn = fn })
			table.sort(bound, function(a, b)
				return a.priority < b.priority
			end)
		end,
		UnbindFromRenderStep = function(self, name: string)
			local bound = rawget(self, "__bound")
			for i, b in bound do
				if b.name == name then
					table.remove(bound, i)
					return
				end
			end
		end,
		IsStudio = function()
			return true
		end,
		IsClient = function()
			return true
		end,
		IsServer = function()
			return false
		end,
		IsRunning = function()
			return true
		end,
	},
}
CLASSES.UserInputService = {
	parent = "Instance",
	props = {
		MouseBehavior = Enum.MouseBehavior.Default, MouseIconEnabled = true, TouchEnabled = false,
		GamepadEnabled = false, KeyboardEnabled = true, MouseEnabled = true,
	},
	signals = { "InputBegan", "InputEnded", "InputChanged", "TouchStarted", "TouchEnded", "JumpRequest" },
	init = function(self)
		rawset(self, "__keys", {})
		rawset(self, "__focused", nil)
	end,
	methods = {
		IsKeyDown = function(self, key): boolean
			return rawget(self, "__keys")[key] == true
		end,
		GetFocusedTextBox = function(self)
			return rawget(self, "__focused")
		end,
		GetGamepadState = function()
			return {}
		end,
		IsGamepadButtonDown = function()
			return false
		end,
		GetMouseDelta = function()
			return roblox.Vector2.new(0, 0)
		end,
		GetMouseLocation = function()
			return roblox.Vector2.new(640, 360)
		end,
	},
}

-- The fake DataModel ----------------------------------------------------------------------------

Fake.now = 0 -- seconds since the fake game started (os.clock / time inside modules)

-- Build a fresh game. Returns the globals to hand to the code under test.
function Fake.newGame()
	Fake.now = 100
	local services: { [string]: any } = {}
	local game = setmetatable({}, {
		__index = function(_, key)
			if key == "GetService" then
				return function(_self, name: string)
					local s = services[name]
					if not s then
						if not CLASSES[name] then
							error(`FakeRoblox: service {name} is not modelled yet (add it to tests/lune/FakeRoblox.luau)`, 2)
						end
						s = new(name)
						services[name] = s
					end
					return s
				end
			end
			error(`{tostring(key)} is not a valid member of DataModel "Game"`, 2)
		end,
	})
	local workspace = game:GetService("Workspace")
	workspace.Gravity = 196.2
	workspace.CurrentCamera = new("Camera", workspace)
	local players = game:GetService("Players")
	local player = new("Player", players)
	player.Name = "Tester"
	new("PlayerGui", player)
	new("PlayerScripts", player)
	players.LocalPlayer = player

	-- task: spawn / defer run at once; wait and delay go by the fake clock (Fake.advance)
	local sleeping: { { at: number, thread: thread, args: { any } } } = {}
	local inRenderStep = false
	local task = {}
	local function resume(thread: thread, ...)
		local ok, err = coroutine.resume(thread, ...)
		if not ok then
			error(`error in a spawned thread: {tostring(err)}\n{debug.traceback(thread)}`, 0)
		end
	end
	function task.spawn(fn, ...)
		local thread = if type(fn) == "thread" then fn else coroutine.create(fn)
		resume(thread, ...)
		return thread
	end
	task.defer = task.spawn
	function task.delay(t: number, fn, ...)
		table.insert(sleeping, { at = Fake.now + (t or 0), thread = coroutine.create(fn), args = { ... } })
	end
	function task.wait(t: number?)
		if inRenderStep and coroutine.running() == Fake.mainThread then
			error("FakeRoblox: task.wait() inside a render step", 2)
		end
		table.insert(sleeping, { at = Fake.now + (t or 0), thread = coroutine.running(), args = {} })
		return coroutine.yield()
	end
	function task.cancel() end

	local env = {
		game = game, workspace = workspace, Instance = Fake.Instance, Enum = Enum, Vector3 = Vector3, CFrame = CFrame,
		Vector2 = roblox.Vector2, Color3 = roblox.Color3, UDim2 = roblox.UDim2, UDim = roblox.UDim, task = task,
		os = { clock = function()
			return Fake.now
		end, time = os.time, date = os.date },
		time = function()
			return Fake.now
		end,
		tick = function()
			return Fake.now
		end,
		warn = function(...)
			table.insert(Fake.warnings, table.concat({ ... }, " "))
		end,
	}
	Fake.warnings = {}
	Fake.mainThread = coroutine.running()

	local G = { env = env, game = game, workspace = workspace, player = player, services = services }

	-- One frame: render steps (in priority order), RenderStepped, physics, Heartbeat.
	function G.frame(dt: number)
		Fake.now += dt
		local run = game:GetService("RunService")
		inRenderStep = true
		for _, b in table.clone(rawget(run, "__bound")) do
			-- a render step must not yield (in Roblox the frame would go on without it)
			local thread = coroutine.create(b.fn)
			local ok, err = coroutine.resume(thread, dt)
			if not ok then
				inRenderStep = false
				error(`error in render step '{b.name}': {tostring(err)}\n{debug.traceback(thread)}`, 0)
			end
			if coroutine.status(thread) ~= "dead" then
				inRenderStep = false
				error(`render step '{b.name}' yielded (it waits for something every frame)`, 0)
			end
		end
		inRenderStep = false
		run.RenderStepped:Fire(dt)
		G.physics(dt)
		run.Stepped:Fire(Fake.now, dt)
		run.Heartbeat:Fire(dt)
		-- wake sleeping threads
		local due = {}
		for i = #sleeping, 1, -1 do
			if sleeping[i].at <= Fake.now then
				table.insert(due, 1, table.remove(sleeping, i))
			end
		end
		for _, s in due do
			resume(s.thread, table.unpack(s.args))
		end
	end

	-- What Roblox physics does to the local character between frames: nothing collides (the
	-- server has no terrain and the client's body is a ghost), so an unanchored root just moves
	-- by its velocity and falls, unless a VectorForce holds it up.
	function G.physics(dt: number)
		local character = player.Character
		local root = character and character:FindFirstChild("HumanoidRootPart")
		if not root or root.Anchored then
			return
		end
		local mass = root.AssemblyMass
		local fy = 0
		for _, d in root:GetDescendants() do
			if d:IsA("VectorForce") and d.Enabled and d.Attachment0 ~= nil then
				fy += d.Force.Y
			end
		end
		local v = root.AssemblyLinearVelocity
		-- Roblox steps physics at 240 Hz
		local steps = math.max(1, math.floor(dt * 240 + 0.5))
		local h = dt / steps
		local pos = root.Position
		for _ = 1, steps do
			v += Vector3.new(0, (fy / mass - workspace.Gravity) * h, 0)
			pos += v * h
		end
		root.AssemblyLinearVelocity = v
		root.Position = pos
	end

	-- Keyboard
	local uis = game:GetService("UserInputService")
	local function inputObject(key)
		return { KeyCode = key, UserInputType = Enum.UserInputType.Keyboard, UserInputState = Enum.UserInputState.Begin, Position = Vector3.zero, Delta = Vector3.zero }
	end
	function G.press(key, processed: boolean?)
		rawget(uis, "__keys")[key] = true
		uis.InputBegan:Fire(inputObject(key), processed == true)
	end
	function G.release(key)
		rawget(uis, "__keys")[key] = nil
		uis.InputEnded:Fire(inputObject(key), false)
	end
	function G.focusTextBox(on: boolean)
		rawset(uis, "__focused", if on then {} else nil)
	end

	return G
end

-- An R6 character like the one AvatarService builds, with its root at `rootCFrame`.
function Fake.newCharacter(name: string, rootCFrame: any)
	local character = new("Model")
	character.Name = name
	local function part(n: string, size)
		local p = new("Part")
		p.Name = n
		p.Size = size
		p.CFrame = rootCFrame
		p.Parent = character
		return p
	end
	local root = part("HumanoidRootPart", Vector3.new(2, 2, 1))
	character.PrimaryPart = root
	local torso = part("Torso", Vector3.new(2, 2, 1))
	part("Head", Vector3.new(2, 1, 1))
	part("Left Arm", Vector3.new(1, 2, 1))
	part("Right Arm", Vector3.new(1, 2, 1))
	part("Left Leg", Vector3.new(1, 2, 1))
	part("Right Leg", Vector3.new(1, 2, 1))
	local rootJoint = new("Motor6D", root)
	rootJoint.Name = "RootJoint"
	for _, n in { "Right Hip", "Left Hip", "Right Shoulder", "Left Shoulder", "Neck" } do
		local m = new("Motor6D", torso)
		m.Name = n
	end
	local humanoid = new("Humanoid", character)
	new("Animator", humanoid)
	local animate = new("LocalScript", character)
	animate.Name = "Animate"
	for holder, animName in { idle = "Animation1", walk = "WalkAnim", run = "RunAnim", jump = "JumpAnim", fall = "FallAnim", climb = "ClimbAnim" } do
		local sv = new("StringValue", animate)
		sv.Name = holder
		local a = new("Animation", sv)
		a.Name = animName
	end
	return character
end

return Fake
