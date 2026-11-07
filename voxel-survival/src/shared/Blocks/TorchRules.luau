--!strict
-- Torch placement and support (shared: the client predicts, the server decides).
--   * clicking the top of a block places a standing torch on it
--   * clicking the side of a block places a wall torch leaning away from that block
--   * torches can't hang from ceilings; if the clicked face can't hold one, a standing torch is
--     tried, then any wall next to the cell
--   * a torch breaks (and drops) when the block holding it is removed
-- A supporting block must be a solid full cube.

local BlockRegistry = require(script.Parent.BlockRegistry)

local TorchRules = {}

local TORCH = BlockRegistry.id("torch")
local WALL = {
	east = BlockRegistry.id("wall_torch_east"), -- wall at x - 1
	west = BlockRegistry.id("wall_torch_west"), -- wall at x + 1
	south = BlockRegistry.id("wall_torch_south"), -- wall at z - 1
	north = BlockRegistry.id("wall_torch_north"), -- wall at z + 1
}
local SUPPORT_OFFSET: { [number]: { number } } = {
	[TORCH] = { 0, -1, 0 },
	[WALL.east] = { -1, 0, 0 },
	[WALL.west] = { 1, 0, 0 },
	[WALL.south] = { 0, 0, -1 },
	[WALL.north] = { 0, 0, 1 },
}
TorchRules.TORCH = TORCH
TorchRules.WALL = WALL

local isSolid = BlockRegistry.isSolid
local isCube = BlockRegistry.isCube

function TorchRules.isTorch(id: number): boolean
	return SUPPORT_OFFSET[id] ~= nil
end

local function sturdy(id: number?): boolean
	return id ~= nil and isSolid[id + 1] and isCube[id + 1]
end

-- Which block to place for `itemBlock` at (x, y, z), clicked face normal (nx, ny, nz).
-- Non-torch items return themselves; nil = a torch can't go here.
function TorchRules.placement(itemBlock: number, x: number, y: number, z: number, nx: number, ny: number, nz: number, getBlock: (number, number, number) -> number?): number?
	if itemBlock ~= TORCH then
		return itemBlock
	end
	local function wallFor(dx: number, dz: number): number?
		-- wall at (x - dx, z - dz): the torch leans towards +(dx, dz)
		if not sturdy(getBlock(x - dx, y, z - dz)) then
			return nil
		end
		if dx == 1 then
			return WALL.east
		elseif dx == -1 then
			return WALL.west
		elseif dz == 1 then
			return WALL.south
		else
			return WALL.north
		end
	end
	if ny == 1 and sturdy(getBlock(x, y - 1, z)) then
		return TORCH
	end
	if ny == 0 and (nx ~= 0 or nz ~= 0) then
		local w = wallFor(nx, nz)
		if w then
			return w
		end
	end
	if sturdy(getBlock(x, y - 1, z)) then
		return TORCH
	end
	for _, d in { { 1, 0 }, { -1, 0 }, { 0, 1 }, { 0, -1 } } do
		local w = wallFor(d[1], d[2])
		if w then
			return w
		end
	end
	return nil
end

-- The block a torch hangs on, or nil for non-torches.
function TorchRules.support(id: number, x: number, y: number, z: number): (number?, number?, number?)
	local o = SUPPORT_OFFSET[id]
	if not o then
		return nil, nil, nil
	end
	return x + o[1], y + o[2], z + o[3]
end

-- Torches around (x, y, z) that hang on it: list of {x, y, z}.
function TorchRules.dependents(x: number, y: number, z: number, getBlock: (number, number, number) -> number?): { { number } }
	local out = {}
	for id, o in SUPPORT_OFFSET do
		local tx, ty, tz = x - o[1], y - o[2], z - o[3]
		if getBlock(tx, ty, tz) == id then
			table.insert(out, { tx, ty, tz })
		end
	end
	return out
end

return TorchRules
