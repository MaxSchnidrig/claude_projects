--!strict
-- Runs flowing water and lava on the server (rules: Shared/World/Fluids). A fluid block gets a
-- scheduled tick whenever it or a neighbour changes; lava next to water reacts at once.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared.Config)
local Remotes = require(Shared.Net.Remotes)
local Fluids = require(Shared.World.Fluids)
local WorldService = require(script.Parent.Parent.World.WorldService)
local BlockUpdates = require(script.Parent.Parent.World.BlockUpdates)
local ItemEntityService = require(script.Parent.Parent.World.ItemEntityService)

local BS = Config.BLOCK_SIZE
local FluidService = {}

local world: Fluids.World = {
	get = WorldService.getBlockIfLoaded,
	set = BlockUpdates.set,
	drop = function(x, y, z, item)
		ItemEntityService.spawn({ item = item, count = 1 }, (Vector3.new(x, y, z) + Vector3.new(0.5, 0.5, 0.5)) * BS)
	end,
	fizz = function(x, y, z)
		local pos = (Vector3.new(x, y, z) + Vector3.new(0.5, 1, 0.5)) * BS
		for _, p in Players:GetPlayers() do
			Remotes.get("EntityEvent"):FireClient(p, { type = "fizz", pos = pos })
		end
	end,
}
FluidService.world = world

function FluidService.init()
	BlockUpdates.register("fluid", function(x, y, z)
		Fluids.tick(world, x, y, z)
	end)
	BlockUpdates.onNeighbourChanged(function(x, y, z)
		local id = WorldService.getBlockIfLoaded(x, y, z)
		local fluid = Fluids.info(id)
		if fluid then
			if fluid == "lava" and Fluids.reactLava(world, x, y, z) then
				return
			end
			BlockUpdates.schedule(x, y, z, Fluids.DELAY[fluid], "fluid")
		end
	end)
end

return FluidService
