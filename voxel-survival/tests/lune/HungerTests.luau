--!nocheck
-- Java parity for hunger, saturation, exhaustion and regeneration (Gameplay/SurvivalRules is a
-- tick-by-tick copy of Java's FoodData). Expected numbers follow the Minecraft Wiki "Food" page
-- (Exhaustion table, Internal variables) and Java's FoodData.tick, worked out tick by tick.
--
-- Usage (from run.luau):  require("./HungerTests")(test, eq)

local Loader = require("./Loader")

return function(test: (string, () -> ()) -> (), eq: (any, any, string?) -> ())
	print("Hunger / saturation / exhaustion (Java FoodData)")
	local SR = Loader.require("src/shared/Gameplay/SurvivalRules")
	local PlayerMotor = Loader.require("src/shared/Gameplay/PlayerMotor")
	local BlockRegistry = Loader.require("src/shared/Blocks/BlockRegistry")
	local ItemRegistry = Loader.require("src/shared/Items/ItemRegistry")
	local Effects = Loader.require("src/shared/Gameplay/Effects")

	local function near(a: number, b: number, eps: number?, what: string?)
		assert(math.abs(a - b) <= (eps or 1e-6), `{what or "value"}: expected {b}, got {a}`)
	end

	-- run FoodData for n ticks at a fixed health (no healing applied) - for exhaustion checks
	local function ticks(h, n: number, health: number?)
		for _ = 1, n do
			SR.tickFood(h, health or 20, 20, "normal")
		end
	end

	test("exhaustion: above 4.0 (not at 4.0) costs a point, one per tick, saturation first; cap 40", function()
		local h = SR.newHunger()
		eq(h.food, 20); eq(h.saturation, 5); eq(h.exhaustion, 0) -- a new life
		SR.addExhaustion(h, 4.0)
		ticks(h, 3)
		eq(h.saturation, 5, "exactly 4.0 isn't above 4.0")
		SR.addExhaustion(h, 0.001)
		ticks(h, 1)
		eq(h.saturation, 4)
		near(h.exhaustion, 0.001)
		-- 4 points at once: one per tick
		SR.addExhaustion(h, 16.5)
		ticks(h, 1)
		eq(h.saturation, 3)
		ticks(h, 10)
		eq(h.saturation, 0, "saturation first")
		eq(h.food, 20)
		SR.addExhaustion(h, 8.5)
		ticks(h, 5)
		eq(h.food, 18, "then hunger")
		-- the cap
		SR.addExhaustion(h, 1000)
		eq(h.exhaustion, 40)
		-- Peaceful: saturation goes, hunger never
		local p = SR.newHunger()
		p.saturation = 1
		SR.addExhaustion(p, 12.5)
		for _ = 1, 5 do
			SR.tickFood(p, 20, 20, "peaceful")
		end
		eq(p.saturation, 0); eq(p.food, 20)
	end)

	test("Java values: every exhaustion source", function()
		local E = SR.EXHAUSTION
		eq(E.sprintPerMeter, 0.1); eq(E.swimPerMeter, 0.01); eq(E.jump, 0.05); eq(E.sprintJump, 0.2)
		eq(E.attack, 0.1); eq(E.damage, 0.1); eq(E.breakBlock, 0.005); eq(E.heal, 6.0); eq(E.hungerEffect, 0.005)
		eq(SR.jumpExhaustion(false), 0.05)
		eq(SR.jumpExhaustion(true), 0.2)
		local ground = { eyeInWater = false, inWater = false, onClimbable = false, onGround = true, sprinting = false }
		eq(SR.movementExhaustion(0.2, 0, 0, ground), 0, "walking costs nothing")
		ground.sprinting = true
		near(SR.movementExhaustion(0.2806, 0, 0, ground), 0.1 * 0.28, 1e-12, "sprinting: whole centimetres")
		local air = { eyeInWater = false, inWater = false, onClimbable = false, onGround = false, sprinting = true }
		eq(SR.movementExhaustion(0.3, 0.2, 0, air), 0, "sprinting in the air costs nothing (Java)")
		local swim = { eyeInWater = true, inWater = true, onClimbable = false, onGround = false, sprinting = false }
		near(SR.movementExhaustion(0.1, 0.1, 0, swim), 0.01 * 0.14, 1e-12, "swimming: 3D distance under water")
		local wade = { eyeInWater = false, inWater = true, onClimbable = false, onGround = true, sprinting = true }
		near(SR.movementExhaustion(0.2, 0.3, 0, wade), 0.01 * 0.2, 1e-12, "wading: horizontal, swim rate")
		-- Hunger I for its 30 s = 3.0 (wiki), Hunger effect per tick per level 0.005
		local list = {}
		Effects.add(list, "hunger", 0, 600)
		local ex = 0
		for _ = 1, 600 do
			Effects.tick(list, {
				health = function() return 20 end, maxHealth = function() return 20 end, hurt = function() end,
				heal = function() end, exhaust = function(n) ex += n end, absorption = function() return 0 end,
			})
		end
		near(ex, 3.0, 1e-9, "Hunger I for 30 s")
	end)

	-- a flat stone floor at y = 64 for the real Java movement code
	local STONE = BlockRegistry.id("stone")
	local world = PlayerMotor.world(function(_x, y, _z)
		return if y < 64 then STONE else 0
	end)
	local function moveExhaustion(r, st, prev, sprint)
		local eye = 1.62
		return SR.movementExhaustion(st.x - prev[1], st.y - prev[2], st.z - prev[3], {
			eyeInWater = r.waterHeight > eye, inWater = r.waterHeight > 0, onClimbable = r.onLadder,
			onGround = st.onGround, sprinting = sprint,
		}) + (if r.jumped then SR.jumpExhaustion(sprint) else 0)
	end

	test("sprint 100 blocks (real Java physics): 0.1 per metre = about 10 exhaustion, saturation 5 -> 3", function()
		local st = PlayerMotor.new(0.5, 64, 0.5)
		for _ = 1, 5 do
			PlayerMotor.tick(st, { forward = 0, strafe = 0, lookX = 0, lookZ = -1, jump = false, sneak = false, sprint = false }, world)
		end
		local h = SR.newHunger()
		local start = st.z
		local n = 0
		while start - st.z < 100 and n < 2000 do
			local prev = { st.x, st.y, st.z }
			local r = PlayerMotor.tick(st, { forward = 1, strafe = 0, lookX = 0, lookZ = -1, jump = false, sneak = false, sprint = true }, world)
			SR.addExhaustion(h, moveExhaustion(r, st, prev, true))
			SR.tickFood(h, 20, 20, "normal")
			n += 1
		end
		local metres = start - st.z
		-- the exhaustion actually added: 0.1 x the distance in whole cm per tick (rounding <= 0.5 cm a tick)
		local used = (5 - h.saturation) * 4 + h.exhaustion
		near(used, 0.1 * metres, n * 0.1 * 0.005, "exhaustion from sprinting")
		eq(h.saturation, 3, "two saturation points used")
		eq(h.food, 20)
		-- Java's sprint speed on flat ground: 0.2806 blocks a tick once up to speed (5.612 m/s)
		assert(n >= 356 and n <= 362, `ticks for 100 blocks: {n}`)
	end)

	test("jump 50 times (real Java physics): 2.5; sprint-jump 50 times: 10.0", function()
		for _, sprint in { false, true } do
			local st = PlayerMotor.new(0.5, 64, 0.5)
			for _ = 1, 5 do
				PlayerMotor.tick(st, { forward = 0, strafe = 0, lookX = 0, lookZ = -1, jump = false, sneak = false, sprint = false }, world)
			end
			local h = SR.newHunger()
			local jumps, total, n = 0, 0, 0
			while jumps < 50 and n < 5000 do
				local prev = { st.x, st.y, st.z }
				-- standing jumps; sprint-jumps run forward (the ground steps between them count too)
				local r = PlayerMotor.tick(st, { forward = if sprint then 1 else 0, strafe = 0, lookX = 0, lookZ = -1, jump = true,
					sneak = false, sprint = sprint }, world)
				if r.jumped then
					jumps += 1
					total += SR.jumpExhaustion(sprint)
				end
				n += 1
			end
			eq(jumps, 50)
			near(total, if sprint then 10.0 else 2.5, 1e-9, if sprint then "sprint-jumps" else "jumps")
			local _ = h
		end
	end)

	test("regen 10 -> 20 HP at full hunger and saturation 20: 100 ticks (5 s), saturation 7 left", function()
		local h = SR.newHunger()
		h.saturation = 20
		local health, t = 10, 0
		while health < 20 and t < 10000 do
			local heal, dmg = SR.tickFood(h, health, 20, "normal")
			health = math.min(20, health + heal - dmg)
			t += 1
		end
		eq(t, 100, "a heart every 10 ticks (saturation boost)")
		eq(h.food, 20)
		eq(h.saturation, 7)
		near(h.exhaustion, 8.0)
	end)

	test("regen of a new player (hunger 20, saturation 5) from 10 HP without eating: stops at 15.5 HP, hunger 17", function()
		local h = SR.newHunger()
		local health = 10
		for _ = 1, 20000 do
			local heal, dmg = SR.tickFood(h, health, 20, "normal")
			health = math.min(20, health + heal - dmg)
		end
		near(health, 15.5, 1e-9, "health")
		eq(h.food, 17, "below 18 natural regeneration stops")
		eq(h.saturation, 0)
		-- slow regeneration: 80 ticks per heart at hunger 18-19
		local s = SR.newHunger()
		s.food, s.saturation = 19, 0
		local hp, first = 10, nil
		for t = 1, 200 do
			local heal = SR.tickFood(s, hp, 20, "normal")
			if heal > 0 and not first then
				first = t
			end
			hp += heal
		end
		eq(first, 80)
		eq(hp, 12)
	end)

	test("starvation: 1 damage every 80 ticks; Easy stops at 10, Normal at 1, Hard kills", function()
		for _, case in { { "easy", 10 }, { "normal", 1 }, { "hard", 0 } } do
			local h = SR.newHunger()
			h.food, h.saturation = 0, 0
			local health, firstHit = 20, nil
			for t = 1, 80 * 25 do
				local _, dmg = SR.tickFood(h, health, 20, case[1])
				if dmg > 0 and not firstHit then
					firstHit = t
				end
				health -= dmg
				if health <= 0 then
					break
				end
			end
			eq(firstHit, 80)
			eq(health, case[2], `starving on {case[1]} ends at`)
		end
		eq(SR.starves(11, "peaceful"), true, "(Java: even on Peaceful above 10 HP)")
		eq(SR.starves(10, "easy"), false)
		-- no starvation, no regen: the timer resets
		local h = SR.newHunger()
		h.food, h.saturation, h.tickTimer = 10, 0, 50
		SR.tickFood(h, 15, 20, "normal")
		eq(h.tickTimer, 0)
	end)

	test("eating: hunger up to 20, saturation up to hunger; sprint needs hunger above 6", function()
		local h = SR.newHunger()
		h.food, h.saturation = 2, 0
		SR.eat(h, 1, 0.6) -- potato: saturation capped by... 3 > 0.6, fine
		eq(h.food, 3); near(h.saturation, 0.6)
		SR.eat(h, 4, 0.8) -- rotten flesh
		eq(h.food, 7); near(h.saturation, 1.4)
		h.food, h.saturation = 2, 0
		SR.eat(h, 2, 3.2) -- spider eye: saturation 3.2 capped at hunger 4? no: 4 >= 3.2
		eq(h.food, 4); near(h.saturation, 3.2)
		h.food, h.saturation = 1, 0
		SR.eat(h, 1, 14.4)
		eq(h.saturation, 2, "never above hunger")
		h.food = 6
		eq(SR.canSprint(h), false)
		h.food = 7
		eq(SR.canSprint(h), true)
	end)

	test("every food: hunger and saturation exactly as the wiki's tables", function()
		local WIKI = {
			apple = { 4, 2.4 }, baked_potato = { 5, 6 }, beetroot = { 1, 1.2 }, beetroot_soup = { 6, 7.2 },
			bread = { 5, 6 }, carrot = { 3, 3.6 }, cooked_chicken = { 6, 7.2 }, cooked_mutton = { 6, 9.6 },
			cooked_porkchop = { 8, 12.8 }, steak = { 8, 12.8 }, golden_apple = { 4, 9.6 },
			enchanted_golden_apple = { 4, 9.6 }, golden_carrot = { 6, 14.4 }, melon_slice = { 2, 1.2 },
			poisonous_potato = { 2, 1.2 }, potato = { 1, 0.6 }, pumpkin_pie = { 8, 4.8 }, raw_beef = { 3, 1.8 },
			raw_chicken = { 2, 1.2 }, raw_mutton = { 2, 1.2 }, raw_porkchop = { 3, 1.8 }, rotten_flesh = { 4, 0.8 },
			spider_eye = { 2, 3.2 },
		}
		for key, v in WIKI do
			local def = ItemRegistry.get(key)
			assert(def and def.food, `{key} is food`)
			eq(def.food.hunger, v[1], `{key} hunger`)
			near(def.food.saturation, v[2], 1e-9, `{key} saturation`)
		end
		-- every food we have is in the table (milk restores nothing)
		for _, def in ItemRegistry.list() do
			if def.food and def.key ~= "milk_bucket" then
				assert(WIKI[def.key], `{def.key} isn't checked against the wiki`)
			end
		end
		-- effects (wiki "Food effects")
		local F = Effects.FOOD
		eq(F.rotten_flesh[1].chance, 0.8); eq(F.rotten_flesh[1].ticks, 600); eq(F.rotten_flesh[1].id, "hunger")
		eq(F.raw_chicken[1].chance, 0.3); eq(F.raw_chicken[1].ticks, 600)
		eq(F.spider_eye[1].id, "poison"); eq(F.spider_eye[1].ticks, 100); eq(F.spider_eye[1].chance, 1)
		eq(F.poisonous_potato[1].chance, 0.6); eq(F.poisonous_potato[1].ticks, 100)
		eq(F.golden_apple[1].ticks, 100); eq(F.golden_apple[1].amp, 1); eq(F.golden_apple[2].ticks, 2400)
		eq(F.enchanted_golden_apple[1].ticks, 400); eq(F.enchanted_golden_apple[4].amp, 3)
		eq(F.enchanted_golden_apple[2].ticks, 6000); eq(F.enchanted_golden_apple[3].ticks, 6000)
	end)
end
