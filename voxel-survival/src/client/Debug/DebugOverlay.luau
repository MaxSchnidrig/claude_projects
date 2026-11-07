--!strict
-- Developer overlay with live performance numbers.
--   F3  toggle overlay                     (Config.DEBUG_KEY_OVERLAY)
--   F4  switch render backend (editable <-> parts) and rebuild everything, for A/B comparison
--       (Config.DEBUG_KEY_BACKEND)
-- Pair it with the MicroProfiler (Ctrl+F6) and View > Stats in Studio.

local Players = game:GetService("Players")
local Stats = game:GetService("Stats")
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
local LiveEditPool = require(script.Parent.Parent.Render.LiveEditPool)
local SpecialPartsBackend = require(script.Parent.Parent.Render.SpecialPartsBackend)
local Hotbar = require(script.Parent.Parent.UI.Hotbar)
local SurvivalClient = require(script.Parent.Parent.Survival.SurvivalClient)
local DayNightClient = require(script.Parent.Parent.Survival.DayNightClient)
local Remotes = require(Shared.Net.Remotes)
local BlockInteraction = require(script.Parent.Parent.Interaction.BlockInteraction)
local InventoryClient = require(script.Parent.Parent.Player.InventoryClient)
local CameraController = require(script.Parent.Parent.Player.CameraController)
local BlockRegistry = require(Shared.Blocks.BlockRegistry)
local ItemRegistry = require(Shared.Items.ItemRegistry)
local Mining = require(Shared.Gameplay.Mining)

local BS = Config.BLOCK_SIZE

-- Engine-reported memory for a developer memory tag, or nil if unavailable.
local function tagMb(tagName: string): number?
	local ok, mb = pcall(function()
		return Stats:GetMemoryUsageMbForTag((Enum.DeveloperMemoryTag :: any)[tagName])
	end)
	return if ok then mb else nil
end
local function fmtMb(mb: number?): string
	return if mb then string.format("%.1f MB", mb) else "n/a"
end

local DebugOverlay = {}

local function healthText(): string
	local c = Players.LocalPlayer.Character
	local h = c and c:FindFirstChildOfClass("Humanoid")
	return if h then string.format("%d/%d", math.ceil(h.Health), h.MaxHealth) else "-"
end

local function yes(b: boolean): string
	return if b then "yes" else "NO"
end

-- Hotbar diagnostics (startup steps, where the GUI is, whether it's on screen).
local function hotbarLines(): string
	local st = Hotbar.status
	return table.concat({
		`hotbar steps: {table.concat(st.steps, " > ")}`,
		string.format("hotbar: in PlayerGui %s (parent %s), enabled %s, visible %s, on screen %s at %d,%d size %dx%d (screen %dx%d)",
			yes(st.parented), st.parentName, yes(st.enabled), yes(st.visible), yes(st.onScreen),
			st.absPos.X, st.absPos.Y, st.absSize.X, st.absSize.Y, st.viewport.X, st.viewport.Y),
		`inventory: {InventoryClient.syncCount} syncs from server, {InventoryClient.itemCount} items, selected slot {InventoryClient.selected}` ..
			(if st.lastProblem ~= "" then `   last hotbar problem: {st.lastProblem}` else ""),
	}, "\n")
end

-- "target Stone (12 64 -3)  1.15 s with Wooden Pickaxe, drops"
local function targetLine(): string
	local hit = BlockInteraction.target
	local held = InventoryClient.heldItem()
	local heldName = if held and ItemRegistry.get(held) then (ItemRegistry.get(held) :: any).name else "hand"
	if not hit then
		return `target -   holding {heldName}`
	end
	local def = BlockRegistry.get(hit.id)
	local t = Mining.breakSeconds(hit.id, held)
	local tText = if t == math.huge then "unbreakable" else string.format("%.2f s", t)
	local drops = if Mining.canHarvest(hit.id, held) then "drops" else "no drop"
	return `target {if def then def.name else "?"} ({hit.x} {hit.y} {hit.z})   {tText} with {heldName}, {drops}`
end

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
		elseif input.KeyCode == (Enum.KeyCode :: any)[Config.DEBUG_KEY_SKIP_TIME] and RunService:IsStudio() then
			Remotes.get("DebugAction"):FireServer({ type = "skipTime" }) -- server ignores outside Studio
		elseif input.KeyCode == (Enum.KeyCode :: any)[Config.DEBUG_KEY_HURT_SELF] and RunService:IsStudio() then
			Remotes.get("DebugAction"):FireServer({ type = "hurtSelf" })
		elseif input.KeyCode == (Enum.KeyCode :: any)[Config.DEBUG_KEY_KEEP_TEMP] then
			ClientWorld.setKeepTemp(not ChunkRenderer.keepTemp)
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
		local prof = ClientWorld.profile
		local ls = LiveEditPool.stats
		local reasons = {}
		for reason, n in es.failReasons do
			table.insert(reasons, `{n}x {reason}`)
		end
		local genAvg = if ws.generated > 0 then ws.genTime / ws.generated * 1000 else 0
		local meshAvg = if rs.sectionsMeshed > 0 then rs.meshTime / rs.sectionsMeshed * 1000 else 0
		local backend = ChunkRenderer.backend .. if ChunkRenderer.isDegraded() then " (DEGRADED: mostly Parts)" else ""
		local cap = if es.bakeMode == "live"
			then (if es.learnedCap then tostring(es.learnedCap) else "?")
			else tostring(Config.MAX_LIVE_EDITABLE)

		label.Text = table.concat({
			`{GameInfo.TITLE} {GameInfo.VERSION}   {string.format("%.0f", fps)} fps   [F3 hide, F4 backend, F6 keep live edits, J +6h, K hurt (Studio)]`,
			`pos {posText}   biome {biomeText}   camera {CameraController.mode}`,
			targetLine(),
			string.format("survival: health %s  food %d  saturation %.1f  air %.1f s  sprint %s   time %s (tick %d)",
				healthText(), SurvivalClient.food, SurvivalClient.saturation, SurvivalClient.air,
				if SurvivalClient.canSprint then "ok" else "too hungry", DayNightClient.clockText(), DayNightClient.timeOfDay),
			hotbarLines(),
			`render distance {ClientWorld.effectiveRenderDistance()}/{ClientWorld.getRenderDistance()}{if ClientWorld.isMobile() then " (mobile)" else ""}   backend {backend}`,
			`chunks loaded {ws.loaded}   waiting: gen {ws.pendingGen}, mesh {ws.pendingMesh} sections`,
			string.format("gen %.2f ms/chunk avg (%d)   mesh %.2f ms/section avg (%d)", genAvg, ws.generated, meshAvg, rs.sectionsMeshed),
			string.format("our script time/frame: %.2f ms (refresh %.2f, scheduler %.2f, other %.2f)   frame %.1f ms",
				prof.total, prof.refresh, prof.scheduler, prof.other, 1000 / math.max(fps, 1)),
			`EditableMesh mode {es.bakeMode}   live {es.liveEditable}/{cap} (peak {es.peakLiveEditable})   est. {string.format("%.0f", es.liveBytesEst / 1024)} KB   budget hits {es.budgetHits}`,
			`MeshParts {es.meshParts}   triangles {es.triangles}   uploads {es.uploadsInFlight} in flight / {es.uploadsQueued} queued`,
			`sections: {rs.sectionsEditable} mesh, {rs.sectionsParts} parts   fallbacks {rs.fallbacks}   demotions {rs.demotions}`,
			`render Parts {PartsBackend.stats.parts}   water/ice/glass/lava Parts {SpecialPartsBackend.stats.parts} in {SpecialPartsBackend.stats.sections} sections   collision Parts {CollisionBuilder.stats.parts}`,
			string.format("live edit pool: %d slots (%d meshes), %d in use, no free slot %dx%s",
				ls.slots, ls.meshes, ls.inUse, ls.noSlot, if ls.createError ~= "" then `, error: {ls.createError}` else ""),
			string.format("instant edit %.2f ms avg (live write %.2f ms)   edit->baked hand-over %.2f s avg (%d)   F6 keep live: %s",
				if rs.urgentBuilds > 0 then rs.urgentTime / rs.urgentBuilds * 1000 else 0,
				if ls.writes > 0 then ls.writeTime / ls.writes * 1000 else 0,
				if rs.swaps > 0 then rs.swapTime / rs.swaps else 0, rs.swaps,
				if ChunkRenderer.keepTemp then "ON" else "off"),
			`memory: GraphicsMeshParts {fmtMb(tagMb("GraphicsMeshParts"))}   GraphicsParts {fmtMb(tagMb("GraphicsParts"))}   total {string.format("%.0f MB", Stats:GetTotalMemoryUsageMb())}`,
			if es.bakeError ~= "" then `bake unavailable: {es.bakeError}` else "",
			`mesh upload retries {es.uploadRetries}   failures {es.failures}`,
			if #reasons > 0 then "failure reasons: " .. table.concat(reasons, " | ") else "",
		}, "\n")
	end)
end

return DebugOverlay
