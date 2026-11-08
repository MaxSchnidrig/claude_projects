--!strict
-- Data attached to specific blocks: furnace contents/fire state and chest contents.
-- Keyed by world block position. Furnaces tick on the server (FurnaceLogic).
-- Phase 6 saves these together with the chunk diffs.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local BlockRegistry = require(Shared.Blocks.BlockRegistry)
local FurnaceLogic = require(Shared.Items.FurnaceLogic)

export type Stack = { item: string, count: number, durability: number? }
export type Entity = {
	kind: string, -- "furnace" | "chest" | "campfire"
	x: number,
	y: number,
	z: number,
	slots: { [number]: Stack? },
	furnace: FurnaceLogic.State?, -- furnaces: slots are furnace.slots
	data: { [string]: any }?, -- signs: { front, back } lines; item frames: { facing, rot }
	key: string?, -- storage key when it isn't the block position (item frames)
}

local KINDS = {
	[BlockRegistry.id("furnace")] = "furnace",
	[BlockRegistry.id("chest")] = "chest",
	[BlockRegistry.id("campfire")] = "campfire",
	[BlockRegistry.id("campfire_unlit")] = "campfire",
}
for id, def in BlockRegistry.byId do
	if def.shape == "sign" or def.shape == "wall_sign" then
		KINDS[id] = "sign"
	end
end
local CHEST_SLOTS = 27

local BlockEntityService = {}
BlockEntityService.CHEST_SLOTS = CHEST_SLOTS

local entities: { [string]: Entity } = {}
local onChanged: ((Entity) -> ())? = nil -- InventoryService refreshes viewers
local dirtyListeners: { (x: number, z: number) -> () } = {} -- Persistence marks the region

local function key(x: number, y: number, z: number): string
	return `{x},{y},{z}`
end

-- Which entity kind a block id has, if any.
function BlockEntityService.kindOf(blockId: number): string?
	return KINDS[blockId]
end

function BlockEntityService.setChangedCallback(fn: (Entity) -> ())
	onChanged = fn
end

-- Contents changed (clicks, furnace progress, creation, removal): tell Persistence.
function BlockEntityService.markDirty(x: number, z: number)
	for _, fn in dirtyListeners do
		fn(x, z)
	end
end

function BlockEntityService.onDirty(fn: (x: number, z: number) -> ())
	table.insert(dirtyListeners, fn)
end

-- Every entity of one kind (e.g. all campfires).
function BlockEntityService.ofKind(kind: string): { Entity }
	local out = {}
	for _, e in entities do
		if e.kind == kind then
			table.insert(out, e)
		end
	end
	return out
end

-- Entities whose x/z lie in [x0, x1) x [z0, z1).
function BlockEntityService.inArea(x0: number, z0: number, x1: number, z1: number): { Entity }
	local out = {}
	for _, e in entities do
		if e.x >= x0 and e.x < x1 and e.z >= z0 and e.z < z1 then
			table.insert(out, e)
		end
	end
	return out
end

-- Listeners for restored entities (signs and item frames tell clients).
local restoreListeners: { (Entity) -> () } = {}
function BlockEntityService.onRestore(fn: (Entity) -> ())
	table.insert(restoreListeners, fn)
end

-- Item frames: keyed by cell and facing (several can share a cell).
function BlockEntityService.frameKey(x: number, y: number, z: number, facing: string): string
	return `f{x},{y},{z},{facing}`
end
function BlockEntityService.getKeyed(k: string): Entity?
	return entities[k]
end
function BlockEntityService.putKeyed(k: string, e: Entity)
	e.key = k
	entities[k] = e
	BlockEntityService.markDirty(e.x, e.z)
end
function BlockEntityService.removeKeyed(k: string): Entity?
	local e = entities[k]
	entities[k] = nil
	if e then
		BlockEntityService.markDirty(e.x, e.z)
	end
	return e
end

-- Recreate a saved entity (Persistence, when its region loads).
function BlockEntityService.restore(kind: string, x: number, y: number, z: number, slots: { [number]: Stack }, burn: number, burnMax: number, progress: number, data: { [string]: any }?)
	if kind == "item_frame" then
		local d = data or {}
		local k = BlockEntityService.frameKey(x, y, z, d.facing or "up")
		local e: Entity = { kind = kind, x = x, y = y, z = z, slots = { [1] = slots[1] }, data = d, key = k }
		entities[k] = e
		for _, fn in restoreListeners do
			fn(e)
		end
		return
	end
	local e = BlockEntityService.ensure(x, y, z, kind)
	if data then
		e.data = data
	end
	if e.furnace then
		local f = e.furnace :: FurnaceLogic.State
		for i = 1, 3 do
			f.slots[i] = slots[i]
		end
		f.burn, f.burnMax, f.progress = burn, burnMax, progress
	else
		for i, st in slots do
			e.slots[i] = st
		end
	end
	for _, fn in restoreListeners do
		fn(e)
	end
end

function BlockEntityService.get(x: number, y: number, z: number): Entity?
	return entities[key(x, y, z)]
end

-- Get or create the entity for a block (e.g. when placed or first opened).
function BlockEntityService.ensure(x: number, y: number, z: number, kind: string): Entity
	local k = key(x, y, z)
	local e = entities[k]
	if not e or e.kind ~= kind then
		local furnace = if kind == "furnace" then FurnaceLogic.new() else nil
		e = {
			kind = kind,
			x = x,
			y = y,
			z = z,
			slots = if furnace then furnace.slots else {},
			furnace = furnace,
		}
		entities[k] = e
		BlockEntityService.markDirty(x, z)
	end
	return e :: Entity
end

-- Remove the entity (block broken). Returns its contents so they can be dropped.
function BlockEntityService.remove(x: number, y: number, z: number): { Stack }
	local k = key(x, y, z)
	local e = entities[k]
	entities[k] = nil
	if e then
		BlockEntityService.markDirty(x, z)
	end
	local out = {}
	if e then
		for _, s in e.slots do
			if s then
				table.insert(out, s)
			end
		end
	end
	return out
end

function BlockEntityService.init()
	local acc = 0
	RunService.Heartbeat:Connect(function(dt)
		acc += dt
		if acc < 0.25 then
			return
		end
		local step = acc
		acc = 0
		for _, e in entities do
			local f = e.furnace
			if f then
				local before = f.burn > 0 or f.progress > 0
				local changed = FurnaceLogic.step(f, step)
				if (changed or before) and onChanged then
					onChanged(e) -- progress bars of anyone viewing it
				end
				if changed or before then
					BlockEntityService.markDirty(e.x, e.z)
				end
			end
		end
	end)
end

return BlockEntityService
