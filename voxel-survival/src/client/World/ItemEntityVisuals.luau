--!strict
-- How dropped items look (client only). The server keeps one plain Part per dropped stack in
-- workspace.ItemEntities (name = item key, attributes Base = resting point, Count); this module
-- draws the real item in its place:
--   * flat items (tools, food, materials, torches...) as their extruded icon, half a block wide
--   * block items as a small 3D block (a quarter block), textured like the world
--   * Java's extra copies for bigger stacks: 2 copies above 1 item, 3 above 16, 4 above 32,
--     5 above 48
--   * Java's spin (1 radian a second) and bob (a tenth of a block), each item at its own phase
-- Meshes come from Render/ItemMeshes (one cached mesh per item type); until an item's mesh is
-- ready its server Part stays visible. All copies are moved with one BulkMoveTo per frame, and
-- items far away aren't animated.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared.Config)
local ItemMeshes = require(script.Parent.Parent.Render.ItemMeshes)

local BS = Config.BLOCK_SIZE
local PIXEL = 0.5 * BS / 16 -- flat items: 16 pixels = half a block (Java's 0.5 scale)
local BLOCK = 0.25 * BS -- block items: a quarter block
local REST_ABOVE_FLOOR = 0.45 -- (ItemEntityService.restY)
local ANIMATE_DISTANCE = 96 -- studs; farther items stay where they are

local ItemEntityVisuals = {}
ItemEntityVisuals.stats = { items = 0, meshParts = 0, waiting = 0 }

type Entry = {
	server: BasePart,
	key: string,
	count: number,
	parts: { BasePart },
	offsets: { CFrame },
	phase: number,
	block: boolean,
	display: Vector3?,
	lift: number, -- studs from the resting point to the item's centre
}

local entries: { [BasePart]: Entry } = {}
local holder: Folder

-- Java ItemEntityRenderer.getRenderAmount
local function copiesFor(count: number): number
	return if count > 48 then 5 elseif count > 32 then 4 elseif count > 16 then 3 elseif count > 1 then 2 else 1
end
ItemEntityVisuals.copiesFor = copiesFor

-- small deterministic random numbers per item (from its resting point)
local function rand(seed: number, i: number): number
	local h = math.abs(math.sin(seed * 12.9898 + i * 78.233) * 43758.5453)
	return (h % 1) * 2 - 1
end

local function clear(e: Entry)
	for _, p in e.parts do
		p:Destroy()
	end
	table.clear(e.parts)
	table.clear(e.offsets)
end

-- (Re)build an entry's copies; false if the mesh isn't ready yet.
local function build(e: Entry): boolean
	local first = ItemMeshes.make(e.key, PIXEL, BLOCK)
	if not first then
		return false
	end
	clear(e)
	local n = copiesFor(e.count)
	for i = 1, n do
		local p = if i == 1 then first else ItemMeshes.make(e.key, PIXEL, BLOCK) :: MeshPart
		p.CastShadow = true
		p.Parent = holder
		table.insert(e.parts, p)
		if i == 1 then
			table.insert(e.offsets, CFrame.identity)
		elseif e.block then
			-- blocks: scattered a little in every direction
			local s = BS * 0.12
			table.insert(e.offsets, CFrame.new(rand(e.phase, i) * s, rand(e.phase, i + 7) * s, rand(e.phase, i + 13) * s))
		else
			-- flat items: stacked behind each other with a slight shift
			local s = BS * 0.04
			table.insert(e.offsets, CFrame.new(rand(e.phase, i) * s, rand(e.phase, i + 7) * s, -(i - 1) * BS * 0.09375))
		end
	end
	e.server.LocalTransparencyModifier = 1
	return true
end

local function add(part: Instance)
	if not part:IsA("BasePart") or entries[part] then
		return
	end
	local base = part:GetAttribute("Base")
	local seed = if typeof(base) == "Vector3" then base.X * 0.37 + base.Z * 0.61 else 0
	local count = part:GetAttribute("Count")
	local e: Entry = {
		server = part,
		key = part.Name,
		count = if typeof(count) == "number" then count else 1,
		parts = {},
		offsets = {},
		phase = seed % 6.28,
		block = ItemMeshes.kind(part.Name) == "block",
		lift = 0,
	}
	-- the server's resting point is REST_ABOVE_FLOOR above the floor; lift the item so its
	-- bottom sits there
	e.lift = math.max(0, (if e.block then BLOCK else 16 * PIXEL) / 2 - REST_ABOVE_FLOOR)
	entries[part] = e
	build(e)
	part:GetAttributeChangedSignal("Count"):Connect(function()
		local c = part:GetAttribute("Count")
		local n = if typeof(c) == "number" then c else 1
		if copiesFor(n) ~= copiesFor(e.count) then
			e.count = n
			build(e)
		else
			e.count = n
		end
	end)
end

local function remove(part: Instance)
	local e = entries[part :: BasePart]
	if e then
		clear(e)
		entries[part :: BasePart] = nil
	end
end

local moveParts: { BasePart } = {}
local moveCFrames: { CFrame } = {}

function ItemEntityVisuals.init()
	local folder = workspace:WaitForChild("ItemEntities", 30)
	if not folder then
		warn("[ItemEntityVisuals] workspace.ItemEntities not found")
		return
	end
	holder = Instance.new("Folder")
	holder.Name = "ItemVisuals"
	holder.Parent = workspace
	for _, c in folder:GetChildren() do
		add(c)
	end
	folder.ChildAdded:Connect(add)
	folder.ChildRemoved:Connect(remove)

	RunService.RenderStepped:Connect(function(dt)
		local t = os.clock()
		local cam = workspace.CurrentCamera
		local camPos = if cam then cam.CFrame.Position else Vector3.zero
		table.clear(moveParts)
		table.clear(moveCFrames)
		local items, meshes, waiting = 0, 0, 0
		for part, e in entries do
			items += 1
			if #e.parts == 0 then
				waiting += 1
				build(e) -- (cheap until the mesh exists: ItemMeshes.make returns nil)
			end
			local base = part:GetAttribute("Base")
			if typeof(base) == "Vector3" then
				-- Java: bob = sin(age / 10 + offset) * 0.1 + 0.1 blocks (never below the ground), the
				-- item's lowest point just above the resting point the server gives
				local bob = (math.sin(t * 2 + e.phase) * 0.1 + 0.1) * BS
				local airborne = part:GetAttribute("Airborne") == true
				if airborne then bob = 0 end
				local display = if e.display then e.display:Lerp(base, 1 - math.exp(-30 * dt)) else base
				e.display = display
				local cf = CFrame.new(display + Vector3.new(0, bob + e.lift, 0)) * CFrame.Angles(0, t + e.phase, 0)
				if #e.parts == 0 then
					part.CFrame = cf -- the stand-in (server part) still animates
				elseif airborne or (base - camPos).Magnitude < ANIMATE_DISTANCE or e.parts[1].CFrame.Position == Vector3.zero then
					for i, p in e.parts do
						table.insert(moveParts, p)
						table.insert(moveCFrames, cf * e.offsets[i])
					end
				end
			end
			meshes += #e.parts
		end
		if #moveParts > 0 then
			workspace:BulkMoveTo(moveParts, moveCFrames, Enum.BulkMoveMode.FireCFrameChanged)
		end
		local st = ItemEntityVisuals.stats
		st.items, st.meshParts, st.waiting = items, meshes, waiting
	end)
end

return ItemEntityVisuals
