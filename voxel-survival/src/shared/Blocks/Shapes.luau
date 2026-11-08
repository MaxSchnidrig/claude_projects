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
	return { math.min(ax, bx), b[2], math.min(az, bz), math.max(ax, bx), b[5], math.max(az, bz) }
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

-- Does a fence connect toward a block with this id?
function Shapes.fenceConnects(id: number?): boolean
	if id == nil or id == 0 then
		return false
	end
	local d = byId[id]
	if d and d.shape == "fence" then
		return true
	end
	-- Java: full sturdy faces (not leaves; ours are not opaque anyway)
	return isOpaque[id + 1] and isCube[id + 1]
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
		if Shapes.fenceConnects(get(v[1], 0, v[2])) then
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
