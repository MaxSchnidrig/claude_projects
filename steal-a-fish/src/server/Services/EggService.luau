--!strict
--[[
	EggService
	==========
	Everything about eggs before they reach a pad on the plot:
	  - Spawning eggs in the danger zones (rarer eggs in deeper zones, using
	    each zone's EggWeights in Config.Zones), with a cap per zone and in total.
	  - Picking up an egg with a ProximityPrompt. The server checks
	    everything: the egg is still there, the player is alive, close enough,
	    owns a plot, isn't already carrying one, and isn't spamming.
	  - Carrying: the player holds the egg above their head, arms straight up,
	    the egg resting on the hands (CarryRig). Heavy eggs can slow them down
	    (Config.Eggs.ByRarity[...].CarrySpeedMultiplier, 1 = no slow-down).
	  - Losing it: being caught by a shark follows Config.Eggs.OnCaught, dying
	    any other way follows Config.Eggs.OnDeath ("Drop" or "Lose").
	  - Every egg REMEMBERS THE ZONE IT FIRST SPAWNED IN, for its whole life:
	    on the ground, carried, dropped and picked up again (by anyone), in
	    the hotbar, on a pad and in saved data. That zone decides which shark
	    chases the thief, and which zone's fish hatch from it.
	  - Reaching the safe zone (the open area and the plots): the egg goes into
	    the player's EGG INVENTORY (max Config.Eggs.MaxInventory). Each egg is
	    a Tool in the Roblox hotbar ("Rare Egg"). The server keeps the real
	    list; the Tools are rebuilt from it (for example after a respawn).
	  - Placing: equip an egg, walk to one of your free pads, press E ("Place
	    Egg"). The server checks the pad, the equipped egg and the inventory,
	    then PetService puts it on the pad and starts its timer.

	Studio-only test command:
		!egg mythic     put a Mythic egg in your egg inventory (from the zone where Mythic eggs are most common)
		!egg mythic 4   ... a Mythic egg from zone 4

	Public interface:
		EggService.IsCarrying(player) -> boolean
		EggService.GetCarriedRarity(player) -> string?
		EggService.DropEgg(player, reason) -> "Dropped" | "Lost" | nil   -- reason: "caught", "died", ...
		EggService.GetInventory(player) -> { InventoryEgg }    -- saving
		EggService.SetInventory(player, eggs)                 -- loading
		EggService.AddToInventory(player, rarity, zone) -> boolean
		EggService.EggPickedUp:Connect(function(player, rarity, originalZone) end)
		EggService.EggDropped:Connect(function(player, rarity, reason) end)
		EggService.EggDelivered:Connect(function(player, rarity) end)
]]

local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Config = require(ReplicatedStorage.Shared.Config)
local Constants = require(ReplicatedStorage.Shared.Constants)
local Layout = require(ReplicatedStorage.Shared.Layout)
local Net = require(ReplicatedStorage.Shared.Net)
local Rarity = require(ReplicatedStorage.Shared.Rarity)
local Signal = require(ReplicatedStorage.Shared.Signal)
local Types = require(ReplicatedStorage.Shared.Types)
local CarryRig = require(ReplicatedStorage.Shared.CarryRig)
local Fish = require(ReplicatedStorage.Shared.Fish)
local Notify = require(script.Parent.Parent.Util.Notify)
local Build = require(script.Parent.Parent.Util.Build)
local EggModel = require(ReplicatedStorage.Shared.Models.EggModel)
local PlayerSpeed = require(script.Parent.Parent.Util.PlayerSpeed)
local DebugCommands = require(script.Parent.Parent.Util.DebugCommands)
local RateLimiter = require(script.Parent.Parent.Util.RateLimiter)
local PlayerLifecycle = require(script.Parent.Parent.Util.PlayerLifecycle)
local PetService = require(script.Parent.PetService)
local PlotService = require(script.Parent.PlotService)
local WorldService = require(script.Parent.WorldService)

-- An egg lying on the ground in the danger zone.
type GroundEgg = {
	Rarity: string,
	Zone: number, -- the zone the egg ORIGINALLY spawned in (kept when dropped)
	Part: BasePart,
	Dropped: boolean, -- true = dropped by a player (temporary, not counted in caps)
	Taken: boolean, -- true once picked up or removed (so it can't be taken twice)
}

-- An egg a player is carrying.
type Carry = {
	Rarity: string,
	Zone: number, -- original zone
	Part: BasePart,
}

-- An egg in the hotbar inventory (also what's saved).
export type InventoryEgg = {
	Rarity: string,
	Zone: number, -- original zone
}

local EggService = {}
EggService.Name = "EggService"

EggService.EggPickedUp = Signal.new()
EggService.EggDropped = Signal.new()
EggService.EggDelivered = Signal.new()

local rng = Random.new()
local eggsFolder: Folder
local zoneEggs: { [number]: { GroundEgg } } = {}
local carrying: { [Player]: Carry } = {}
local pickupLimiter = RateLimiter.new(4, 1) -- max 4 pickup attempts per second

-- Height of an egg's center when it rests on a surface at height `surfaceY`,
-- partly buried (Config.Eggs.VisibleFraction sticks out).
local function restingY(surfaceY: number): number
	return surfaceY + Config.Eggs.Size.Y * (Config.Eggs.VisibleFraction - 0.5)
end

local function notify(player: Player, message: string, kind: string?)
	Notify.send(player, message, kind)
end

local function getRoot(player: Player): BasePart?
	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	if root and root:IsA("BasePart") then
		return root
	end
	return nil
end

local function isAlive(player: Player): boolean
	local character = player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	return humanoid ~= nil and humanoid.Health > 0
end

---------------------------------------------------------------------------
-- Ground eggs
---------------------------------------------------------------------------

local function countZoneEggs(): number
	local total = 0
	for _, list in zoneEggs do
		total += #list
	end
	return total
end

local function removeGroundEgg(egg: GroundEgg)
	egg.Taken = true
	egg.Part:Destroy()
	if not egg.Dropped then
		local list = zoneEggs[egg.Zone]
		local index = table.find(list, egg)
		if index then
			table.remove(list, index)
		end
	end
end

-- A random free spot in the BACK part of a zone (between its halfway mark and
-- the shark's patrol line, see Layout.eggSpawnZRange), or nil if no good
-- spot was found.
local function randomSpotInZone(zoneIndex: number): Vector3?
	local halfX = math.max(Config.World.DangerZoneWidth / 2 - Config.Eggs.SpawnMargin, 0)
	local nearZ, farZ = Layout.eggSpawnZRange(zoneIndex)
	for _ = 1, 10 do
		local position = Vector3.new(rng:NextNumber(-halfX, halfX), restingY(Layout.GroundTop), rng:NextNumber(farZ, nearZ))
		local tooClose = false
		for _, other in zoneEggs[zoneIndex] do
			if (other.Part.Position - position).Magnitude < Config.Eggs.MinSpacing then
				tooClose = true
				break
			end
		end
		if not tooClose then
			return position
		end
	end
	return nil
end

-- Forward declaration: createGroundEgg and tryPickUp use each other.
local tryPickUp: (player: Player, egg: GroundEgg) -> ()

local function createGroundEgg(rarity: string, zoneIndex: number, position: Vector3, dropped: boolean)
	local part = EggModel.create(rarity, zoneIndex, true)
	part.CFrame = CFrame.new(position) * CFrame.Angles(0, rng:NextNumber(0, math.pi * 2), 0)

	local label = Build.billboard(part, `{rarity} Egg`, 2.5, 70)
	label.TextColor3 = Rarity.color(rarity)

	local prompt = Instance.new("ProximityPrompt")
	prompt.Name = "PickupPrompt"
	prompt.ActionText = "Steal"
	prompt.ObjectText = `{rarity} Egg`
	prompt.HoldDuration = Config.Eggs.PickupHoldDuration
	prompt.MaxActivationDistance = Config.Eggs.PickupMaxDistance
	prompt.RequiresLineOfSight = false
	prompt.Parent = part
	CollectionService:AddTag(prompt, Constants.Tags.EggPrompt)

	part.Parent = eggsFolder

	local egg: GroundEgg = {
		Rarity = rarity,
		Zone = zoneIndex,
		Part = part,
		Dropped = dropped,
		Taken = false,
	}

	-- ProximityPrompt.Triggered runs on the server and tells us WHICH player
	-- triggered it. We still check everything, since cheaters can trigger
	-- prompts from far away.
	prompt.Triggered:Connect(function(player: Player)
		tryPickUp(player, egg)
	end)

	if dropped then
		task.delay(Config.Eggs.DroppedEggLifetime, function()
			if not egg.Taken then
				removeGroundEgg(egg)
			end
		end)
	else
		table.insert(zoneEggs[zoneIndex], egg)
	end
end

-- Try to add one new egg to a zone (if it's under its caps).
local function spawnEggInZone(zoneIndex: number): boolean
	local zone = Config.Zones[zoneIndex]
	if #zoneEggs[zoneIndex] >= zone.MaxEggs or countZoneEggs() >= Config.Eggs.MaxEggsTotal then
		return false
	end
	local rarity = Rarity.pick(zone.EggWeights)
	local position = randomSpotInZone(zoneIndex)
	if rarity and position then
		createGroundEgg(rarity, zoneIndex, position, false)
		return true
	end
	return false
end

---------------------------------------------------------------------------
-- Carrying
---------------------------------------------------------------------------

local function attachCarriedEgg(player: Player, rarity: string, zoneIndex: number, root: BasePart)
	local character = root.Parent
	-- The egg rests on the hands: measure how high they reach with the arms up.
	local handsHeight = if character and character:IsA("Model") then CarryRig.carryHeight(character, root) else nil
	local height = if handsHeight
		then handsHeight + Config.Eggs.Size.Y / 2 + Config.Eggs.CarryRestOffset
		else Config.Eggs.CarryHeight

	local part = EggModel.create(rarity, zoneIndex, false)
	part.Name = "CarriedEgg"
	local weld = Instance.new("Weld")
	weld.Part0 = root
	weld.Part1 = part
	weld.C0 = CFrame.new(0, height, 0)
	weld.Parent = part
	part.CFrame = root.CFrame * weld.C0
	part.Parent = character

	carrying[player] = { Rarity = rarity, Zone = zoneIndex, Part = part }
	player:SetAttribute(Constants.Attributes.CarryingEgg, rarity)
	if character and character:IsA("Model") then
		CarryRig.setRaised(character, true)
	end

	local rarityConfig = Config.Eggs.ByRarity[rarity]
	PlayerSpeed.SetMultiplier(player, "Carry", if rarityConfig then rarityConfig.CarrySpeedMultiplier else 1)
end

-- Remove the carried egg from the player and return what it was.
local function takeCarry(player: Player): Carry?
	local carry = carrying[player]
	if not carry then
		return nil
	end
	carrying[player] = nil
	carry.Part:Destroy()
	player:SetAttribute(Constants.Attributes.CarryingEgg, nil)
	if player.Character then
		CarryRig.setRaised(player.Character, false)
	end
	PlayerSpeed.SetMultiplier(player, "Carry", nil)
	return carry
end

tryPickUp = function(player: Player, egg: GroundEgg)
	if egg.Taken then
		return
	end
	if not pickupLimiter.allow(player) then
		return
	end
	if carrying[player] then
		notify(player, "You can only carry one egg at a time!", "warning")
		return
	end
	if not PlotService.GetPlot(player) or not isAlive(player) then
		return
	end
	local root = getRoot(player)
	if not root then
		return
	end
	-- Distance check (+2 studs of slack for network lag).
	if (root.Position - egg.Part.Position).Magnitude > Config.Eggs.PickupMaxDistance + 2 then
		return
	end

	local rarity = egg.Rarity
	local zoneIndex = egg.Zone
	removeGroundEgg(egg)
	attachCarriedEgg(player, rarity, zoneIndex, root)
	notify(player, `You stole a {rarity} Egg! Run back to the safe zone!`, "success")
	-- BotService alerts the shark of the egg's ORIGINAL zone (for a dropped
	-- egg that's still the zone it first spawned in, not where it was dropped).
	EggService.EggPickedUp:Fire(player, rarity, zoneIndex)
end

---------------------------------------------------------------------------
-- Public
---------------------------------------------------------------------------

function EggService.IsCarrying(player: Player): boolean
	return carrying[player] ~= nil
end

function EggService.GetCarriedRarity(player: Player): string?
	local carry = carrying[player]
	return if carry then carry.Rarity else nil
end

-- The player loses their egg. Returns "Dropped" (it's on the ground and can
-- be picked up again), "Lost" (gone) or nil (they had no egg).
--   reason "caught": Config.Eggs.OnCaught, depending on where they were
--     caught compared to the egg's ORIGINAL zone (see Config).
--   anything else ("died", "respawned", ...): Config.Eggs.OnDeath.
-- Eggs only drop inside the danger zone; elsewhere they're lost.
function EggService.DropEgg(player: Player, reason: string): string?
	local root = getRoot(player)
	local position = if root then root.Position else nil
	local carry = takeCarry(player)
	if not carry then
		return nil
	end

	local zoneHere = if position then Layout.zoneIndexAt(position) else nil
	local rule: string
	if reason == "caught" then
		local onCaught = Config.Eggs.OnCaught
		-- Caught in the egg's own zone or deeper: SameOrDeeperZone.
		rule = if zoneHere == nil or zoneHere >= carry.Zone then onCaught.SameOrDeeperZone else onCaught.ShallowerZone
	else
		rule = Config.Eggs.OnDeath
	end

	local outcome = "Lost"
	if rule == "Drop" and position and zoneHere then
		-- The dropped egg keeps its ORIGINAL zone.
		local groundPosition = Vector3.new(position.X, restingY(Layout.GroundTop), position.Z)
		createGroundEgg(carry.Rarity, carry.Zone, groundPosition, true)
		outcome = "Dropped"
	end

	if Config.Debug then
		print(`[{Config.GameName}] {player.Name} lost a {carry.Rarity} Egg ({reason})`)
	end
	EggService.EggDropped:Fire(player, carry.Rarity, reason)
	return outcome
end

---------------------------------------------------------------------------
-- Egg inventory (hotbar Tools)
---------------------------------------------------------------------------

local SAFE_CHECK_INTERVAL = 0.15
local FULL_NOTICE_COOLDOWN = 3

local inventories: { [Player]: { InventoryEgg } } = {}

local function isEggTool(item: Instance): boolean
	return item:IsA("Tool") and typeof(item:GetAttribute(Constants.Attributes.EggRarity)) == "string"
end

local function zoneName(zoneIndex: number): string
	local zone = Config.Zones[zoneIndex]
	return if zone then zone.Name else "?"
end

local function makeEggTool(egg: InventoryEgg): Tool
	local tool = Instance.new("Tool")
	tool.Name = `{egg.Rarity} Egg`
	tool.CanBeDropped = false
	tool.RequiresHandle = true
	tool.ToolTip = `From {zoneName(egg.Zone)}. Walk to one of your free pads and press E`
	tool:SetAttribute(Constants.Attributes.EggRarity, egg.Rarity)
	tool:SetAttribute(Constants.Attributes.EggZone, egg.Zone)
	local handle = EggModel.create(egg.Rarity, egg.Zone, false)
	handle.Name = "Handle"
	handle.Parent = tool
	return tool
end

local function getBackpack(player: Player): Backpack?
	local backpack = player:FindFirstChildOfClass("Backpack")
	return backpack
end

-- Make the Tools in the backpack match the server's inventory list.
local function rebuildTools(player: Player)
	local backpack = getBackpack(player)
	if not backpack then
		return
	end
	local containers: { Instance } = { backpack }
	if player.Character then
		table.insert(containers, player.Character)
	end
	for _, container in containers do
		for _, item in container:GetChildren() do
			if isEggTool(item) then
				item:Destroy()
			end
		end
	end
	local list: { InventoryEgg } = inventories[player] or {}
	for _, egg in list do
		makeEggTool(egg).Parent = backpack
	end
end

local function updateCount(player: Player)
	player:SetAttribute(Constants.Attributes.EggCount, #(inventories[player] or {}))
end

function EggService.GetInventory(player: Player): { InventoryEgg }
	local result: { InventoryEgg } = {}
	local list: { InventoryEgg } = inventories[player] or {}
	for _, egg in list do
		table.insert(result, { Rarity = egg.Rarity, Zone = egg.Zone })
	end
	return result
end

function EggService.SetInventory(player: Player, eggs: { InventoryEgg })
	local list: { InventoryEgg } = {}
	for _, egg in eggs do
		if Rarity.rank(egg.Rarity) > 0 and Config.Zones[egg.Zone] and #list < Config.Eggs.MaxInventory then
			table.insert(list, { Rarity = egg.Rarity, Zone = egg.Zone })
		end
	end
	inventories[player] = list
	updateCount(player)
	rebuildTools(player)
end

-- Add one egg (and its Tool). False if the inventory is full.
function EggService.AddToInventory(player: Player, rarity: string, zoneIndex: number): boolean
	local list = inventories[player]
	if not list then
		list = {}
		inventories[player] = list
	end
	if #list >= Config.Eggs.MaxInventory then
		return false
	end
	local egg: InventoryEgg = { Rarity = rarity, Zone = zoneIndex }
	table.insert(list, egg)
	updateCount(player)
	local backpack = getBackpack(player)
	if backpack then
		makeEggTool(egg).Parent = backpack
	end
	return true
end

-- Runs a few times per second: a carried egg that reaches the safe zone
-- (the open area in front of the plots, or the plots) goes into the inventory.
local lastFullNotice: { [Player]: number } = {}
local function checkSafeArrivals()
	for player, carry in carrying do
		local root = getRoot(player)
		if root and root.Position.Z > Layout.DangerZoneFront then
			if EggService.AddToInventory(player, carry.Rarity, carry.Zone) then
				takeCarry(player)
				notify(player, `🎒 {carry.Rarity} Egg added to your hotbar! Equip it and press E on a free pad.`, "success")
				-- Celebration on the player's screen (confetti, sound, "SAFE!").
				Net.event(Net.Names.EggSaved):FireClient(player, carry.Rarity)
				EggService.EggDelivered:Fire(player, carry.Rarity)
			else
				local now = os.clock()
				if now - (lastFullNotice[player] or 0) > FULL_NOTICE_COOLDOWN then
					lastFullNotice[player] = now
					notify(player, `Your egg inventory is full ({Config.Eggs.MaxInventory})! Place some eggs on your pads first.`, "warning")
				end
			end
		end
	end
end

-- The "Place Egg" prompt on a pad was used.
local placeLimiter = RateLimiter.new(4, 1)
local function onPadPrompt(player: Player, plot: Types.PlotInfo, padIndex: number)
	if not placeLimiter.allow(player) or plot.Owner ~= player then
		return
	end
	local character = player.Character
	local tool = character and character:FindFirstChildOfClass("Tool")
	if not (tool and isEggTool(tool)) then
		notify(player, "Equip an egg from your hotbar first!", "warning")
		return
	end
	local rarity = tool:GetAttribute(Constants.Attributes.EggRarity)
	local zoneIndex = tool:GetAttribute(Constants.Attributes.EggZone)
	local list: { InventoryEgg } = inventories[player] or {}
	-- Find this egg in the server's list (never trust the Tool alone).
	local index: number? = nil
	for i, egg in list do
		if egg.Rarity == rarity and egg.Zone == zoneIndex then
			index = i
			break
		end
	end
	if not index then
		tool:Destroy() -- a Tool the server doesn't know about: remove it
		return
	end
	-- Close enough to the pad?
	local root = getRoot(player)
	local pad = plot.Pads[padIndex]
	if not (root and pad) or (root.Position - pad.Position).Magnitude > 14 then
		return
	end
	local egg = list[index]
	if PetService.PlaceEggOnPad(player, padIndex, egg.Rarity, egg.Zone) then
		table.remove(list, index)
		tool:Destroy()
		updateCount(player)
		notify(player, `{egg.Rarity} Egg placed! It hatches when the timer runs out.`, "success")
	else
		notify(player, "That pad isn't free!", "warning")
	end
end

---------------------------------------------------------------------------
-- Lifecycle
---------------------------------------------------------------------------

local function watchCharacter(player: Player, character: Model)
	local humanoid = character:WaitForChild("Humanoid", 10)
	if humanoid and humanoid:IsA("Humanoid") then
		humanoid.Died:Connect(function()
			EggService.DropEgg(player, "died")
		end)
	end
end

local function watchPlayer(player: Player)
	player.CharacterAdded:Connect(function(character)
		watchCharacter(player, character)
		-- A new character gets a new, empty backpack: give the eggs back.
		task.wait(0.1)
		player:WaitForChild("Backpack", 5)
		rebuildTools(player)
	end)
	-- If the character disappears without dying (for example, a respawn),
	-- the egg goes with it.
	player.CharacterRemoving:Connect(function()
		EggService.DropEgg(player, "respawned")
	end)
	if player.Character then
		task.spawn(watchCharacter, player, player.Character)
	end
end

function EggService.Init()
	for zoneIndex in Config.Zones do
		zoneEggs[zoneIndex] = {}
	end
end

function EggService.Start()
	eggsFolder = Instance.new("Folder")
	eggsFolder.Name = "Eggs"
	eggsFolder.Parent = WorldService.GetFolder()

	Players.PlayerAdded:Connect(watchPlayer)
	for _, player in Players:GetPlayers() do
		watchPlayer(player)
	end
	PlayerLifecycle.onLeave(function(player)
		takeCarry(player) -- a carried (not yet safe) egg is simply removed
		inventories[player] = nil
		lastFullNotice[player] = nil
	end)

	PetService.PadPromptTriggered:Connect(onPadPrompt)

	DebugCommands.register("egg", function(player, args)
		local wanted = args[1] or "common"
		for _, info in Config.Rarities do
			if string.lower(info.Name) == wanted then
				local zoneIndex = tonumber(args[2]) or Fish.likelyZone(info.Name)
				zoneIndex = math.clamp(math.floor(zoneIndex), 1, #Config.Zones)
				if not EggService.AddToInventory(player, info.Name, zoneIndex) then
					notify(player, "[Studio] Your egg inventory is full!", "warning")
				end
				return
			end
		end
	end)

	-- Fill every zone right away, then keep topping them up.
	for zoneIndex, zone in Config.Zones do
		for _ = 1, zone.MaxEggs do
			spawnEggInZone(zoneIndex)
		end
	end
	task.spawn(function()
		while true do
			task.wait(Config.Eggs.RespawnInterval)
			for zoneIndex in Config.Zones do
				spawnEggInZone(zoneIndex)
			end
		end
	end)

	local elapsed = 0
	RunService.Heartbeat:Connect(function(dt)
		elapsed += dt
		if elapsed >= SAFE_CHECK_INTERVAL then
			elapsed = 0
			checkSafeArrivals()
		end
	end)
end

return EggService
