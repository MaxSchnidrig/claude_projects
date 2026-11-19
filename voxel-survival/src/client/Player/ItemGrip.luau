--!strict
local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local Registry = require(Shared.Items.ItemRegistry)
local Meshes = require(script.Parent.Parent.Render.ItemMeshes)
local Grip = {}
-- Full sprite width in avatar studs, grip pixel (origin top-left), thickness, yaw and roll.
local tools = {
	sword={2.7,3,12,0.13,67,-12}, shovel={3,4,11,0.18,65,-13},
	pickaxe={2.7,4,11,0.22,65,-14}, axe={2.4,4,10,0.25,65,-14},
	hoe={2.65,4,9,0.18,65,-14}, fishing_rod={3.5,3,11,0.14,72,-16},
	bow={2.9,5,5,0.16,70,-40}, crossbow={2.4,4,11,0.24,65,-40},
	shears={1.1,6,10,0.13,55,-12}, shield={2.5,8,8,0.18,18,0},
}
local food = {1.05,7,10,0.34,22,8}
local bottle = {1.25,7,10,0.36,15,0}
local bucket = {1.8,7,2,0.72,24,0}
local small = {0.65,7,9,0.16,25,5}
local ordinary = {1.22,7,10,0.19,28,5}
local block = {1.1,7.5,11,1.1,30,0}
local fish = {1.65,5,9,0.26,40,6}
local specific = { bucket=bucket, water_bucket=bucket, lava_bucket=bucket, milk_bucket=bucket,
	glass_bottle=bottle, water_bottle=bottle, crossbow_loaded=tools.crossbow,
	stick={2.1,4,11,0.15,68,-12}, torch={1.8,7,12,0.2,20,0},
	diamond=small, emerald=small, gold_nugget=small, egg=small }
for _, f in require(Shared.Items.Fishing).SPECIES do specific[f.key] = fish end
local function profile(key: string)
	local def = Registry.get(key)
	return specific[key] or (def and def.tool and tools[def.tool.kind])
		or (Meshes.kind(key) == "block" and block)
		or (string.match(key,"^potion_") and bottle) or (string.match(key,"_seeds$") and small)
		or (def and def.food and food) or ordinary
end
function Grip.make(key: string, scale: number)
	local p = profile(key)
	local w = p[1]*scale
	local mesh = Meshes.make(key,w/16,w)
	local part = mesh or Meshes.standIn(key,w/16,w)
	part.Size = Vector3.new(w,w,p[4]*scale)
	return part, mesh ~= nil
end
function Grip.offset(key: string, scale: number, left: boolean): CFrame
	local p = profile(key)
	local pixel = p[1]*scale/16
	local yaw = if left then 180-p[5] else p[5]
	return CFrame.Angles(0,math.rad(yaw),0)*CFrame.Angles(0,0,math.rad(p[6]))
		*CFrame.new((7.5-p[2])*pixel,(p[3]-7.5)*pixel,0)
end
return Grip
