--!strict
-- Developer overlay with live performance numbers.
--   F3  toggle overlay                     (Config.DEBUG_KEY_OVERLAY)
--   F4  switch render backend (editable <-> parts) and rebuild everything, for A/B comparison
--       (Config.DEBUG_KEY_BACKEND)
-- Pair it with the MicroProfiler (Ctrl+F6) and View > Stats in Studio.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared.Config)
local GameInfo = require(Shared.GameInfo)
local Biomes = require(Shared.World.Biomes)
local ClientWorld = require(script.Parent.Parent.World.ClientWorld)
local ChunkRenderer = require(script.Parent.Parent.Render.ChunkRenderer)
local EditableMeshBackend = require(script.Parent.Parent.Render.EditableMeshBackend)
local PartsBackend = require(script.Parent.Parent.Render.PartsBackend)
local CollisionBuilder = require(script.Parent.Parent.Render.CollisionBuilder)

local BS = Config.BLOCK_SIZE

local DebugOverlay = {}

function DebugOverlay.init()
	local gui = Instance.new("ScreenGui")
	gui.Name = "DebugOverlay"
	gui.ResetOnSpawn = false
	gui.IgnoreGuiInset = true
	gui.DisplayOrder = 100

	local label = Instance.new("TextLabel")
	label.BackgroundColor3 = Color3.fromRGB(10, 14, 22)
	label.BackgroundTransparency = 0.35
	label.TextColor3 = Color3.fromRGB(220, 235, 255)
	label.Font = Enum.Font.Code
	label.TextSize = 14
	label.TextXAlignment = Enum.TextXAlignment.Left
	label.TextYAlignment = Enum.TextYAlignment.Top
	label.AutomaticSize = Enum.AutomaticSize.XY
	label.Position = UDim2.fromOffset(8, 48)
	label.Text = ""
	local pad = Instance.new("UIPadding")
	pad.PaddingLeft = UDim.new(0, 6)
	pad.PaddingRight = UDim.new(0, 6)
	pad.PaddingTop = UDim.new(0, 4)
	pad.PaddingBottom = UDim.new(0, 4)
	pad.Parent = label
	label.Parent = gui
	gui.Parent = Players.LocalPlayer:WaitForChild("PlayerGui")

	UserInputService.InputBegan:Connect(function(input, processed)
		if processed then
			return
		end
		if input.KeyCode == (Enum.KeyCode :: any)[Config.DEBUG_KEY_OVERLAY] then
			gui.Enabled = not gui.Enabled
		elseif input.KeyCode == (Enum.KeyCode :: any)[Config.DEBUG_KEY_BACKEND] then
			local nextBackend = if ChunkRenderer.backend == "editable" then "parts" else "editable"
			ChunkRenderer.setBackend(nextBackend)
			ClientWorld.remeshAll()
		end
	end)

	local frames, fpsTime, fps = 0, 0, 0
	local acc = 0
	RunService.RenderStepped:Connect(function(dt)
		frames += 1
		fpsTime += dt
		if fpsTime >= 1 then
			fps = frames / fpsTime
			frames, fpsTime = 0, 0
		end
		acc += dt
		if acc < 0.25 or not gui.Enabled then
			return
		end
		acc = 0

		local character = Players.LocalPlayer.Character
		local root = character and character:FindFirstChild("HumanoidRootPart") :: BasePart?
		local posText, biomeText = "-", "-"
		if root then
			local p = root.Position / BS
			local bx, by, bz = math.floor(p.X), math.floor(p.Y), math.floor(p.Z)
			posText = `{bx} {by} {bz}  chunk {bx // 16} {bz // 16}`
			local b = ClientWorld.biomeAt(bx, bz)
			biomeText = if b and Biomes.byId[b] then Biomes.byId[b].name else "?"
		end

		local ws = ClientWorld.stats
		local rs = ChunkRenderer.stats
		local es = EditableMeshBackend.stats
		local sched = (ClientWorld :: any).scheduler
		local genAvg = if ws.generated > 0 then ws.genTime / ws.generated * 1000 else 0
		local meshAvg = if rs.sectionsMeshed > 0 then rs.meshTime / rs.sectionsMeshed * 1000 else 0
		local backend = ChunkRenderer.backend .. if ChunkRenderer.editableDisabled then " (EditableMesh failed -> parts)" else ""

		label.Text = table.concat({
			`{GameInfo.TITLE} {GameInfo.VERSION}   {string.format("%.0f", fps)} fps   [F3 hide, F4 switch backend]`,
			`pos {posText}   biome {biomeText}`,
			`render distance {ClientWorld.getRenderDistance()}{if ClientWorld.isMobile() then " (mobile)" else ""}   backend {backend}`,
			`chunks loaded {ws.loaded}   waiting: gen {ws.pendingGen}, mesh {ws.pendingMesh} sections`,
			string.format("gen %.2f ms/chunk avg (%d)   mesh %.2f ms/section avg (%d)", genAvg, ws.generated, meshAvg, rs.sectionsMeshed),
			string.format("scheduler last step %.2f ms", if sched then sched.stats.lastStepTime * 1000 else 0),
			`MeshParts {es.meshParts}   triangles {es.triangles}   uploads {es.uploadsInFlight} in flight / {es.uploadsQueued} queued`,
			`render Parts {PartsBackend.stats.parts}   collision Parts {CollisionBuilder.stats.parts}   fallbacks {rs.fallbacks}`,
			if es.lastError ~= "" then `last EditableMesh error: {es.lastError}` else "",
		}, "\n")
	end)
end

return DebugOverlay
