--!strict
-- Client side of signs and item frames (server: Simulation/DecorService).
--   * keeps every sign's (already filtered) text; TorchRenderer draws it on the sign models
--   * the sign editor: 4 lines, opened after placing a sign or by right-clicking one
--   * item frame models (a wooden frame with the item's icon, turned in 45 degree steps) and a
--     raycast so the crosshair can pick them

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared.Config)
local Remotes = require(Shared.Net.Remotes)
local BlockRegistry = require(Shared.Blocks.BlockRegistry)
local Shapes = require(Shared.Blocks.Shapes)
local ItemIcon = require(script.Parent.Parent.UI.ItemIcon)
local InventoryClient = require(script.Parent.Parent.Player.InventoryClient)
local CameraController = require(script.Parent.Parent.Player.CameraController)
local TorchRenderer = require(script.Parent.Parent.Render.TorchRenderer)
local ClientWorld = require(script.Parent.ClientWorld)

local BS = Config.BLOCK_SIZE
local MAX_LINE = 18

local DecorClient = {}
DecorClient.signChanged = Instance.new("BindableEvent") -- (x, y, z)
DecorClient.editing = false

local signs: { [string]: { front: { string }, back: { string } } } = {}
type Frame = { key: string, x: number, y: number, z: number, facing: string, rot: number, item: string?, model: Model? }
local frames: { [string]: Frame } = {}
local folder: Folder

local FACE_DIR: { [string]: Vector3 } = {
	up = Vector3.yAxis, down = -Vector3.yAxis, north = -Vector3.zAxis, south = Vector3.zAxis,
	east = Vector3.xAxis, west = -Vector3.xAxis,
}

local function key(x: number, y: number, z: number): string
	return `{x},{y},{z}`
end

function DecorClient.signText(x: number, y: number, z: number): { front: { string }, back: { string } }?
	return signs[key(x, y, z)]
end

-- The sign's front direction (unit, horizontal) for a sign block id.
function DecorClient.signNormal(id: number): Vector3
	local d = BlockRegistry.byId[id]
	if d and d.shape == "wall_sign" then
		local v = Shapes.DIR[d.state.facing :: string]
		return Vector3.new(v[1], 0, v[2])
	end
	local r = (d and d.state.rotation or 0) :: number
	local t = math.rad(r * 22.5)
	return Vector3.new(-math.sin(t), 0, math.cos(t))
end

-- Item frames ----------------------------------------------------------------------------------

local function frameCFrame(f: Frame): CFrame
	local n = FACE_DIR[f.facing]
	local centre = (Vector3.new(f.x, f.y, f.z) + Vector3.one * 0.5 - n * (0.5 - 1 / 32)) * BS
	local up = if math.abs(n.Y) > 0.5 then Vector3.zAxis else Vector3.yAxis
	return CFrame.lookAt(centre, centre + n, up)
end

local function buildFrame(f: Frame)
	if f.model then
		(f.model :: Model):Destroy()
	end
	local m = Instance.new("Model")
	m.Name = "ItemFrame"
	local p = Instance.new("Part")
	p.Anchored = true
	p.CanCollide = false
	p.CanQuery = false
	p.CanTouch = false
	p.CastShadow = false
	p.Material = Enum.Material.Wood
	p.Color = Color3.fromRGB(140, 100, 60)
	p.Size = Vector3.new(0.75 * BS, 0.75 * BS, BS / 16)
	p.CFrame = frameCFrame(f)
	p.Parent = m
	local gui = Instance.new("SurfaceGui")
	gui.Face = Enum.NormalId.Front
	gui.CanvasSize = Vector2.new(96, 96)
	gui.LightInfluence = 1
	local back = Instance.new("Frame")
	back.BorderSizePixel = 0
	back.BackgroundColor3 = Color3.fromRGB(124, 78, 46)
	back.Size = UDim2.fromScale(0.8, 0.8)
	back.Position = UDim2.fromScale(0.1, 0.1)
	back.Parent = gui
	if f.item then
		local icon = Instance.new("Frame")
		icon.BackgroundTransparency = 1
		icon.Size = UDim2.fromScale(0.7, 0.7)
		icon.Position = UDim2.fromScale(0.15, 0.15)
		icon.Rotation = f.rot * 45
		icon.Parent = gui
		ItemIcon.draw(icon, f.item :: string)
	end
	gui.Parent = p
	m.Parent = folder
	f.model = m
end

-- Nearest item frame along a ray (studs), within maxStuds: key, distance in studs.
function DecorClient.raycast(origin: Vector3, dir: Vector3, maxStuds: number): (string?, number)
	local o = origin / BS
	local d = dir.Unit
	local best, bestKey = maxStuds / BS, nil
	for k, f in frames do
		local n = FACE_DIR[f.facing]
		local c = Vector3.new(f.x, f.y, f.z) + Vector3.one * 0.5 - n * (0.5 - 1 / 32)
		local half = Vector3.new(
			if math.abs(n.X) > 0.5 then 1 / 32 else 6 / 16,
			if math.abs(n.Y) > 0.5 then 1 / 32 else 6 / 16,
			if math.abs(n.Z) > 0.5 then 1 / 32 else 6 / 16
		)
		local lo, hi = c - half, c + half
		local tmin, tmax = -math.huge, math.huge
		local ok = true
		for _, axis in { "X", "Y", "Z" } do
			local ov, dv = (o :: any)[axis], (d :: any)[axis]
			local l, h = (lo :: any)[axis], (hi :: any)[axis]
			if math.abs(dv) < 1e-9 then
				if ov < l or ov > h then
					ok = false
					break
				end
			else
				local t1, t2 = (l - ov) / dv, (h - ov) / dv
				if t1 > t2 then
					t1, t2 = t2, t1
				end
				tmin = math.max(tmin, t1)
				tmax = math.min(tmax, t2)
				if tmin > tmax then
					ok = false
					break
				end
			end
		end
		if ok and tmax >= 0 and tmin < best then
			best = math.max(tmin, 0)
			bestKey = k
		end
	end
	return bestKey, best * BS
end

function DecorClient.useFrame(k: string)
	Remotes.get("Decor"):FireServer({ type = "frameUse", key = k })
end

function DecorClient.hitFrame(k: string)
	Remotes.get("Decor"):FireServer({ type = "frameHit", key = k })
end

function DecorClient.placeFrame(x: number, y: number, z: number, nx: number, ny: number, nz: number)
	Remotes.get("Decor"):FireServer({ type = "framePlace", x = x, y = y, z = z, nx = nx, ny = ny, nz = nz })
end

-- Sign editor ----------------------------------------------------------------------------------

local editor: ScreenGui
local boxes: { TextBox } = {}
local editTarget: { x: number, y: number, z: number, side: string }? = nil

local function closeEditor(send: boolean)
	local t = editTarget
	if send and t then
		local lines = {}
		for i, b in boxes do
			lines[i] = string.sub(b.Text, 1, 64)
		end
		Remotes.get("Decor"):FireServer({ type = "signEdit", x = t.x, y = t.y, z = t.z, side = t.side, lines = lines })
	end
	editTarget = nil
	editor.Enabled = false
	DecorClient.editing = false
	InventoryClient.uiOpen = false
	CameraController.mouseUnlocked = false
	for _, b in boxes do
		b:ReleaseFocus()
	end
end

function DecorClient.openEditor(x: number, y: number, z: number, side: string)
	if InventoryClient.uiOpen then
		return
	end
	editTarget = { x = x, y = y, z = z, side = side }
	local cur = signs[key(x, y, z)]
	local lines = if cur then (if side == "back" then cur.back else cur.front) else nil
	for i, b in boxes do
		b.Text = if lines then lines[i] or "" else ""
	end
	editor.Enabled = true
	DecorClient.editing = true
	InventoryClient.uiOpen = true
	CameraController.mouseUnlocked = true
	if not UserInputService.TouchEnabled then
		boxes[1]:CaptureFocus()
	end
end

-- Right-click on a sign: edit the side the player stands in front of.
function DecorClient.editSign(x: number, y: number, z: number, id: number, eye: Vector3)
	local n = DecorClient.signNormal(id)
	local c = (Vector3.new(x, y, z) + Vector3.one * 0.5) * BS
	local side = if (eye - c):Dot(n) >= 0 then "front" else "back"
	DecorClient.openEditor(x, y, z, side)
end

local function makeEditor()
	editor = Instance.new("ScreenGui")
	editor.Name = "SignEditor"
	editor.ResetOnSpawn = false
	editor.Enabled = false
	editor.IgnoreGuiInset = true
	editor.DisplayOrder = 20
	local dim = Instance.new("Frame")
	dim.Size = UDim2.fromScale(1, 1)
	dim.BackgroundColor3 = Color3.new(0, 0, 0)
	dim.BackgroundTransparency = 0.5
	dim.BorderSizePixel = 0
	dim.Parent = editor
	local board = Instance.new("Frame")
	board.AnchorPoint = Vector2.new(0.5, 0.5)
	board.Position = UDim2.fromScale(0.5, 0.42)
	board.Size = UDim2.fromOffset(360, 190)
	board.BackgroundColor3 = Color3.fromRGB(176, 140, 86)
	board.BorderSizePixel = 0
	board.Parent = editor
	local scale = Instance.new("UIScale")
	scale.Parent = board
	local function rescale()
		local cam = workspace.CurrentCamera
		local w = if cam then cam.ViewportSize.X else 800
		scale.Scale = math.clamp(w / 900, 0.6, 1.4)
	end
	rescale()
	if workspace.CurrentCamera then
		workspace.CurrentCamera:GetPropertyChangedSignal("ViewportSize"):Connect(rescale)
	end
	for i = 1, 4 do
		local b = Instance.new("TextBox")
		b.Size = UDim2.new(1, -20, 0, 38)
		b.Position = UDim2.fromOffset(10, 8 + (i - 1) * 44)
		b.BackgroundColor3 = Color3.fromRGB(196, 160, 104)
		b.BorderSizePixel = 0
		b.Font = Enum.Font.Arcade
		b.TextSize = 26
		b.TextColor3 = Color3.fromRGB(20, 16, 12)
		b.ClearTextOnFocus = false
		b.Text = ""
		b.PlaceholderText = ""
		b:GetPropertyChangedSignal("Text"):Connect(function()
			local t = string.gsub(b.Text, "[%c]", "")
			if utf8.len(t) and (utf8.len(t) :: number) > MAX_LINE then
				t = string.sub(t, 1, (utf8.offset(t, MAX_LINE + 1) :: number) - 1)
			end
			if t ~= b.Text then
				b.Text = t
			end
		end)
		b.FocusLost:Connect(function(enter)
			if enter and editTarget then
				local nextBox = boxes[i + 1]
				if nextBox then
					nextBox:CaptureFocus()
				else
					closeEditor(true)
				end
			end
		end)
		b.Parent = board
		boxes[i] = b
	end
	local done = Instance.new("TextButton")
	done.AnchorPoint = Vector2.new(0.5, 0)
	done.Position = UDim2.new(0.5, 0, 1, 12)
	done.Size = UDim2.fromOffset(160, 40)
	done.BackgroundColor3 = Color3.fromRGB(70, 70, 76)
	done.BorderSizePixel = 0
	done.Font = Enum.Font.GothamBold
	done.TextSize = 20
	done.TextColor3 = Color3.new(1, 1, 1)
	done.Text = "Done"
	done.Parent = board
	done.Activated:Connect(function()
		closeEditor(true)
	end)
	UserInputService.InputBegan:Connect(function(input)
		if input.KeyCode == Enum.KeyCode.Escape and editTarget then
			closeEditor(true) -- Java keeps what you typed when you press Escape
		end
	end)
	editor.Parent = Players.LocalPlayer:WaitForChild("PlayerGui")
end

function DecorClient.init()
	local f = Instance.new("Folder")
	f.Name = "ItemFrames"
	f.Parent = workspace
	folder = f
	makeEditor()
	TorchRenderer.signText = DecorClient.signText
	DecorClient.signChanged.Event:Connect(function(x: number, y: number, z: number)
		TorchRenderer.refreshSign(x, y, z, ClientWorld.getBlock(x, y, z))
	end)
	Remotes.get("Decor").OnClientEvent:Connect(function(m: any)
		if typeof(m) ~= "table" then
			return
		end
		if m.type == "sign" and typeof(m.x) == "number" then
			local function lines(t: any): { string }
				local out = { "", "", "", "" }
				if typeof(t) == "table" then
					for i = 1, 4 do
						out[i] = if typeof(t[i]) == "string" then t[i] else ""
					end
				end
				return out
			end
			signs[key(m.x, m.y, m.z)] = { front = lines(m.front), back = lines(m.back) }
			DecorClient.signChanged:Fire(m.x, m.y, m.z)
		elseif m.type == "signRemove" and typeof(m.x) == "number" then
			signs[key(m.x, m.y, m.z)] = nil
		elseif m.type == "signEditor" and typeof(m.x) == "number" then
			DecorClient.openEditor(m.x, m.y, m.z, if m.side == "back" then "back" else "front")
		elseif m.type == "frame" and typeof(m.key) == "string" and FACE_DIR[m.facing] then
			local fr = frames[m.key] or { key = m.key, x = m.x, y = m.y, z = m.z, facing = m.facing, rot = 0 }
			fr.rot = if typeof(m.rot) == "number" then m.rot else 0
			fr.item = if typeof(m.item) == "string" then m.item else nil
			frames[m.key] = fr
			buildFrame(fr)
		elseif m.type == "frameRemove" and typeof(m.key) == "string" then
			local fr = frames[m.key]
			if fr then
				if fr.model then
					(fr.model :: Model):Destroy()
				end
				frames[m.key] = nil
			end
		end
	end)
end

return DecorClient
