--!strict
-- Blocky clouds: a flat layer of white 12 x 12-block cells, 4 blocks thick, at Config.CLOUD_Y,
-- drifting slowly west. The pattern is our own hash noise (seeded by the world seed). Rows of
-- touching cells are merged into one Part each, rebuilt only when the camera crosses a cell.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared.Config)
local Hash = require(Shared.Util.Hash)

local BS = Config.BLOCK_SIZE
local CELL = 12 -- blocks
local THICK = 4 -- blocks
local RADIUS = 12 -- cells around the camera
local DRIFT = 0.6 -- blocks per second

local Clouds = {}

function Clouds.init()
	local seed = (ReplicatedStorage:GetAttribute("WorldSeed") :: number?) or 1
	local folder = Instance.new("Folder")
	folder.Name = "Clouds"
	folder.Parent = workspace
	local layer = Instance.new("Model")
	layer.Name = "Layer"
	layer.Parent = folder
	local pivot = Instance.new("Part")
	pivot.Anchored = true
	pivot.CanCollide = false
	pivot.CanQuery = false
	pivot.CanTouch = false
	pivot.Transparency = 1
	pivot.Size = Vector3.one
	pivot.Parent = layer
	layer.PrimaryPart = pivot

	local function cloudy(cx: number, cz: number): boolean
		-- two octaves of our hash noise, thresholded
		local a = Hash.hash3f(seed, cx // 3, 0, cz // 3)
		local b = Hash.hash3f(seed + 7, cx, 1, cz)
		return a * 0.65 + b * 0.35 > 0.62
	end

	local builtAt: Vector2? = nil
	local parts: { Part } = {}
	local function rebuild(ccx: number, ccz: number)
		for _, p in parts do
			p:Destroy()
		end
		table.clear(parts)
		for dz = -RADIUS, RADIUS do
			local cz = ccz + dz
			local run = 0
			local startX = 0
			for dx = -RADIUS, RADIUS + 1 do
				local cx = ccx + dx
				local on = dx <= RADIUS and cloudy(cx, cz)
				if on then
					if run == 0 then
						startX = cx
					end
					run += 1
				elseif run > 0 then
					local p = Instance.new("Part")
					p.Anchored = true
					p.CanCollide = false
					p.CanQuery = false
					p.CanTouch = false
					p.CastShadow = false
					p.Material = Enum.Material.SmoothPlastic
					p.Color = Color3.fromRGB(250, 250, 252)
					p.Transparency = 0.18
					p.Size = Vector3.new(run * CELL * BS, THICK * BS, CELL * BS)
					p.CFrame = CFrame.new((startX + run / 2) * CELL * BS, (Config.CLOUD_Y + THICK / 2) * BS, (cz + 0.5) * CELL * BS)
					p.Parent = layer
					table.insert(parts, p)
					run = 0
				end
			end
		end
	end

	local start = os.clock()
	RunService.Heartbeat:Connect(function()
		local cam = workspace.CurrentCamera
		if not cam then
			return
		end
		local drift = (os.clock() - start) * DRIFT -- blocks, clouds move towards -X
		local camBlocks = cam.CFrame.Position / BS
		-- in the layer's own frame the camera moves +X as the clouds drift -X
		local lx = camBlocks.X + drift
		local ccx, ccz = math.floor(lx / CELL), math.floor(camBlocks.Z / CELL)
		if not builtAt or (builtAt :: Vector2).X ~= ccx or (builtAt :: Vector2).Y ~= ccz then
			builtAt = Vector2.new(ccx, ccz)
			layer:PivotTo(CFrame.new())
			rebuild(ccx, ccz)
		end
		layer:PivotTo(CFrame.new(-drift * BS, 0, 0))
	end)
end

return Clouds
