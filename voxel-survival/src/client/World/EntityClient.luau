--!strict
-- Client side of falling blocks and primed TNT (server: Simulation/EntityService).
-- A spawn event starts a textured cube that moves with the same Java physics as the server
-- (gravity 0.04, drag 0.98, collisions; TNT bounces softly and flashes white every 0.25 s);
-- the remove event ends it. Also plays the lava/water "fizz" puff.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared.Config)
local Remotes = require(Shared.Net.Remotes)
local BlockRegistry = require(Shared.Blocks.BlockRegistry)
local MobPhysics = require(Shared.Mobs.MobPhysics)
local TextureAtlas = require(script.Parent.Parent.Render.TextureAtlas)

local BS = Config.BLOCK_SIZE
local EntityClient = {}
EntityClient.events = Instance.new("BindableEvent") -- ("spawn" | "remove" | "fizz", kind, pos)

type E = { part: Part, kind: string, x: number, y: number, z: number, vx: number, vy: number, vz: number, acc: number, age: number, flash: Part? }
local entities: { [number]: E } = {}
local folder: Folder
local getBlock: ((number, number, number) -> number?)? = nil

local function solid(x: number, y: number, z: number): boolean
	local gb = getBlock
	local id = gb and gb(x, y, z)
	return id == nil or BlockRegistry.isSolid[id + 1]
end

local function texturedCube(block: number): Part
	local p = Instance.new("Part")
	p.Anchored = true
	p.CanCollide = false
	p.CanQuery = false
	p.CanTouch = false
	p.CastShadow = false
	p.Size = Vector3.one * BS * 0.98
	p.Color = Color3.new(1, 1, 1)
	local def = BlockRegistry.byId[block]
	for _, face in Enum.NormalId:GetEnumItems() do
		if def and TextureAtlas.content then
			local dir = if face == Enum.NormalId.Top then BlockRegistry.Dir.TOP
				elseif face == Enum.NormalId.Bottom then BlockRegistry.Dir.BOTTOM
				else BlockRegistry.Dir.EAST
			local offset, size = TextureAtlas.pixelRect(def.faceTexture[dir])
			local gui = Instance.new("SurfaceGui")
			gui.Face = face
			gui.CanvasSize = Vector2.new(64, 64)
			gui.LightInfluence = 1
			local img = Instance.new("ImageLabel")
			img.Size = UDim2.fromScale(1, 1)
			img.BackgroundTransparency = 1
			img.ResampleMode = Enum.ResamplerMode.Pixelated
			img.ImageRectOffset = offset
			img.ImageRectSize = size
			pcall(function()
				(img :: any).ImageContent = TextureAtlas.content
			end)
			img.Parent = gui
			gui.Parent = p
		end
	end
	return p
end

local function onEvent(e: any)
	if typeof(e) ~= "table" then
		return
	end
	if e.type == "spawn" and typeof(e.id) == "number" and typeof(e.pos) == "Vector3" then
		local old = entities[e.id]
		if old then
			old.part:Destroy()
		end
		local part = texturedCube(tonumber(e.block) or 0)
		local flash: Part? = nil
		if e.kind == "tnt" then
			local f = Instance.new("Part")
			f.Anchored = true
			f.CanCollide = false
			f.CanQuery = false
			f.CanTouch = false
			f.CastShadow = false
			f.Material = Enum.Material.Neon
			f.Color = Color3.new(1, 1, 1)
			f.Size = Vector3.one * BS
			f.Transparency = 1
			f.Parent = folder
			flash = f
		end
		part.Parent = folder
		local vel = if typeof(e.vel) == "Vector3" then e.vel else Vector3.zero
		entities[e.id] = { part = part, kind = e.kind, x = e.pos.X, y = e.pos.Y, z = e.pos.Z,
			vx = vel.X, vy = vel.Y, vz = vel.Z, acc = 0, age = 0, flash = flash }
		EntityClient.events:Fire("spawn", e.kind, e.pos * BS)
	elseif e.type == "remove" and typeof(e.id) == "number" then
		local ent = entities[e.id]
		if ent then
			ent.part:Destroy()
			if ent.flash then
				(ent.flash :: Part):Destroy()
			end
			entities[e.id] = nil
			EntityClient.events:Fire("remove", ent.kind, Vector3.new(ent.x, ent.y, ent.z) * BS)
		end
	elseif e.type == "fizz" and typeof(e.pos) == "Vector3" then
		-- a short puff of steam where lava met water
		for _ = 1, 6 do
			local puff = Instance.new("Part")
			puff.Anchored = true
			puff.CanCollide = false
			puff.CanQuery = false
			puff.CanTouch = false
			puff.CastShadow = false
			puff.Color = Color3.fromRGB(220, 220, 224)
			puff.Size = Vector3.one * BS * 0.2
			puff.Transparency = 0.3
			puff.CFrame = CFrame.new(e.pos + Vector3.new((math.random() - 0.5) * BS, 0, (math.random() - 0.5) * BS))
			puff.Parent = folder
			TweenService:Create(puff, TweenInfo.new(1), { CFrame = puff.CFrame + Vector3.new(0, BS, 0), Transparency = 1 }):Play()
			task.delay(1, function()
				puff:Destroy()
			end)
		end
		EntityClient.events:Fire("fizz", "fizz", e.pos)
	end
end

function EntityClient.init(blockAt: (number, number, number) -> number?)
	getBlock = blockAt
	local f = Instance.new("Folder")
	f.Name = "FallingEntities"
	f.Parent = workspace
	folder = f
	Remotes.get("EntityEvent").OnClientEvent:Connect(onEvent)
	RunService.Heartbeat:Connect(function(dt)
		for _, e in entities do
			e.acc += dt
			while e.acc >= 0.05 do
				e.acc -= 0.05
				e.age += 1
				e.vy -= 0.04
				local nx, ny, nz, rvx, rvy, rvz, onGround = MobPhysics.move(solid, e.x, e.y, e.z, e.vx * 20, e.vy * 20, e.vz * 20, 0.98, 0.98, 0.05)
				e.x, e.y, e.z = nx, ny, nz
				e.vx, e.vy, e.vz = rvx / 20 * 0.98, rvy / 20 * 0.98, rvz / 20 * 0.98
				if onGround and e.kind == "tnt" then
					e.vx *= 0.7
					e.vz *= 0.7
					e.vy *= -0.5
				end
			end
			local cf = CFrame.new(Vector3.new(e.x, e.y + 0.49, e.z) * BS)
			e.part.CFrame = cf
			local fl = e.flash
			if fl then
				fl.CFrame = cf
				fl.Transparency = if (e.age // 5) % 2 == 0 then 0.6 else 1
			end
		end
	end)
end

return EntityClient
