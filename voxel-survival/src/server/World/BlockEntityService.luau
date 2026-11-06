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
	kind: string, -- "furnace" | "chest"
	x: number,
	y: number,
	z: number,
	slots: { [number]: Stack? },
	furnace: FurnaceLogic.State?, -- furnaces: slots are furnace.slots
}

local KINDS = {
	[BlockRegistry.id("furnace")] = "furnace",
	[BlockRegistry.id("chest")] = "chest",
}
local CHEST_SLOTS = 27

local BlockEntityService = {}
BlockEntityService.CHEST_SLOTS = CHEST_SLOTS

local entities: { [string]: Entity } = {}
local onChanged: ((Entity) -> ())? = nil -- InventoryService refreshes viewers

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
	end
	return e :: Entity
end

-- Remove the entity (block broken). Returns its contents so they can be dropped.
function BlockEntityService.remove(x: number, y: number, z: number): { Stack }
	local k = key(x, y, z)
	local e = entities[k]
	entities[k] = nil
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
			end
		end
	end)
end

return BlockEntityService
