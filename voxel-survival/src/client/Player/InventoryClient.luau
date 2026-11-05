--!strict
-- Client mirror of the server inventory, plus the locally selected hotbar slot.
-- The server is authoritative; this only displays and reports the selection.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared.Config)
local Remotes = require(Shared.Net.Remotes)

export type Stack = { item: string, count: number, durability: number? }

local InventoryClient = {}
InventoryClient.slots = {} :: { [number]: Stack? }
InventoryClient.selected = 1

local changed = Instance.new("BindableEvent")
InventoryClient.Changed = changed.Event -- fires (selectionChanged: boolean)

function InventoryClient.init()
	Remotes.get("InventorySync").OnClientEvent:Connect(function(data: any)
		if typeof(data) ~= "table" or typeof(data.slots) ~= "table" then
			return
		end
		local slots = {}
		for i = 1, Config.INVENTORY_SLOTS do
			local s = data.slots[i]
			if typeof(s) == "table" then
				slots[i] = s
			end
		end
		InventoryClient.slots = slots
		changed:Fire(false)
	end)
	-- tell the server our starting selection
	Remotes.get("SelectSlot"):FireServer(InventoryClient.selected)
end

function InventoryClient.select(n: number)
	n = ((n - 1) % Config.HOTBAR_SLOTS) + 1
	if n == InventoryClient.selected then
		return
	end
	InventoryClient.selected = n
	Remotes.get("SelectSlot"):FireServer(n)
	changed:Fire(true)
end

function InventoryClient.heldStack(): Stack?
	return InventoryClient.slots[InventoryClient.selected]
end

function InventoryClient.heldItem(): string?
	local s = InventoryClient.heldStack()
	return s and s.item
end

return InventoryClient
