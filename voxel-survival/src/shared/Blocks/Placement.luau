--!strict
-- Which block states a held block item places, and where (shared: the client predicts, the
-- server decides). Java rules:
--   slabs   top half when clicking a block's underside or the upper half of a side; clicking a
--           slab's open side with the same slab (or placing into a cell holding one) makes a
--           double slab
--   stairs  face the way the player looks; upside down like slabs
--   doors   face the way the player looks; need two free cells and a floor; the hinge goes
--           toward the wall / away from a neighbouring door / by the click position
--           (DoorBlock.getHinge)
--   ladders on the side of a full block, facing away from it
--   signs   standing on top of a block (16 rotations from the player's yaw) or on a wall
--   torches TorchRules
--
-- `ctx`: hit cell (hx, hy, hz), clicked face normal (nx, ny, nz), exact hit point (px, py, pz)
-- in block units, and the player's look direction (lx, lz).

local BlockRegistry = require(script.Parent.BlockRegistry)
local TorchRules = require(script.Parent.TorchRules)
local Shapes = require(script.Parent.Shapes)

local Placement = {}

export type Ctx = {
	hx: number, hy: number, hz: number,
	nx: number, ny: number, nz: number,
	px: number, py: number, pz: number,
	lx: number, lz: number,
}
export type Change = { x: number, y: number, z: number, id: number }

local byId = BlockRegistry.byId
local byKey = BlockRegistry.byKey
local isLiquid = BlockRegistry.isLiquid
local isSolid = BlockRegistry.isSolid
local isCube = BlockRegistry.isCube
local isOpaque = BlockRegistry.isOpaque
local FIRE = BlockRegistry.id("fire")

-- Cells a placement may overwrite: air, liquids, fire.
function Placement.replaceable(id: number?): boolean
	return id ~= nil and (id == 0 or isLiquid[id + 1] or id == FIRE)
end
local replaceable = Placement.replaceable

local function sturdy(id: number?): boolean
	return id ~= nil and isSolid[id + 1] and isCube[id + 1]
end

-- Java Direction.fromYRot of the look vector: the horizontal direction the player faces.
function Placement.facingOf(lx: number, lz: number): string
	if math.abs(lx) > math.abs(lz) then
		return if lx > 0 then "east" else "west"
	end
	return if lz > 0 then "south" else "north"
end

-- Java yRot in degrees (0 = looking south, 90 = west, 180 = north, 270 = east).
function Placement.yRot(lx: number, lz: number): number
	return math.deg(math.atan2(-lx, lz)) % 360
end

local function normalFacing(nx: number, nz: number): string?
	if nx == 1 then
		return "east"
	elseif nx == -1 then
		return "west"
	elseif nz == 1 then
		return "south"
	elseif nz == -1 then
		return "north"
	end
	return nil
end

local function stateId(family: string, match: (st: { [string]: any }) -> boolean): number?
	-- small families; a linear scan is fine (placements are rare)
	for id, d in byId do
		if d.family == family and match(d.state) then
			return id
		end
	end
	return nil
end

local cache: { [string]: number } = {}
local function cachedState(family: string, key: string, match: (st: { [string]: any }) -> boolean): number?
	local k = family .. "|" .. key
	local v = cache[k]
	if v == nil then
		v = stateId(family, match) or -1
		cache[k] = v
	end
	return if v == -1 then nil else v
end

function Placement.slabState(family: string, half: string): number?
	return cachedState(family, half, function(st)
		return st.half == half
	end)
end

function Placement.stairsState(family: string, facing: string, half: string): number?
	return cachedState(family, facing .. half, function(st)
		return st.facing == facing and st.half == half
	end)
end

function Placement.doorState(family: string, facing: string, open: boolean, hinge: string): number?
	return cachedState(family, `{facing}{open}{hinge}`, function(st)
		return not st.upper and st.facing == facing and st.open == open and st.hinge == hinge
	end)
end

function Placement.doorUpper(family: string): number?
	return cachedState(family, "upper", function(st)
		return st.upper == true
	end)
end

-- The same door with its `open` flipped (lower-half id), or nil if `id` isn't a lower door half.
function Placement.toggledDoor(id: number): number?
	local d = byId[id]
	if not d or d.shape ~= "door" or d.state.upper then
		return nil
	end
	return Placement.doorState(d.family, d.state.facing, not d.state.open, d.state.hinge)
end

local function ladderState(facing: string): number?
	return cachedState("ladder", facing, function(st)
		return st.facing == facing
	end)
end

local function signState(family: string, rotation: number?, wallFacing: string?): number?
	if wallFacing then
		return cachedState(family, "wall" .. wallFacing, function(st)
			return st.facing == wallFacing
		end)
	end
	return cachedState(family, "rot" .. tostring(rotation), function(st)
		return st.rotation == rotation
	end)
end

local DIR = Shapes.DIR

-- Java DoorBlock.getHinge.
local function doorHinge(family: string, facing: string, x: number, y: number, z: number, ctx: Ctx, get: (number, number, number) -> number?): string
	local left, right = DIR[Shapes.ccw(facing)], DIR[Shapes.opposite(Shapes.ccw(facing))]
	local function full(id: number?): boolean
		return id ~= nil and isOpaque[id + 1] and isCube[id + 1]
	end
	local i = (if full(get(x + left[1], y, z + left[2])) then -1 else 0)
		+ (if full(get(x + left[1], y + 1, z + left[2])) then -1 else 0)
		+ (if full(get(x + right[1], y, z + right[2])) then 1 else 0)
		+ (if full(get(x + right[1], y + 1, z + right[2])) then 1 else 0)
	local function lowerDoor(id: number?): boolean
		local d = id and byId[id]
		return d ~= nil and d.family == family and not d.state.upper
	end
	local doorLeft = lowerDoor(get(x + left[1], y, z + left[2]))
	local doorRight = lowerDoor(get(x + right[1], y, z + right[2]))
	if (not doorLeft or doorRight) and i <= 0 then
		if (not doorRight or doorLeft) and i >= 0 then
			local d = DIR[facing]
			local j, k = d[1], d[2]
			local d0, d1 = ctx.px - x, ctx.pz - z
			local leftHinge = (j >= 0 or not (d1 < 0.5)) and (j <= 0 or not (d1 > 0.5))
				and (k >= 0 or not (d0 > 0.5)) and (k <= 0 or not (d0 < 0.5))
			return if leftHinge then "left" else "right"
		end
		return "left"
	end
	return "right"
end

-- The changes placing `itemBlock` makes (the first is the main cell), or nil + reason.
function Placement.resolve(itemBlock: number, ctx: Ctx, get: (number, number, number) -> number?): ({ Change }?, string?)
	local def = byId[itemBlock]
	if not def then
		return nil, "unknown block"
	end
	local hx, hy, hz = ctx.hx, ctx.hy, ctx.hz
	local x, y, z = hx + ctx.nx, hy + ctx.ny, hz + ctx.nz
	local fracY = ctx.py - hy
	if ctx.ny == 0 then
		fracY = ctx.py - y
	end
	local shape = def.shape

	if shape == "slab" then
		-- merge into the clicked slab
		local clicked = get(hx, hy, hz)
		local cd = clicked and byId[clicked]
		if cd and cd.family == def.family and cd.shape == "slab"
			and ((cd.state.half == "bottom" and ctx.ny == 1) or (cd.state.half == "top" and ctx.ny == -1))
		then
			local dbl = Placement.slabState(def.family, "double")
			return if dbl then { { x = hx, y = hy, z = hz, id = dbl } } else nil, "no double slab"
		end
		-- merge into a slab already in the target cell
		local here = get(x, y, z)
		local hd = here and byId[here]
		if hd and hd.family == def.family and hd.shape == "slab" then
			local dbl = Placement.slabState(def.family, "double")
			return if dbl then { { x = x, y = y, z = z, id = dbl } } else nil, "no double slab"
		end
		if not replaceable(here) then
			return nil, "cell occupied"
		end
		local half = if ctx.ny == -1 or (ctx.ny == 0 and fracY > 0.5) then "top" else "bottom"
		local id = Placement.slabState(def.family, half)
		return if id then { { x = x, y = y, z = z, id = id } } else nil, "no slab state"
	end

	if not replaceable(get(x, y, z)) then
		return nil, "cell occupied"
	end

	if shape == "stairs" then
		local half = if ctx.ny == -1 or (ctx.ny == 0 and fracY > 0.5) then "top" else "bottom"
		local id = Placement.stairsState(def.family, Placement.facingOf(ctx.lx, ctx.lz), half)
		return if id then { { x = x, y = y, z = z, id = id } } else nil, "no stairs state"
	elseif shape == "door" then
		if not replaceable(get(x, y + 1, z)) then
			return nil, "no room for the door"
		end
		local below = get(x, y - 1, z)
		if not below or not Shapes.coversFace(below, 3) then
			return nil, "a door needs a floor"
		end
		local facing = Placement.facingOf(ctx.lx, ctx.lz)
		local hinge = doorHinge(def.family, facing, x, y, z, ctx, get)
		local lower = Placement.doorState(def.family, facing, false, hinge)
		local upper = Placement.doorUpper(def.family)
		if not lower or not upper then
			return nil, "no door state"
		end
		return { { x = x, y = y, z = z, id = lower }, { x = x, y = y + 1, z = z, id = upper } }
	elseif shape == "ladder" then
		local function tryFacing(f: string): number?
			local d = DIR[f]
			-- the wall is behind the ladder
			if sturdy(get(x - d[1], y, z - d[2])) then
				return ladderState(f)
			end
			return nil
		end
		local nf = normalFacing(ctx.nx, ctx.nz)
		local id = nf and tryFacing(nf)
		if not id then
			-- Java tries the directions the player is looking toward
			local f = Placement.facingOf(ctx.lx, ctx.lz)
			for _, cand in { Shapes.opposite(f), Shapes.ccw(f), Shapes.opposite(Shapes.ccw(f)), f } do
				id = tryFacing(cand)
				if id then
					break
				end
			end
		end
		return if id then { { x = x, y = y, z = z, id = id } } else nil, "a ladder needs a wall"
	elseif shape == "sign" then
		if ctx.ny == 1 then
			local below = get(x, y - 1, z)
			if not below or not isSolid[below + 1] then
				return nil, "a sign needs something solid below"
			end
			local rot = math.floor((180 + Placement.yRot(ctx.lx, ctx.lz)) * 16 / 360 + 0.5) % 16
			local id = signState(def.family, rot, nil)
			return if id then { { x = x, y = y, z = z, id = id } } else nil, "no sign state"
		elseif ctx.ny == 0 then
			local nf = normalFacing(ctx.nx, ctx.nz) :: string
			local wall = get(hx, hy, hz)
			if not wall or not isSolid[wall + 1] then
				return nil, "a sign needs a solid wall"
			end
			local id = signState(def.family, nil, nf)
			return if id then { { x = x, y = y, z = z, id = id } } else nil, "no sign state"
		end
		return nil, "signs can't hang from ceilings"
	end

	local id = TorchRules.placement(itemBlock, x, y, z, ctx.nx, ctx.ny, ctx.nz, get)
	if not id then
		return nil, "a torch can't go here"
	end
	return { { x = x, y = y, z = z, id = id } }
end

-- Is this block still held up? (ok, drops) — `drops` false means it vanishes without an item
-- (the other half of a door). Torches keep their own rules in TorchRules.
function Placement.supported(id: number, x: number, y: number, z: number, get: (number, number, number) -> number?): (boolean, boolean)
	local d = byId[id]
	if not d then
		return true, true
	end
	local shape = d.shape
	if shape == "ladder" then
		local v = DIR[d.state.facing :: string]
		return sturdy(get(x - v[1], y, z - v[2])), true
	elseif shape == "sign" then
		local below = get(x, y - 1, z)
		return below == nil or isSolid[below + 1], true
	elseif shape == "wall_sign" then
		local v = DIR[d.state.facing :: string]
		local wall = get(x - v[1], y, z - v[2])
		return wall == nil or isSolid[wall + 1], true
	elseif shape == "door" then
		if d.state.upper then
			local below = get(x, y - 1, z)
			local bd = below and byId[below]
			return below == nil or (bd ~= nil and bd.family == d.family and not bd.state.upper), false
		end
		local above = get(x, y + 1, z)
		local ad = above and byId[above]
		if above ~= nil and not (ad and ad.family == d.family and ad.state.upper) then
			return false, false
		end
		local below = get(x, y - 1, z)
		return below == nil or Shapes.coversFace(below, 3), true
	end
	return true, true
end

-- Item frames hang on any face of a solid block.
function Placement.frameSupported(wall: number?): boolean
	return wall ~= nil and isSolid[wall + 1]
end

_ = byKey
return Placement
