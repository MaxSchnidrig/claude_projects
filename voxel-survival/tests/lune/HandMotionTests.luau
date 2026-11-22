--!nocheck
local Loader = require("./Loader")
local Fake = require("./FakeRoblox")
return function(test, eq)
	test("hand actions: distinct strokes, mirrored eating, shoulder replication, cancel and expiry", function()
		local G = Fake.newGame()
		for k, val in G.env do Loader.globals[k] = val end
		Fake.mount(G.game:GetService("ReplicatedStorage"), "Shared", Loader.node("src/shared"))
		local remote = Fake.Instance.new("RemoteEvent")
		Loader.stubs["src/shared/Net/Remotes.luau"] = { get = function() return remote end }
		local motion = Loader.require("src/shared/Gameplay/HandMotion")
		local animator = Loader.require("src/client/Player/ActionAnimator")
		local me = Fake.newCharacter("Me", Fake.CFrame.identity)
		me.Parent = G.workspace
		G.player.Character = me
		local other = Fake.newCharacter("ObserverTarget", Fake.CFrame.identity)
		other.Parent = G.workspace
		local function changed(cf)
			return (cf.Position.Magnitude > 0.0001 or (cf.LookVector - Fake.CFrame.identity.LookVector).Magnitude > 0.0001)
		end
		for _, action in { "slash", "scoop", "chop", "jab", "eat", "drink" } do
			local duration = motion.duration[action]
			assert(changed(motion.pose(action, duration*0.49, false)), action)
			assert(not changed(motion.pose(action, duration, false)), action)
		end
		eq(motion.stroke("shovel"), "scoop")
		eq(motion.stroke("sword"), "slash")
		local slash = motion.pose("slash", 0.2, false)
		local scoop = motion.pose("scoop", 0.2, false)
		assert((slash.Position - scoop.Position).Magnitude > 0.3)
		animator.init()
		animator.start("eat", true)
		G.frame(0.45)
		assert(changed(me.Torso["Left Shoulder"].C0))
		assert(not changed(me.Torso["Right Shoulder"].C0))
		assert(animator.view(true).Position.X > 0)
		animator.start("stop")
		assert(not changed(me.Torso["Left Shoulder"].C0))
		remote.OnClientEvent:Fire(other, "slash", false)
		G.frame(0.17)
		assert(changed(other.Torso["Right Shoulder"].C0))
		G.frame(0.3)
		assert(not changed(other.Torso["Right Shoulder"].C0))
		Loader.stubs["src/shared/Net/Remotes.luau"] = nil
		Loader.forget("src/client/Player/ActionAnimator")
		for k in G.env do Loader.globals[k] = nil end
	end)
end
