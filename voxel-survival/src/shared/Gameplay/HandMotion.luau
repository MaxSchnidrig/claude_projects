--!strict
-- Hand-authored poses. Translation is camera-local; shoulder angles are torso-local.
local HandMotion = {}
HandMotion.duration = { slash = 0.38, scoop = 0.46, chop = 0.43, jab = 0.30, eat = 1.6, drink = 1.6 }
local function smooth(t: number): number
	t = math.clamp(t, 0, 1)
	return t * t * (3 - 2 * t)
end
local function pulse(t: number, start: number, peak: number, stop: number): number
	return if t < peak then smooth((t - start) / (peak - start)) else 1 - smooth((t - peak) / (stop - peak))
end
function HandMotion.stroke(tool: string?): string
	if tool == "sword" then return "slash" end
	if tool == "shovel" or tool == "hoe" then return "scoop" end
	if tool == "axe" or tool == "pickaxe" then return "chop" end
	return "jab"
end
function HandMotion.pose(action: string, elapsed: number, left: boolean): (CFrame, CFrame)
	local duration = (HandMotion.duration :: {[string]: number})[action]
	if not duration or elapsed <= 0 or elapsed >= duration then return CFrame.identity, CFrame.identity end
	local t = elapsed / duration
	local wind = pulse(t, 0, 0.22, 0.52)
	local hit = pulse(t, 0.22, 0.54, 1)
	local x, y, z, pitch, yaw, roll, lift, inward, side = 0, 0, 0, 0, 0, 0, 0, 0, 0
	if action == "slash" then
		x, y, z = 0.18*wind - 0.75*hit, 0.20*wind + 0.10*hit, -0.38*hit
		pitch, yaw, roll = 23*wind - 16*hit, -22*wind + 36*hit, -24*wind + 48*hit
		lift, inward, side = 68*wind + 77*hit, -18*wind + 37*hit, 32*wind - 19*hit
	elseif action == "scoop" then
		local scoop = pulse(t, 0.47, 0.72, 1)
		x, y, z = -0.22*hit, 0.12*wind - 0.30*hit + 0.28*scoop, -0.55*hit
		pitch, yaw, roll = 20*wind - 44*hit + 20*scoop, 12*scoop, 24*scoop
		lift, inward, side = 36*wind + 46*hit + 36*scoop, 12*scoop, 13*wind
	elseif action == "chop" then
		x, y, z = -0.18*hit, 0.46*wind - 0.17*hit, -0.51*hit
		pitch, roll = 44*wind - 48*hit, -14*wind + 10*hit
		lift, side = 108*wind + 46*hit, 16*wind
	elseif action == "jab" then
		x, z, pitch, lift = -0.14*hit, 0.10*wind - 0.5*hit, -18*hit, 70*hit
	else
		local raised = smooth(t/0.22) * (1 - smooth((t-0.86)/0.14))
		local bite = if action == "eat" then pulse(t,0.23,0.32,0.41) + pulse(t,0.43,0.53,0.62) + pulse(t,0.64,0.76,0.85) else 0
		x, y, z = -0.75*raised, 0.60*raised + 0.09*bite, 0.62*raised + 0.08*bite
		pitch, yaw, roll = (if action == "drink" then 40 else 12)*raised, 28*raised, -17*raised + 7*bite
		lift, inward, side = 112*raised + 6*bite, 17*raised, -28*raised
	end
	local sign = if left then -1 else 1
	return CFrame.new(sign*x,y,z) * CFrame.Angles(math.rad(pitch), math.rad(sign*yaw), math.rad(sign*roll)),
		CFrame.Angles(math.rad(lift), math.rad(sign*inward), math.rad(sign*side))
end
return HandMotion
