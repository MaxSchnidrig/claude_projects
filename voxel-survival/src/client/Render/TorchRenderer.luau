--!strict
-- Small models for blocks that aren't cubes (our own designs):
--   torch / wall torch  a thin wooden stick with a glowing tip; wall torches lean away from their
--                       wall and sit against it
--   fire                crossed sheets of flickering flame
--   campfire            four logs in a square with embers; flames and rising smoke when lit,
--                       and up to 4 cooking items on top (CampfireState) Their light on blocks comes from the light engine (baked into the terrain
-- mesh); the nearest Config.TORCH_POINT_LIGHTS torches also carry a Roblox PointLight so they
-- light mobs, players and items, and still glow at night.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared.Config)
local BlockRegistry = require(Shared.Blocks.BlockRegistry)
local TorchRules = require(Shared.Blocks.TorchRules)
local ItemRegistry = require(Shared.Items.ItemRegistry)
local TweenService = game:GetService("TweenService")

local BS = Config.BLOCK_SIZE
local CS = Config.CHUNK_SIZE
local TorchRenderer = {}
TorchRenderer.count = 0

type Torch = { model: Model, light: PointLight?, pos: Vector3, cx: number, cz: number, kind: string, flames: { BasePart }, lit: boolean }
local torches: { [string]: Torch } = {}
local refreshLights: () -> () = function() end
local folder: Folder? = nil

local function key(x: number, y: number, z: number): string
	return `{x},{y},{z}`
end

local function plain(size: Vector3, color: Color3, material: Enum.Material?): Part
	local p = Instance.new("Part")
	p.Anchored = true
	p.CanCollide = false
	p.CanQuery = false
	p.CanTouch = false
	p.CastShadow = false
	p.Material = material or Enum.Material.SmoothPlastic
	p.Color = color
	p.Size = size
	return p
end

local function pointLight(parent: Instance, range: number): PointLight
	local light = Instance.new("PointLight")
	light.Color = Color3.fromRGB(255, 196, 120)
	light.Range = range
	light.Brightness = 1.2
	light.Shadows = false
	light.Enabled = false
	light.Parent = parent
	return light
end

local function buildFire(x: number, y: number, z: number): Torch
	local model = Instance.new("Model")
	model.Name = "Fire"
	local base = Vector3.new(x + 0.5, y, z + 0.5) * BS
	local flames = {}
	for i = 0, 3 do
		local f = plain(Vector3.new(BS * 0.9, BS * 0.8, 0.05), if i % 2 == 0 then Color3.fromRGB(255, 150, 40) else Color3.fromRGB(255, 210, 90), Enum.Material.Neon)
		f.Transparency = 0.25
		f.CFrame = CFrame.new(base + Vector3.new(0, BS * 0.4, 0)) * CFrame.Angles(0, math.rad(i * 45), 0)
		f.Parent = model
		table.insert(flames, f)
	end
	local light = pointLight(flames[1], 15 * BS * 0.6)
	model.Parent = folder
	return { model = model, light = light, pos = base + Vector3.new(0, BS * 0.4, 0), cx = x // CS, cz = z // CS, kind = "fire", flames = flames, lit = true }
end

local function buildCampfire(x: number, y: number, z: number, lit: boolean): Torch
	local model = Instance.new("Model")
	model.Name = "Campfire"
	local base = Vector3.new(x + 0.5, y, z + 0.5) * BS
	local logColor = Color3.fromRGB(104, 76, 44)
	-- four logs in a square, two layers
	for i = 0, 3 do
		local along = i % 2 == 0
		local off = (if i < 2 then -1 else 1) * BS * 0.28
		local h = if along then 0.12 else 0.3
		local log = plain(if along then Vector3.new(BS * 0.95, BS * 0.2, BS * 0.2) else Vector3.new(BS * 0.2, BS * 0.2, BS * 0.95), logColor)
		log.CFrame = CFrame.new(base + (if along then Vector3.new(0, BS * h, off) else Vector3.new(off, BS * h, 0)))
		log.Parent = model
	end
	local embers = plain(Vector3.new(BS * 0.5, BS * 0.05, BS * 0.5), if lit then Color3.fromRGB(230, 100, 30) else Color3.fromRGB(50, 44, 40), if lit then Enum.Material.Neon else nil)
	embers.CFrame = CFrame.new(base + Vector3.new(0, BS * 0.06, 0))
	embers.Parent = model
	local flames = {}
	local light: PointLight? = nil
	if lit then
		for i = 0, 1 do
			local f = plain(Vector3.new(BS * 0.55, BS * 0.6, 0.05), Color3.fromRGB(255, 170, 60), Enum.Material.Neon)
			f.Transparency = 0.2
			f.CFrame = CFrame.new(base + Vector3.new(0, BS * 0.55, 0)) * CFrame.Angles(0, math.rad(45 + i * 90), 0)
			f.Parent = model
			table.insert(flames, f)
		end
		light = pointLight(flames[1], 15 * BS * 0.6)
	end
	model.Parent = folder
	return { model = model, light = light, pos = base + Vector3.new(0, BS * 0.5, 0), cx = x // CS, cz = z // CS, kind = "campfire", flames = flames, lit = lit }
end

local function build(x: number, y: number, z: number, id: number): Torch
	local def = BlockRegistry.byId[id]
	if def and def.shape == "fire" then
		return buildFire(x, y, z)
	elseif def and def.shape == "campfire" then
		return buildCampfire(x, y, z, def.light > 0)
	end
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
	local light = pointLight(tip, 14 * BS * 0.6)
	model.Parent = folder
	return { model = model, light = light, pos = tip.Position, cx = x // CS, cz = z // CS, kind = "torch", flames = {}, lit = true }
end

-- Does this block id get a model here (anything that isn't a plain cube)?
function TorchRenderer.hasModel(id: number?): boolean
	local def = id and BlockRegistry.byId[id]
	return def ~= nil and def.shape ~= "cube"
end

-- Items cooking on a campfire (CampfireState): small cubes in the item's colour on top.
local cooking: { [string]: Model } = {}
function TorchRenderer.setCooking(x: number, y: number, z: number, items: { any })
	local k = key(x, y, z)
	local old = cooking[k]
	if old then
		old:Destroy()
		cooking[k] = nil
	end
	local m = Instance.new("Model")
	m.Name = "Cooking"
	local any = false
	for i, item in items do
		if typeof(item) == "string" then
			local def = ItemRegistry.get(item)
			local c = def and def.color or { 200, 120, 100 }
			local p = plain(Vector3.new(BS * 0.22, BS * 0.08, BS * 0.22), Color3.fromRGB(c[1], c[2], c[3]))
			local ox = if i == 1 or i == 4 then -0.22 else 0.22
			local oz = if i <= 2 then -0.22 else 0.22
			p.CFrame = CFrame.new((Vector3.new(x + 0.5 + ox, y + 0.47, z + 0.5 + oz)) * BS)
			p.Parent = m
			any = true
		end
	end
	if any then
		m.Parent = folder
		cooking[k] = m
	else
		m:Destroy()
	end
end

-- A block changed: show / hide a model there.
function TorchRenderer.set(x: number, y: number, z: number, id: number)
	local k = key(x, y, z)
	local old = torches[k]
	if old then
		old.model:Destroy()
		torches[k] = nil
		TorchRenderer.count -= 1
	end
	if TorchRenderer.hasModel(id) then
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
			local l = e.t.light
			if l then
				l.Enabled = i <= Config.TORCH_POINT_LIGHTS
			end
		end
	end
	local acc, flick, smoke = 0, 0, 0
	RunService.Heartbeat:Connect(function(dt)
		acc += dt
		if acc >= 0.5 then
			acc = 0
			refreshLights()
		end
		-- flame flicker and campfire smoke (cosmetic)
		flick += dt
		smoke += dt
		if flick >= 0.08 then
			flick = 0
			for _, t in torches do
				for _, f in t.flames do
					f.Transparency = 0.15 + math.random() * 0.25
				end
			end
		end
		if smoke >= 0.35 then
			smoke = 0
			local cam = workspace.CurrentCamera
			for _, t in torches do
				if t.kind == "campfire" and t.lit and cam and (cam.CFrame.Position - t.pos).Magnitude < 64 * BS then
					local puff = plain(Vector3.one * BS * 0.25, Color3.fromRGB(120, 120, 124))
					puff.Transparency = 0.3
					puff.CFrame = CFrame.new(t.pos + Vector3.new((math.random() - 0.5) * BS * 0.3, 0, (math.random() - 0.5) * BS * 0.3))
					puff.Parent = folder
					TweenService:Create(puff, TweenInfo.new(3, Enum.EasingStyle.Linear), {
						CFrame = puff.CFrame + Vector3.new(0, BS * 4, 0),
						Size = Vector3.one * BS * 0.6,
						Transparency = 1,
					}):Play()
					task.delay(3, function()
						puff:Destroy()
					end)
				end
			end
		end
	end)
	game:GetService("ReplicatedStorage"):WaitForChild("Remotes")
	require(Shared.Net.Remotes).get("CampfireState").OnClientEvent:Connect(function(x: any, y: any, z: any, items: any)
		if typeof(x) == "number" and typeof(y) == "number" and typeof(z) == "number" and typeof(items) == "table" then
			TorchRenderer.setCooking(x, y, z, items)
		end
	end)
end

return TorchRenderer
