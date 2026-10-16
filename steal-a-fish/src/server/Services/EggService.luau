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
	  - Carrying: the egg floats above the player's head and heavy eggs slow
	    them down (Config.Eggs.ByRarity[...].CarrySpeedMultiplier).
	  - Losing it: being caught by a shark follows Config.Eggs.OnCaught, dying
	    any other way follows Config.Eggs.OnDeath ("Drop" or "Lose").
	  - Delivering: stepping onto your own plot hands the egg to PetService,
	    which puts it on the nearest free pad.

	Public interface:
		EggService.IsCarrying(player) -> boolean
		EggService.GetCarriedRarity(player) -> string?
		EggService.DropEgg(player, reason)     -- reason: "caught", "died", ...
		EggService.EggPickedUp:Connect(function(player, rarity) end)
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
local Build = require(script.Parent.Parent.Util.Build)
local EggVisual = require(script.Parent.Parent.Util.EggVisual)
local PlayerSpeed = require(script.Parent.Parent.Util.PlayerSpeed)
local RateLimiter = require(script.Parent.Parent.Util.RateLimiter)
local PlayerLifecycle = require(script.Parent.Parent.Util.PlayerLifecycle)
local PetService = require(script.Parent.PetService)
local PlotService = require(script.Parent.PlotService)
local WorldService = require(script.Parent.WorldService)

-- An egg lying on the ground in the danger zone.
type GroundEgg = {
	Rarity: string,
	Zone: number,
	Part: BasePart,
	Dropped: boolean, -- true = dropped by a player (temporary, not counted in caps)
	Taken: boolean, -- true once picked up or removed (so it can't be taken twice)
}

-- An egg a player is carrying.
type Carry = {
	Rarity: string,
	Part: BasePart,
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
local lastPadFullNotice: { [Player]: number } = {}

-- Height of an egg's center when it rests on a surface at height `surfaceY`,
-- partly buried (Config.Eggs.VisibleFraction sticks out).
local function restingY(surfaceY: number): number
	return surfaceY + Config.Eggs.Size.Y * (Config.Eggs.VisibleFraction - 0.5)
end

local function notify(player: Player, message: string)
	Net.event(Net.Names.Notify):FireClient(player, message)
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

-- A random free spot in a zone, or nil if no good spot was found.
local function randomSpotInZone(zoneIndex: number): Vector3?
	local cf, size = Layout.zoneCFrameAndSize(zoneIndex)
	local margin = Config.Eggs.SpawnMargin
	local halfX = math.max(size.X / 2 - margin, 0)
	local halfZ = math.max(size.Z / 2 - margin, 0)
	for _ = 1, 10 do
		local offset = CFrame.new(rng:NextNumber(-halfX, halfX), 0, rng:NextNumber(-halfZ, halfZ))
		local spot = (cf * offset).Position
		local position = Vector3.new(spot.X, restingY(Layout.GroundTop), spot.Z)
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
	local part = EggVisual.create(rarity, true)
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

local function attachCarriedEgg(player: Player, rarity: string, root: BasePart)
	local part = EggVisual.create(rarity, false)
	part.Name = "CarriedEgg"
	part.CFrame = root.CFrame * CFrame.new(0, Config.Eggs.CarryHeight, 0)
	local weld = Instance.new("WeldConstraint")
	weld.Part0 = root
	weld.Part1 = part
	weld.Parent = part
	part.Parent = root.Parent

	carrying[player] = { Rarity = rarity, Part = part }
	player:SetAttribute(Constants.Attributes.CarryingEgg, rarity)

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
		notify(player, "You can only carry one egg at a time!")
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
	removeGroundEgg(egg)
	attachCarriedEgg(player, rarity, root)
	notify(player, `You stole a {rarity} Egg! Run back to your plot!`)
	EggService.EggPickedUp:Fire(player, rarity)
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

-- The player loses their egg. reason "caught" follows Config.Eggs.OnCaught;
-- anything else ("died", "respawned", ...) follows Config.Eggs.OnDeath.
-- "Drop" puts the egg on the ground (only inside the danger zone);
-- "Lose" makes it disappear.
function EggService.DropEgg(player: Player, reason: string)
	local root = getRoot(player)
	local position = if root then root.Position else nil
	local carry = takeCarry(player)
	if not carry then
		return
	end

	local rule = if reason == "caught" then Config.Eggs.OnCaught else Config.Eggs.OnDeath
	if rule == "Drop" and position then
		local zoneIndex = Layout.zoneIndexAt(position)
		if zoneIndex then
			local groundPosition = Vector3.new(position.X, restingY(Layout.GroundTop), position.Z)
			createGroundEgg(carry.Rarity, zoneIndex, groundPosition, true)
		end
	end

	if Config.Debug then
		print(`[{Config.GameName}] {player.Name} lost a {carry.Rarity} Egg ({reason})`)
	end
	EggService.EggDropped:Fire(player, carry.Rarity, reason)
end

---------------------------------------------------------------------------
-- Delivery check (runs a few times per second)
---------------------------------------------------------------------------

local DELIVERY_CHECK_INTERVAL = 0.15
local PAD_FULL_NOTICE_COOLDOWN = 3

local function checkDeliveries()
	for player, carry in carrying do
		local plot = PlotService.GetPlot(player)
		local root = getRoot(player)
		-- Anywhere on your own plot counts: the egg goes to the nearest free pad.
		if plot and root and PlotService.GetPlotAt(root.Position) == plot then
			if PetService.AcceptEgg(player, carry.Rarity, root.Position) then
				takeCarry(player)
				notify(player, `{carry.Rarity} Egg placed on a pad!`)
				EggService.EggDelivered:Fire(player, carry.Rarity)
			else
				local now = os.clock()
				if now - (lastPadFullNotice[player] or 0) > PAD_FULL_NOTICE_COOLDOWN then
					lastPadFullNotice[player] = now
					notify(player, "All your pads are full!")
				end
			end
		end
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
		takeCarry(player) -- a leaving player's egg is simply removed
		lastPadFullNotice[player] = nil
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
		if elapsed >= DELIVERY_CHECK_INTERVAL then
			elapsed = 0
			checkDeliveries()
		end
	end)
end

return EggService
