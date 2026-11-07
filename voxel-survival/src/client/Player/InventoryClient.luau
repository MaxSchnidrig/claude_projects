--!strict
-- Client mirror of the server inventory: slots, cursor stack, the open window (crafting grid,
-- result, container contents, furnace progress) and the locally selected hotbar slot.
-- The server is authoritative; this only displays state and sends intentions.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared.Config)
local Remotes = require(Shared.Net.Remotes)

export type Stack = { item: string, count: number, durability: number? }
export type Window = {
	kind: string, -- "inventory" | "crafting_table" | "furnace" | "chest"
	x: number?,
	y: number?,
	z: number?,
	craftWidth: number?,
	craft: { [number]: Stack? }?,
	result: Stack?,
	block: { [number]: Stack? }?,
	burn: number?,
	burnMax: number?,
	progress: number?,
}

local InventoryClient = {}
InventoryClient.slots = {} :: { [number]: Stack? }
InventoryClient.selected = 1
InventoryClient.cursor = nil :: Stack?
InventoryClient.window = { kind = "inventory" } :: Window
InventoryClient.uiOpen = false -- set by InventoryUI; gameplay input is ignored while true
InventoryClient.syncCount = 0 -- InventorySync messages received (diagnostics)
InventoryClient.itemCount = 0 -- items in the last sync

local changed = Instance.new("BindableEvent")
InventoryClient.Changed = changed.Event -- fires (selectionChanged: boolean)

local function unpackSlots(list: any, n: number): { [number]: Stack? }
	local out = {}
	if typeof(list) == "table" then
		for i = 1, n do
			local s = list[i]
			if typeof(s) == "table" then
				out[i] = s
			end
		end
	end
	return out
end

local function stackOrNil(v: any): Stack?
	return if typeof(v) == "table" then v else nil
end

function InventoryClient.init()
	Remotes.get("InventorySync").OnClientEvent:Connect(function(data: any)
		if typeof(data) ~= "table" or typeof(data.slots) ~= "table" then
			return
		end
		InventoryClient.slots = unpackSlots(data.slots, Config.INVENTORY_SLOTS)
		InventoryClient.cursor = stackOrNil(data.cursor)
		local w = data.window
		if typeof(w) == "table" and typeof(w.kind) == "string" then
			local cw = if typeof(w.craftWidth) == "number" then w.craftWidth else nil
			InventoryClient.window = {
				kind = w.kind,
				x = w.x,
				y = w.y,
				z = w.z,
				craftWidth = cw,
				craft = if cw then unpackSlots(w.craft, cw * cw) else nil,
				result = stackOrNil(w.result),
				block = if typeof(w.block) == "table" then unpackSlots(w.block, #w.block) else nil,
				burn = w.burn,
				burnMax = w.burnMax,
				progress = w.progress,
			}
		end
		InventoryClient.syncCount += 1
		local n = 0
		for _, st in InventoryClient.slots do
			n += (st :: Stack).count
		end
		InventoryClient.itemCount = n
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

-- Intentions sent to the server (see server InventoryService for the rules).
local function send(action: { [string]: any })
	Remotes.get("InventoryAction"):FireServer(action)
end

function InventoryClient.click(container: string, index: number, button: string, shift: boolean)
	send({ type = "click", container = container, index = index, button = button, shift = shift })
end

function InventoryClient.openInventory()
	send({ type = "openInventory" })
end

function InventoryClient.openBlock(x: number, y: number, z: number)
	send({ type = "open", x = x, y = y, z = z })
end

function InventoryClient.close()
	send({ type = "close" })
end

function InventoryClient.drop(all: boolean)
	send({ type = "drop", all = all })
end

-- Drag with the carried stack across slots: refs are { {container, index}, ... } in visit order.
function InventoryClient.drag(refs: { { any } }, button: string)
	send({ type = "drag", slots = refs, button = button })
end

-- Q while hovering a slot in an open window.
function InventoryClient.dropSlot(container: string, index: number, all: boolean)
	send({ type = "dropSlot", container = container, index = index, all = all })
end

function InventoryClient.dropCursor(all: boolean)
	send({ type = "dropCursor", all = all })
end

return InventoryClient
