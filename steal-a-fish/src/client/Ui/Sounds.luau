--!strict
--[[
	Sounds
	======
	Plays short sound effects on YOUR computer only (other players don't hear
	your UI sounds). Sound IDs and volumes are in Config.Sounds.

	Usage:
		local Sounds = require(script.Parent.Parent.Ui.Sounds)
		Sounds.play("Pickup")
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local SoundService = game:GetService("SoundService")

local Config = require(ReplicatedStorage.Shared.Config)

local Sounds = {}

local cache: { [string]: Sound } = {}

function Sounds.play(name: string)
	local info = Config.Sounds[name]
	if not info then
		return
	end
	local sound = cache[name]
	if not sound then
		local newSound = Instance.new("Sound")
		newSound.Name = name
		newSound.SoundId = info.Id
		newSound.Volume = info.Volume
		newSound.Parent = SoundService
		cache[name] = newSound
		sound = newSound
	end
	SoundService:PlayLocalSound(sound)
end

return Sounds
