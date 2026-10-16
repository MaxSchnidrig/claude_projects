--!strict
--[[
	Effects
	=======
	Small visual effects in the 3D world, shown only on YOUR screen.

	Usage:
		Effects.burst(position, color, 30)   -- a sparkly particle burst
]]

local Debris = game:GetService("Debris")
local TweenService = game:GetService("TweenService")
local Workspace = game:GetService("Workspace")

local Effects = {}

local MAX_DISTANCE = 200 -- don't bother with effects this far from the camera

function Effects.burst(position: Vector3, color: Color3, count: number)
	local camera = Workspace.CurrentCamera
	if camera and (camera.CFrame.Position - position).Magnitude > MAX_DISTANCE then
		return
	end

	local anchor = Instance.new("Part")
	anchor.Anchored = true
	anchor.CanCollide = false
	anchor.CanQuery = false
	anchor.CanTouch = false
	anchor.Transparency = 1
	anchor.Size = Vector3.one
	anchor.Position = position
	anchor.Parent = Workspace

	local emitter = Instance.new("ParticleEmitter")
	emitter.Color = ColorSequence.new(color, Color3.new(1, 1, 1))
	emitter.LightEmission = 1
	emitter.Lifetime = NumberRange.new(0.6, 1.2)
	emitter.Speed = NumberRange.new(10, 20)
	emitter.SpreadAngle = Vector2.new(180, 180)
	emitter.Size = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.8),
		NumberSequenceKeypoint.new(1, 0),
	})
	emitter.Rate = 0
	emitter.Parent = anchor
	emitter:Emit(count)

	local flash = Instance.new("PointLight")
	flash.Color = color
	flash.Range = 18
	flash.Brightness = 6
	flash.Parent = anchor
	TweenService:Create(flash, TweenInfo.new(0.8), { Brightness = 0 }):Play()

	Debris:AddItem(anchor, 2)
end

return Effects
