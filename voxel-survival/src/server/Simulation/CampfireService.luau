--!strict
-- Campfires, Java Edition rules:
--   * lit when placed; light 15; standing on a lit campfire hurts (1 per hit, unless sneaking)
--   * right-click with raw food that has a cooked form puts it on (4 spots); it cooks in 30 s on a
--     lit campfire and pops off cooked
--   * water or a shovel puts it out; flint and steel lights it again
--   * breaking it drops 2 charcoal and whatever is cooking
-- The cooking items are a block entity (saved with the region); timers restart after a reload.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared.Config)
local Remotes = require(Shared.Net.Remotes)
local BlockRegistry = require(Shared.Blocks.BlockRegistry)
local ItemRegistry = require(Shared.Items.ItemRegistry)
local Crafting = require(Shared.Items.Crafting)
local WorldService = require(script.Parent.Parent.World.WorldService)
local BlockEntityService = require(script.Parent.Parent.World.BlockEntityService)
local ItemEntityService = require(script.Parent.Parent.World.ItemEntityService)

local BS = Config.BLOCK_SIZE
local LIT = BlockRegistry.id("campfire")
local COOK_SECONDS = 30

local CampfireService = {}
local timers: { [any]: { number } } = {} -- entity -> seconds cooked per slot

local function sendState(e: BlockEntityService.Entity)
	local items = {}
	for i = 1, 4 do
		local s = e.slots[i]
		items[i] = if s then s.item else false
	end
	local remote = Remotes.get("CampfireState")
	for _, p in Players:GetPlayers() do
		remote:FireClient(p, e.x, e.y, e.z, items)
	end
end

-- Can this item be cooked on a campfire (food with a cooked form)?
function CampfireService.cookable(item: string?): boolean
	local def = ItemRegistry.get(item)
	return def ~= nil and def.food ~= nil and Crafting.smeltResult(item) ~= nil
end

-- Put one item on the campfire. Returns true if it fit.
function CampfireService.addItem(x: number, y: number, z: number, item: string): boolean
	local e = BlockEntityService.ensure(x, y, z, "campfire")
	for i = 1, 4 do
		if not e.slots[i] then
			e.slots[i] = { item = item, count = 1 }
			local t = timers[e] or { 0, 0, 0, 0 }
			timers[e] = t
			t[i] = 0
			BlockEntityService.markDirty(x, z)
			sendState(e)
			return true
		end
	end
	return false
end

function CampfireService.init()
	local acc = 0
	RunService.Heartbeat:Connect(function(dt)
		acc += dt
		if acc < 0.25 then
			return
		end
		local step = acc
		acc = 0
		for _, e in BlockEntityService.ofKind("campfire") do
			local lit = WorldService.getBlockIfLoaded(e.x, e.y, e.z) == LIT
			local t = timers[e] or { 0, 0, 0, 0 }
			timers[e] = t
			for i = 1, 4 do
				local s = e.slots[i]
				if s and lit then
					t[i] += step
					if t[i] >= COOK_SECONDS then
						t[i] = 0
						e.slots[i] = nil
						local cooked = Crafting.smeltResult(s.item) or s.item
						ItemEntityService.spawn({ item = cooked, count = 1 }, Vector3.new(e.x + 0.5, e.y + 1.1, e.z + 0.5) * BS)
						BlockEntityService.markDirty(e.x, e.z)
						sendState(e)
					end
				end
			end
		end
	end)
	-- show what's cooking to players who join later
	Players.PlayerAdded:Connect(function(p)
		task.wait(3)
		for _, e in BlockEntityService.ofKind("campfire") do
			local items = {}
			for i = 1, 4 do
				local s = e.slots[i]
				items[i] = if s then s.item else false
			end
			Remotes.get("CampfireState"):FireClient(p, e.x, e.y, e.z, items)
		end
	end)
	WorldService.onBlockChanged(function(x, y, z, old)
		if (old == LIT or old == BlockRegistry.id("campfire_unlit")) then
			local items = { false, false, false, false }
			for _, p in Players:GetPlayers() do
				Remotes.get("CampfireState"):FireClient(p, x, y, z, items)
			end
		end
	end)
end

return CampfireService
