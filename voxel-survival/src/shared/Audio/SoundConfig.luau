--!strict
-- EVERY sound and music track in ROCRAFT, in one place. Swap any of them by changing its `id`.
--
-- Rules: only properly licensed audio — Roblox's own built-in sounds (rbxasset://...), audio from
-- Roblox's licensed Creator Store library (rbxassetid://<number>), CC0 packs uploaded by you, or
-- files you provide. Never another game's sound files or music, edits of them, or recreations of
-- their melodies or signature creature sounds.
--
-- An empty `id` is a placeholder: nothing plays until you fill it in. `search` is what to type in
-- Studio's Toolbox (Audio tab) to find a fitting licensed sound; see SOUNDS.md for the full list.
--
-- Fields: id, volume (0-1), pitch = { min, max } (random each play), search.
-- 3D sounds (blocks, mobs, footsteps) are heard from their position; the rest are 2D.

export type Entry = { id: string, volume: number, pitch: { number }?, search: string }

local E = function(id: string, volume: number, pitchMin: number, pitchMax: number, search: string): Entry
	return { id = id, volume = volume, pitch = { pitchMin, pitchMax }, search = search }
end

local SoundConfig = {}

-- Material groups (BlockDefs `sound`): footsteps, digging hits, breaking and placing.
SoundConfig.materials = { "stone", "wood", "gravel", "grass", "sand", "snow", "glass", "wool", "water", "lava" }

SoundConfig.sounds = {
	-- footsteps (one step about every block walked)
	["step.stone"] = E("", 0.35, 0.9, 1.1, "footstep stone hard"),
	["step.wood"] = E("", 0.35, 0.9, 1.1, "footstep wood plank"),
	["step.gravel"] = E("", 0.35, 0.9, 1.1, "footstep gravel dirt"),
	["step.grass"] = E("", 0.3, 0.9, 1.1, "footstep grass"),
	["step.sand"] = E("", 0.3, 0.9, 1.1, "footstep sand"),
	["step.snow"] = E("", 0.3, 0.9, 1.1, "footstep snow crunch"),
	["step.glass"] = E("", 0.3, 0.9, 1.1, "footstep glass tile"),
	["step.wool"] = E("", 0.3, 0.9, 1.1, "footstep carpet cloth"),
	-- Roblox's own default footstep (ships with the Roblox client): a fallback for every material
	["step.default"] = E("rbxasset://sounds/action_footsteps_plastic.mp3", 0.25, 0.9, 1.1, "(built in)"),

	-- digging hits while mining (quieter, every 4 ticks)
	["dig.stone"] = E("", 0.25, 0.5, 0.6, "stone hit pick chip"),
	["dig.wood"] = E("", 0.25, 0.5, 0.6, "wood hit knock"),
	["dig.gravel"] = E("", 0.25, 0.5, 0.6, "dirt shovel hit"),
	["dig.grass"] = E("", 0.25, 0.5, 0.6, "grass rustle short"),
	["dig.sand"] = E("", 0.25, 0.5, 0.6, "sand shovel"),
	["dig.snow"] = E("", 0.25, 0.5, 0.6, "snow crunch short"),
	["dig.glass"] = E("", 0.25, 0.5, 0.6, "glass tap"),
	["dig.wool"] = E("", 0.25, 0.5, 0.6, "cloth rustle"),

	-- breaking and placing (the same family, like the classic games)
	["break.stone"] = E("", 0.8, 0.8, 1.0, "rock break crumble"),
	["break.wood"] = E("", 0.8, 0.8, 1.0, "wood break crack"),
	["break.gravel"] = E("", 0.8, 0.8, 1.0, "dirt break dig"),
	["break.grass"] = E("", 0.8, 0.8, 1.0, "grass break dig"),
	["break.sand"] = E("", 0.8, 0.8, 1.0, "sand pour dig"),
	["break.snow"] = E("", 0.8, 0.8, 1.0, "snow break crunch"),
	["break.glass"] = E("", 0.9, 0.9, 1.1, "glass shatter small"),
	["break.wool"] = E("", 0.8, 0.8, 1.0, "cloth soft thud"),
	["place.stone"] = E("", 0.8, 0.8, 1.0, "stone place thud"),
	["place.wood"] = E("", 0.8, 0.8, 1.0, "wood place knock"),
	["place.gravel"] = E("", 0.8, 0.8, 1.0, "dirt place thud"),
	["place.grass"] = E("", 0.8, 0.8, 1.0, "grass place"),
	["place.sand"] = E("", 0.8, 0.8, 1.0, "sand place"),
	["place.snow"] = E("", 0.8, 0.8, 1.0, "snow place"),
	["place.glass"] = E("", 0.8, 0.8, 1.0, "glass place clink"),
	["place.wool"] = E("", 0.8, 0.8, 1.0, "cloth place soft"),

	-- liquids and fire
	["water.splash"] = E("rbxasset://sounds/impact_water.mp3", 0.5, 0.9, 1.1, "(built in) water splash"),
	["water.swim"] = E("rbxasset://sounds/action_swim.mp3", 0.3, 0.9, 1.1, "(built in) swim"),
	["lava.pop"] = E("", 0.4, 0.8, 1.2, "lava bubble pop"),
	["lava.ambient"] = E("", 0.25, 0.9, 1.0, "lava ambient bubbling loop"),
	["fire.crackle"] = E("", 0.4, 0.9, 1.1, "fire crackle"),
	["fire.extinguish"] = E("", 0.5, 0.9, 1.1, "fire hiss extinguish"),
	["fire.ignite"] = E("", 0.6, 0.9, 1.1, "lighter flick spark"),
	["fizz"] = E("", 0.5, 0.9, 1.1, "steam hiss short"),
	["bucket.fill"] = E("", 0.6, 0.9, 1.1, "water scoop bucket"),
	["bucket.fill_lava"] = E("", 0.6, 0.9, 1.1, "thick liquid scoop"),
	["bucket.empty"] = E("", 0.6, 0.9, 1.1, "water pour splash"),
	["bucket.empty_lava"] = E("", 0.6, 0.9, 1.1, "thick liquid pour"),
	["tnt.primed"] = E("", 0.8, 0.95, 1.05, "fuse hiss burning"),
	["sand.land"] = E("", 0.5, 0.9, 1.1, "sand thud"),
	["campfire.crackle"] = E("", 0.3, 0.9, 1.1, "campfire crackle loop"),

	-- containers, doors
	["chest.open"] = E("", 0.5, 0.9, 1.0, "wooden chest open creak"),
	["chest.close"] = E("", 0.5, 0.9, 1.0, "wooden chest close"),
	["door.open"] = E("", 0.6, 0.9, 1.0, "wooden door open"),
	["door.close"] = E("", 0.6, 0.9, 1.0, "wooden door close"),
	["furnace.crackle"] = E("", 0.3, 0.9, 1.1, "fireplace crackle"),

	-- player
	["eat"] = E("", 0.5, 0.8, 1.2, "eating bite crunch"),
	["burp"] = E("", 0.5, 0.9, 1.1, "burp short"),
	["hurt"] = E("", 0.7, 0.9, 1.1, "player hurt grunt"),
	["fall.small"] = E("", 0.6, 1.0, 1.0, "body fall thud"),
	["fall.big"] = E("", 0.8, 1.0, 1.0, "heavy fall impact"),
	["jump"] = E("rbxasset://sounds/action_jump.mp3", 0.15, 0.9, 1.1, "(built in) jump"),
	["attack.swing"] = E("", 0.3, 0.9, 1.1, "whoosh swing short"),
	["attack.crit"] = E("", 0.6, 0.9, 1.1, "critical hit impact"),
	["item.pickup"] = E("", 0.3, 1.2, 1.8, "pop pickup small"),
	["item.break"] = E("", 0.6, 0.9, 1.1, "tool break snap"),
	["explosion"] = E("", 1.0, 0.8, 1.0, "explosion medium"),

	-- mobs: real animals get real-animal sounds; our own mobs get their own fitting sounds
	["mob.zombie.idle"] = E("", 0.5, 0.8, 1.2, "zombie groan"),
	["mob.zombie.hurt"] = E("", 0.6, 0.8, 1.2, "zombie hurt"),
	["mob.zombie.death"] = E("", 0.6, 0.8, 1.2, "zombie death"),
	["mob.skeleton.idle"] = E("", 0.5, 0.8, 1.2, "bones rattle"),
	["mob.skeleton.hurt"] = E("", 0.6, 0.8, 1.2, "bones hit"),
	["mob.skeleton.death"] = E("", 0.6, 0.8, 1.2, "bones collapse"),
	["mob.skeleton.shoot"] = E("", 0.6, 0.8, 1.2, "bow shoot arrow"),
	["mob.spider.idle"] = E("", 0.5, 0.8, 1.2, "spider hiss"),
	["mob.spider.hurt"] = E("", 0.6, 0.8, 1.2, "insect screech short"),
	["mob.spider.death"] = E("", 0.6, 0.8, 1.2, "insect death"),
	-- Sneaker: a dry, ashy crackle while it fuses (its own sound, not a hiss)
	["mob.sneaker.fuse"] = E("", 0.8, 0.95, 1.05, "embers crackle fuse sizzle"),
	["mob.sneaker.hurt"] = E("", 0.6, 0.8, 1.2, "rock crack hit"),
	["mob.sneaker.death"] = E("", 0.6, 0.8, 1.2, "rock crumble"),
	-- Voidling: crystalline, glassy tones
	["mob.voidling.idle"] = E("", 0.5, 0.8, 1.2, "crystal chime ambient"),
	["mob.voidling.hurt"] = E("", 0.6, 0.8, 1.2, "crystal hit"),
	["mob.voidling.death"] = E("", 0.7, 0.8, 1.0, "crystal shatter"),
	["mob.voidling.teleport"] = E("", 0.6, 0.9, 1.1, "warp whoosh"),
	["mob.voidling.angry"] = E("", 0.7, 0.9, 1.1, "eerie scream synth"),
	["mob.cow.idle"] = E("", 0.5, 0.8, 1.2, "cow moo"),
	["mob.cow.hurt"] = E("", 0.6, 0.8, 1.2, "cow moo short"),
	["mob.pig.idle"] = E("", 0.5, 0.8, 1.2, "pig oink"),
	["mob.pig.hurt"] = E("", 0.6, 0.8, 1.2, "pig squeal"),
	["mob.sheep.idle"] = E("", 0.5, 0.8, 1.2, "sheep baa"),
	["mob.sheep.hurt"] = E("", 0.6, 0.8, 1.2, "sheep baa short"),
	["mob.chicken.idle"] = E("", 0.5, 0.8, 1.2, "chicken cluck"),
	["mob.chicken.hurt"] = E("", 0.6, 0.8, 1.2, "chicken squawk"),
	["mob.arrow.hit"] = E("", 0.5, 0.9, 1.2, "arrow hit wood thunk"),
}

-- Calm ambient piano-style music, played now and then with long silences (Java-like pacing:
-- 10-20 minutes between tracks, the first one 1-3 minutes after joining).
SoundConfig.music = {
	volume = 0.35,
	firstDelay = { 60, 180 },
	gap = { 600, 1200 },
	tracks = {
		{ id = "", name = "Calm 1", search = "calm ambient piano" },
		{ id = "", name = "Calm 2", search = "peaceful piano ambient" },
		{ id = "", name = "Calm 3", search = "relaxing piano soft" },
		{ id = "", name = "Calm 4", search = "ambient piano gentle" },
		{ id = "", name = "Night", search = "night ambient piano slow" },
	},
}

function SoundConfig.get(name: string): Entry?
	return SoundConfig.sounds[name]
end

return SoundConfig
