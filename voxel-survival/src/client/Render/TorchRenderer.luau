--!strict
-- Torch models: a thin wooden stick with a glowing tip; wall torches lean away from their wall
-- and sit against it. Their light on blocks comes from the light engine (baked into the terrain
-- mesh); the nearest Config.TORCH_POINT_LIGHTS torches also carry a Roblox PointLight so they
-- light mobs, players and items, and still glow at night.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared.Config)
local BlockRegistry = require(Shared.Blocks.BlockRegistry)
local TorchRules = require(Shared.Blocks.TorchRules)

local BS = Config.BLOCK_SIZE
local CS = Config.CHUNK_SIZE
local TorchRenderer = {}
TorchRenderer.count = 0

type Torch = { model: Model, light: PointLight, pos: Vector3, cx: number, cz: number }
local torches: { [string]: Torch } = {}
local refreshLights: () -> () = function() end
local folder: Folder? = nil

local function key(x: number, y: number, z: number): string
	return `{x},{y},{z}`
end

local function build(x: number, y: number, z: number, id: number): Torch
	local def = BlockRegistry.byId[id]
	local base = Vector3.new(x + 0.5, y, z + 0.5) * BS
	local tilt = CFrame.identity
	local offset = Vector3.zero
	if def and def.shape == "wall_torch" then
		-- lean 22.5 degrees away from the wall, foot against it
		local f = def.facing
		local away = if f == "east" then Vector3.xAxis elseif f == "west" then -Vector3.xAxis
			elseif f == "south" then Vector3.zAxis else -Vector3.zAxis
		offset = -away * (BS * 0.35) + Vector3.new(0, BS * 0.2, 0)
		local axis = Vector3.yAxis:Cross(away)
		tilt = CFrame.fromAxisAngle(axis, math.rad(22.5))
	end
	local stickLen = BS * 10 / 16
	local thick = BS * 2 / 16
	local root = CFrame.new(base + offset) * tilt
	local model = Instance.new("Model")
	model.Name = "Torch"
	local stick = Instance.new("Part")
	stick.Anchored = true
	stick.CanCollide = false
	stick.CanQuery = false
	stick.CanTouch = false
	stick.CastShadow = false
	stick.Material = Enum.Material.SmoothPlastic
	stick.Color = Color3.fromRGB(116, 82, 44)
	stick.Size = Vector3.new(thick, stickLen, thick)
	stick.CFrame = root * CFrame.new(0, stickLen / 2, 0)
	stick.Parent = model
	local tip = Instance.new("Part")
	tip.Anchored = true
	tip.CanCollide = false
	tip.CanQuery = false
	tip.CanTouch = false
	tip.CastShadow = false
	tip.Material = Enum.Material.Neon
	tip.Color = Color3.fromRGB(255, 200, 90)
	tip.Size = Vector3.new(thick * 1.1, thick * 1.4, thick * 1.1)
	tip.CFrame = root * CFrame.new(0, stickLen + thick * 0.5, 0)
	tip.Parent = model
	local light = Instance.new("PointLight")
	light.Color = Color3.fromRGB(255, 196, 120)
	light.Range = 14 * BS * 0.6
	light.Brightness = 1.2
	light.Shadows = false
	light.Enabled = false
	light.Parent = tip
	model.Parent = folder
	return { model = model, light = light, pos = tip.Position, cx = x // CS, cz = z // CS }
end

-- A block changed: show / hide a torch model there.
function TorchRenderer.set(x: number, y: number, z: number, id: number)
	local k = key(x, y, z)
	local old = torches[k]
	if old then
		old.model:Destroy()
		torches[k] = nil
		TorchRenderer.count -= 1
	end
	if TorchRules.isTorch(id) then
		torches[k] = build(x, y, z, id)
		TorchRenderer.count += 1
		refreshLights() -- light the new torch now, not at the next periodic check
	end
end

-- A chunk was unloaded.
function TorchRenderer.clearChunk(cx: number, cz: number)
	for k, t in torches do
		if t.cx == cx and t.cz == cz then
			t.model:Destroy()
			torches[k] = nil
			TorchRenderer.count -= 1
		end
	end
end

function TorchRenderer.init()
	local f = Instance.new("Folder")
	f.Name = "Torches"
	f.Parent = workspace
	folder = f
	-- only the nearest torches carry a PointLight
	refreshLights = function()
		local cam = workspace.CurrentCamera
		if not cam then
			return
		end
		local list = {}
		for _, t in torches do
			table.insert(list, { t = t, d = (t.pos - cam.CFrame.Position).Magnitude })
		end
		table.sort(list, function(a, b)
			return a.d < b.d
		end)
		for i, e in list do
			e.t.light.Enabled = i <= Config.TORCH_POINT_LIGHTS
		end
	end
	local acc = 0
	RunService.Heartbeat:Connect(function(dt)
		acc += dt
		if acc >= 0.5 then
			acc = 0
			refreshLights()
		end
	end)
end

return TorchRenderer
