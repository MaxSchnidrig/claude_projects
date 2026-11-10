--!strict
-- Box shapes of non-cube blocks (Java VoxelShapes), shared by rendering, collision, mob physics
-- and raycasts. Boxes are { x0, y0, z0, x1, y1, z1 } in block units, 0..1 inside the cell
-- (collision boxes of fences reach up to 1.5, like Java's).
--
-- `get(dx, dy, dz)` returns the id of a neighbouring block (relative offset) or nil if unknown;
-- fences, stairs and door tops depend on their neighbours.
--
--   slab     bottom or top half
--   stairs   half slab + the step; corners (inner / outer) follow Java's StairBlock rules
--   fence    post + rails toward fences and full solid blocks; collision 1.5 tall
--   door     3/16 thick panel; Java's shape table for facing / open / hinge; the top half reads
--            the bottom half's state
--   ladder   thin rails and rungs on the wall (collision: Java's 3/16 box)

local BlockRegistry = require(script.Parent.BlockRegistry)

local Shapes = {}

export type Box = { number }
export type Getter = (dx: number, dy: number, dz: number) -> number?

local byId = BlockRegistry.byId
local isOpaque = BlockRegistry.isOpaque
local isCube = BlockRegistry.isCube
local isSolid = BlockRegistry.isSolid
local isBoxShape = BlockRegistry.isBoxShape

local FULL: { Box } = { { 0, 0, 0, 1, 1, 1 } }
Shapes.FULL = FULL
local NONE: { Box } = {}

local DIR = { north = { 0, -1 }, east = { 1, 0 }, south = { 0, 1 }, west = { -1, 0 } }
Shapes.DIR = DIR
local function ccw(f: string): string -- counter-clockwise seen from above
	return if f == "north" then "west" elseif f == "west" then "south" elseif f == "south" then "east" else "north"
end
local function axisOf(f: string): string
	return if f == "north" or f == "south" then "z" else "x"
end
local function opposite(f: string): string
	return if f == "north" then "south" elseif f == "south" then "north" elseif f == "east" then "west" else "east"
end
Shapes.opposite = opposite
Shapes.ccw = ccw

local function px(a: number, b: number, c: number, d: number, e: number, f: number): Box
	return { a / 16, b / 16, c / 16, d / 16, e / 16, f / 16 }
end

-- Rotate a box designed for "north" to another facing (a quarter turn per step, seen from above:
-- what reaches toward -z for north reaches toward +x for east, +z for south, -x for west).
local function rot(b: Box, facing: string): Box
	if facing == "north" then
		return b
	end
	local function map(x: number, z: number): (number, number)
		if facing == "east" then
			return 1 - z, x
		elseif facing == "south" then
			return 1 - x, 1 - z
		else -- west
			return z, 1 - x
		end
	end
	local ax, az = map(b[1], b[3])
	local bx, bz = map(b[4], b[6])
	return { math.min(ax, bx), b[2], math.min(az, bz), math.max(ax, bx), b[5], math.max(az, bz), b[7] }
end
Shapes.rotate = rot

-- Stairs --------------------------------------------------------------------------------------

local function stairState(id: number?): { [string]: any }?
	local d = id and byId[id]
	if d and d.shape == "stairs" then
		return d.state
	end
	return nil
end

-- Java StairBlock.getStairsShape: "straight", "inner_left", "inner_right", "outer_left", "outer_right".
function Shapes.stairsShape(state: { [string]: any }, get: Getter): string
	local facing: string, half: string = state.facing, state.half
	local function at(dir: string): { [string]: any }?
		local v = DIR[dir]
		return stairState(get(v[1], 0, v[2]))
	end
	local function canTake(dir: string): boolean
		local n = at(dir)
		return n == nil or n.facing ~= facing or n.half ~= half
	end
	local front = at(facing)
	if front and front.half == half and axisOf(front.facing) ~= axisOf(facing) and canTake(opposite(front.facing)) then
		return if front.facing == ccw(facing) then "outer_left" else "outer_right"
	end
	local back = at(opposite(facing))
	if back and back.half == half and axisOf(back.facing) ~= axisOf(facing) and canTake(back.facing) then
		return if back.facing == ccw(facing) then "inner_left" else "inner_right"
	end
	return "straight"
end

local function stairBoxes(state: { [string]: any }, get: Getter): { Box }
	local top = state.half == "top"
	local slabY0, slabY1 = if top then 0.5 else 0, if top then 1 else 0.5
	local stepY0, stepY1 = if top then 0 else 0.5, if top then 0.5 else 1
	local out: { Box } = { { 0, slabY0, 0, 1, slabY1, 1 } }
	local shape = Shapes.stairsShape(state, get)
	local f = DIR[state.facing :: string]
	local l = DIR[ccw(state.facing)]
	-- quadrant by (forward sign, left sign) -> box
	local function quad(fs: number, ls: number): Box
		local cx = 0.5 + 0.25 * (fs * f[1] + ls * l[1])
		local cz = 0.5 + 0.25 * (fs * f[2] + ls * l[2])
		local x0 = if cx > 0.5 then 0.5 else 0
		local z0 = if cz > 0.5 then 0.5 else 0
		return { x0, stepY0, z0, x0 + 0.5, stepY1, z0 + 0.5 }
	end
	local function merge(a: Box, b: Box): Box
		return { math.min(a[1], b[1]), a[2], math.min(a[3], b[3]), math.max(a[4], b[4]), a[5], math.max(a[6], b[6]) }
	end
	if shape == "straight" then
		table.insert(out, merge(quad(1, 1), quad(1, -1)))
	elseif shape == "outer_left" then
		table.insert(out, quad(1, 1))
	elseif shape == "outer_right" then
		table.insert(out, quad(1, -1))
	elseif shape == "inner_left" then
		table.insert(out, merge(quad(1, 1), quad(1, -1)))
		table.insert(out, quad(-1, 1))
	else -- inner_right
		table.insert(out, merge(quad(1, 1), quad(1, -1)))
		table.insert(out, quad(-1, -1))
	end
	return out
end

-- Fences --------------------------------------------------------------------------------------

-- Java "sturdy face" for connections: a solid full cube, glass included, leaves excluded.
local function sturdyCube(id: number): boolean
	if not (isSolid[id + 1] and isCube[id + 1]) or BlockRegistry.isLiquid[id + 1] then
		return false
	end
	local d = byId[id]
	return d ~= nil and string.find(d.key, "leaves", 1, true) == nil
end
Shapes.sturdyCube = sturdyCube

-- Does a fence connect toward a block with this id?
function Shapes.fenceConnects(id: number?): boolean
	if id == nil or id == 0 then
		return false
	end
	local d = byId[id]
	if d and d.shape == "fence" then
		return true
	end
	-- Java: full sturdy faces (glass too; not leaves)
	return sturdyCube(id)
end

-- Fences, walls and panes join a fence gate whose span runs across the joining direction.
local function gateJoins(id: number?, dir: string): boolean
	local d = id and byId[id]
	return d ~= nil and d.shape == "fence_gate" and axisOf(d.state.facing) ~= axisOf(dir)
end

-- Walls join walls, panes / bars, gates and full solid blocks (Java WallBlock.connectsTo).
local function wallConnects(id: number?, dir: string): boolean
	if id == nil or id == 0 then
		return false
	end
	local d = byId[id]
	if d and (d.shape == "wall" or d.shape == "pane") then
		return true
	end
	return gateJoins(id, dir) or sturdyCube(id)
end

-- Panes and iron bars join each other, walls and full solid blocks (Java IronBarsBlock).
local function paneConnects(id: number?): boolean
	if id == nil or id == 0 then
		return false
	end
	local d = byId[id]
	if d and (d.shape == "pane" or d.shape == "wall") then
		return true
	end
	return sturdyCube(id)
end

local function fenceBoxes(get: Getter, collision: boolean): { Box }
	local out: { Box } = {}
	if collision then
		table.insert(out, px(6, 0, 6, 10, 24, 10))
	else
		table.insert(out, px(6, 0, 6, 10, 16, 10))
	end
	for _, dir in { "north", "east", "south", "west" } do
		local v = DIR[dir]
		local n = get(v[1], 0, v[2])
		if Shapes.fenceConnects(n) or gateJoins(n, dir) then
			-- arms designed toward north (-z); rot() turns a north-designed box toward `dir`
			if collision then
				table.insert(out, rot(px(6, 0, 0, 10, 24, 6), dir))
			else
				table.insert(out, rot(px(7, 6, 0, 9, 9, 6), dir))
				table.insert(out, rot(px(7, 12, 0, 9, 15, 6), dir))
			end
		end
	end
	return out
end

-- Doors ---------------------------------------------------------------------------------------

local DOOR_AABB = {
	north = px(0, 0, 13, 16, 16, 16),
	south = px(0, 0, 0, 16, 16, 3),
	west = px(13, 0, 0, 16, 16, 16),
	east = px(0, 0, 0, 3, 16, 16),
}

-- Java DoorBlock.getShape
function Shapes.doorBox(facing: string, open: boolean, hinge: string): Box
	if not open then
		return DOOR_AABB[facing]
	end
	local right = hinge == "right"
	if facing == "east" then
		return if right then DOOR_AABB.north else DOOR_AABB.south
	elseif facing == "south" then
		return if right then DOOR_AABB.east else DOOR_AABB.west
	elseif facing == "west" then
		return if right then DOOR_AABB.south else DOOR_AABB.north
	else
		return if right then DOOR_AABB.west else DOOR_AABB.east
	end
end

-- Full state of a door cell (the top half takes the bottom half's).
function Shapes.doorState(id: number, get: Getter): { [string]: any }
	local d = byId[id]
	local st = d and d.state or {}
	if st.upper then
		local below = get(0, -1, 0)
		local bd = below and byId[below]
		if bd and bd.shape == "door" and not bd.state.upper then
			return bd.state
		end
		return { facing = "north", open = false, hinge = "left" }
	end
	return st
end

-- Ladders -------------------------------------------------------------------------------------

local LADDER_RENDER_NORTH: { Box } = {
	px(1, 0, 15, 3, 16, 16), px(13, 0, 15, 15, 16, 16),
	px(3, 2, 15, 13, 3, 16), px(3, 6, 15, 13, 7, 16), px(3, 10, 15, 13, 11, 16), px(3, 14, 15, 13, 15, 16),
}
local LADDER_COLLISION_NORTH = px(0, 0, 13, 16, 16, 16)

-- Trapdoors (Java TrapDoorBlock shapes) ---------------------------------------------------------

local TRAP_OPEN = {
	north = px(0, 0, 13, 16, 16, 16),
	south = px(0, 0, 0, 16, 16, 3),
	west = px(13, 0, 0, 16, 16, 16),
	east = px(0, 0, 0, 3, 16, 16),
}
local function trapdoorBox(st: { [string]: any }): Box
	if st.open then
		return TRAP_OPEN[st.facing :: string]
	end
	return if st.half == "top" then px(0, 13, 0, 16, 16, 16) else px(0, 0, 0, 16, 3, 16)
end

-- Fence gates: designed for "north" (the gate spans along x); collision 1.5 tall while closed,
-- nothing while open.
local GATE_CLOSED_NORTH: { Box } = {
	px(0, 5, 7, 2, 16, 9), px(14, 5, 7, 16, 16, 9), -- posts
	px(2, 6, 7, 14, 9, 9), px(2, 12, 7, 14, 15, 9), -- rails
	px(6, 9, 7, 10, 12, 9), -- middle brace
}
local GATE_OPEN_NORTH: { Box } = {
	px(0, 5, 7, 2, 16, 9), px(14, 5, 7, 16, 16, 9),
	px(0, 6, 1, 2, 9, 7), px(0, 12, 1, 2, 15, 7), -- left leaf swung toward -z
	px(14, 6, 1, 16, 9, 7), px(14, 12, 1, 16, 15, 7), -- right leaf
}
local function gateBoxes(st: { [string]: any }, collision: boolean): { Box }
	local f = st.facing :: string
	if collision then
		if st.open then
			return NONE
		end
		return { rot(px(0, 0, 6, 16, 24, 10), f) }
	end
	local out = {}
	for _, b in (if st.open then GATE_OPEN_NORTH else GATE_CLOSED_NORTH) do
		table.insert(out, rot(b, f))
	end
	return out
end

-- Walls: a post plus arms toward connections (Java WallBlock); straight runs have no post.
local function wallBoxes(get: Getter, collision: boolean): { Box }
	local con = {}
	local count = 0
	for _, dir in { "north", "east", "south", "west" } do
		local v = DIR[dir]
		if wallConnects(get(v[1], 0, v[2]), dir) then
			con[dir] = true
			count += 1
		end
	end
	local above = get(0, 1, 0)
	local tall = above ~= nil and above ~= 0 and isSolid[above + 1]
	local straight = count == 2 and ((con.north and con.south) or (con.east and con.west))
	local out = {}
	local h = if collision then 24 elseif tall then 16 else 14
	if not straight or (above ~= nil and byId[above] ~= nil and byId[above].shape == "wall") then
		table.insert(out, px(4, 0, 4, 12, if collision then 24 else 16, 12))
	end
	for dir in con do
		table.insert(out, rot(px(5, 0, 0, 11, h, 8), dir))
	end
	if #out == 0 then
		table.insert(out, px(4, 0, 4, 12, 16, 12))
	end
	return out
end

-- Glass panes and iron bars: a thin post and arms toward connections; bars are rods.
local function paneBoxes(st: { [string]: any }, get: Getter, collision: boolean): { Box }
	local bars = st.bars == true and not collision
	if st.bars ~= true and not collision then
		-- glass: boxes that don't overlap, so no inner faces show through the glass. One box
		-- along x (post included), the z arms beside it.
		local con = {}
		for _, dir in { "north", "east", "south", "west" } do
			local v = DIR[dir]
			con[dir] = paneConnects(get(v[1], 0, v[2]))
		end
		local out: { Box } = {}
		local x0 = if con.west then 0 else 7
		local x1 = if con.east then 16 else 9
		table.insert(out, px(x0, 0, 7, x1, 16, 9))
		if con.north then
			table.insert(out, px(7, 0, 0, 9, 16, 7))
		end
		if con.south then
			table.insert(out, px(7, 0, 9, 9, 16, 16))
		end
		return out
	end
	local out: { Box } = { px(7, 0, 7, 9, 16, 9) }
	for _, dir in { "north", "east", "south", "west" } do
		local v = DIR[dir]
		if paneConnects(get(v[1], 0, v[2])) then
			if bars then
				table.insert(out, rot(px(7, 0, 1, 9, 16, 2.5), dir))
				table.insert(out, rot(px(7, 0, 4.5, 9, 16, 6), dir))
				table.insert(out, rot(px(7, 0, 0, 9, 1, 7), dir))
				table.insert(out, rot(px(7, 15, 0, 9, 16, 7), dir))
			else
				table.insert(out, rot(px(7, 0, 0, 9, 16, 7), dir))
			end
		end
	end
	return out
end

-- Vines: a thin sheet on each face that has one (bits: north 1, east 2, south 4, west 8, up 16).
Shapes.VINE_BITS = { north = 1, east = 2, south = 4, west = 8, up = 16 }
local VINE_SHEET = {
	north = px(0, 0, 0, 16, 16, 0.8),
	east = px(15.2, 0, 0, 16, 16, 16),
	south = px(0, 0, 15.2, 16, 16, 16),
	west = px(0, 0, 0, 0.8, 16, 16),
	up = px(0, 15.2, 0, 16, 16, 16),
}
local function vineBoxes(mask: number): { Box }
	local out = {}
	for face, bit in Shapes.VINE_BITS do
		if (mask // bit) % 2 == 1 then
			table.insert(out, VINE_SHEET[face])
		end
	end
	return out
end

-- Beds (our own model): a blanket box on short wooden legs at the outer end of each half, and a
-- pillow on the head half. Designed for "north" (the head half points to -z). An optional 7th
-- number in a box is the texture index it uses instead of the block's.
local PLANKS_TEX = BlockRegistry.textureIndex["oak_planks"]
local PILLOW_TEX = BlockRegistry.textureIndex["white_wool"]
local function bedBoxes(st: { [string]: any }, collision: boolean): { Box }
	if collision then
		return { px(0, 0, 0, 16, 9, 16) } -- Java: 9/16 high
	end
	local head = st.part == "head"
	local legZ0, legZ1 = if head then 0 else 13, if head then 3 else 16
	local out: { Box } = {
		px(0, 3, 0, 16, 9, 16),
		{ 0, 0, legZ0 / 16, 3 / 16, 3 / 16, legZ1 / 16, PLANKS_TEX },
		{ 13 / 16, 0, legZ0 / 16, 1, 3 / 16, legZ1 / 16, PLANKS_TEX },
	}
	if head then
		table.insert(out, { 2 / 16, 9 / 16, 1 / 16, 14 / 16, 11 / 16, 7 / 16, PILLOW_TEX })
	end
	local f = st.facing :: string
	for i, b in out do
		out[i] = rot(b, f)
	end
	return out
end

-- Public --------------------------------------------------------------------------------------

-- Boxes of block `id`. `collision` = the movement shape (else the visual shape). Full cubes
-- return FULL for collision; blocks without collision return an empty list.
function Shapes.boxes(id: number, get: Getter, collision: boolean): { Box }
	if id == 0 then
		return NONE
	end
	if not isBoxShape[id + 1] then
		if collision then
			return if isSolid[id + 1] and isCube[id + 1] then FULL else NONE
		end
		return if isCube[id + 1] then FULL else NONE
	end
	local d = byId[id]
	local shape, st = d.shape, d.state
	if shape == "slab" then
		return { if st.half == "top" then { 0, 0.5, 0, 1, 1, 1 } else { 0, 0, 0, 1, 0.5, 1 } }
	elseif shape == "stairs" then
		return stairBoxes(st, get)
	elseif shape == "fence" then
		return fenceBoxes(get, collision)
	elseif shape == "door" then
		local s = Shapes.doorState(id, get)
		return { Shapes.doorBox(s.facing, s.open, s.hinge) }
	elseif shape == "trapdoor" then
		return { trapdoorBox(st) }
	elseif shape == "bed" then
		return bedBoxes(st, collision)
	elseif shape == "fence_gate" then
		return gateBoxes(st, collision)
	elseif shape == "wall" then
		return wallBoxes(get, collision)
	elseif shape == "pane" then
		return paneBoxes(st, get, collision)
	elseif shape == "vine" then
		return if collision then NONE else vineBoxes(st.faces)
	elseif shape == "ladder" then
		if collision then
			return { rot(LADDER_COLLISION_NORTH, st.facing) }
		end
		local out = {}
		for _, b in LADDER_RENDER_NORTH do
			table.insert(out, rot(b, st.facing))
		end
		return out
	end
	return FULL
end

-- Does this block's shape cover its whole face in direction d (1..6, BlockRegistry.Dir)? Used to
-- hide the neighbour's face against it. Only full cubes and slab bottoms/tops qualify here.
function Shapes.coversFace(id: number, d: number): boolean
	if isOpaque[id + 1] then
		return true
	end
	local def = byId[id]
	if def and def.shape == "slab" then
		return (def.state.half == "bottom" and d == 4) or (def.state.half == "top" and d == 3)
	end
	return false
end

-- Ladders and vines; an open trapdoor right above a ladder facing the same way (Java).
function Shapes.climbable(id: number?, below: number?): boolean
	local d = id and byId[id]
	if not d then
		return false
	end
	if d.shape == "ladder" or d.shape == "vine" then
		return true
	end
	if d.shape == "trapdoor" and d.state.open then
		local b = below and byId[below]
		return b ~= nil and b.shape == "ladder" and b.state.facing == d.state.facing
	end
	return false
end

-- Boxes of the block at world (x, y, z), reading neighbours through `getBlock`.
function Shapes.at(getBlock: (number, number, number) -> number?, x: number, y: number, z: number, collision: boolean): { Box }
	local id = getBlock(x, y, z)
	if not id then
		return FULL
	end
	return Shapes.boxes(id, function(dx, dy, dz)
		return getBlock(x + dx, y + dy, z + dz)
	end, collision)
end

-- For VoxelRaycast.cast's `shapeOf`: visual boxes of box-shaped blocks, nil (whole cell) otherwise.
function Shapes.rayShapeFn(getBlock: (number, number, number) -> number?): (number, number, number, number) -> { Box }?
	return function(id: number, x: number, y: number, z: number): { Box }?
		if not isBoxShape[id + 1] then
			return nil
		end
		return Shapes.boxes(id, function(dx, dy, dz)
			return getBlock(x + dx, y + dy, z + dz)
		end, false)
	end
end

-- For MobPhysics: true for full cubes and unknown (unloaded) cells, the collision boxes of
-- solid box shapes, false for everything else.
function Shapes.physicsFn(getBlock: (number, number, number) -> number?): (number, number, number) -> any
	return function(x: number, y: number, z: number): any
		local id = getBlock(x, y, z)
		if id == nil then
			return true
		end
		if not isSolid[id + 1] then
			return false
		end
		if isBoxShape[id + 1] then
			return Shapes.boxes(id, function(dx, dy, dz)
				return getBlock(x + dx, y + dy, z + dz)
			end, true)
		end
		return isCube[id + 1]
	end
end

-- Bounding box of a box list (selection outline).
function Shapes.bounds(boxes: { Box }): (Vector3, Vector3)
	local lo = Vector3.new(1, 1, 1)
	local hi = Vector3.zero
	for _, b in boxes do
		lo = lo:Min(Vector3.new(b[1], b[2], b[3]))
		hi = hi:Max(Vector3.new(b[4], b[5], b[6]))
	end
	if #boxes == 0 then
		return Vector3.zero, Vector3.one
	end
	return lo, hi
end

return Shapes
