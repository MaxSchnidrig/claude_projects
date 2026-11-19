--!strict
-- The player's own options (Java's Options screen): what exists, the allowed values and the
-- defaults. Pure, shared: the client shows and applies them (Player/Settings), the server checks
-- what a client sends before saving it (Player/SettingsService). Saved per player, not per
-- world (u:<userId>:settings).

local SettingsSchema = {}

export type Def = {
	key: string,
	kind: string, -- "number" | "bool" | "choice"
	min: number?,
	max: number?,
	step: number?,
	choices: { string }?,
	default: any,
}

SettingsSchema.DEFS = {
	-- video
	{ key = "fov", kind = "number", min = 30, max = 110, step = 1, default = 70 },
	{ key = "fovEffects", kind = "number", min = 0, max = 100, step = 5, default = 100 }, -- sprint / bow FOV change
	{ key = "renderDistance", kind = "number", min = 2, max = 12, step = 1, default = 0 }, -- 0 = the device's default
	{ key = "brightness", kind = "number", min = 0, max = 100, step = 5, default = 50 }, -- Java: Moody 0 .. Bright 100
	{ key = "bobbing", kind = "bool", default = true },
	-- controls
	{ key = "sensitivity", kind = "number", min = 0, max = 200, step = 5, default = 100 },
	{ key = "touchLayout", kind = "choice", choices = { "dpad", "joystick" }, default = "dpad" },
	{ key = "touchSensitivity", kind = "number", min = 10, max = 200, step = 5, default = 100 },
	-- sound (percent)
	{ key = "master", kind = "number", min = 0, max = 100, step = 5, default = 100 },
	{ key = "music", kind = "number", min = 0, max = 100, step = 5, default = 100 },
	{ key = "blocks", kind = "number", min = 0, max = 100, step = 5, default = 100 },
	{ key = "hostile", kind = "number", min = 0, max = 100, step = 5, default = 100 },
	{ key = "friendly", kind = "number", min = 0, max = 100, step = 5, default = 100 },
	{ key = "players", kind = "number", min = 0, max = 100, step = 5, default = 100 },
	{ key = "ambient", kind = "number", min = 0, max = 100, step = 5, default = 100 },
} :: { Def }

SettingsSchema.byKey = {} :: { [string]: Def }
for _, d in SettingsSchema.DEFS do
	SettingsSchema.byKey[d.key] = d
end

function SettingsSchema.defaults(): { [string]: any }
	local out = {}
	for _, d in SettingsSchema.DEFS do
		out[d.key] = d.default
	end
	return out
end

-- One value made valid: wrong type or out of range -> the default; numbers snap to the step.
function SettingsSchema.clean(key: string, v: any): any
	local d = SettingsSchema.byKey[key]
	if not d then
		return nil
	end
	if d.kind == "bool" then
		return if typeof(v) == "boolean" then v else d.default
	elseif d.kind == "choice" then
		return if typeof(v) == "string" and table.find(d.choices :: { string }, v) then v else d.default
	end
	if typeof(v) ~= "number" or v ~= v then
		return d.default
	end
	if key == "renderDistance" and v == 0 then
		return 0
	end
	local min, max, step = d.min :: number, d.max :: number, d.step :: number
	v = math.clamp(v, min, max)
	return math.clamp(min + math.floor((v - min) / step + 0.5) * step, min, max)
end

-- A whole table (saved or received): every known key valid, unknown keys dropped.
function SettingsSchema.sanitize(t: any): { [string]: any }
	local out = SettingsSchema.defaults()
	if typeof(t) == "table" then
		for _, d in SettingsSchema.DEFS do
			if t[d.key] ~= nil then
				out[d.key] = SettingsSchema.clean(d.key, t[d.key])
			end
		end
	end
	return out
end

-- Java's FOV labels: 70 "Normal", 110 "Quake Pro".
function SettingsSchema.fovText(v: number): string
	if v == 70 then
		return "Normal"
	elseif v == 110 then
		return "Quake Pro"
	end
	return tostring(v)
end

function SettingsSchema.brightnessText(v: number): string
	if v == 0 then
		return "Moody"
	elseif v == 100 then
		return "Bright"
	end
	return `{v}%`
end

-- Which volume slider a sound belongs to (Java's sound categories).
function SettingsSchema.soundCategory(name: string): string
	if string.sub(name, 1, 4) == "mob." then
		local kind = string.match(name, "^mob%.(%a+)") or ""
		if kind == "cow" or kind == "pig" or kind == "sheep" or kind == "chicken" then
			return "friendly"
		elseif kind == "arrow" then
			return "players"
		end
		return "hostile"
	end
	local head = string.match(name, "^(%a+)") or name
	if head == "step" or head == "eat" or head == "burp" or head == "hurt" or head == "fall" or head == "jump"
		or head == "attack" or head == "item" or head == "shield" or head == "bow" or head == "crossbow"
		or head == "armor" or name == "water.swim" or name == "water.splash"
	then
		return "players"
	elseif name == "lava.ambient" or head == "weather" then
		return "ambient" -- (Java has a separate Weather slider; ours is Ambient)
	end
	return "blocks"
end

return SettingsSchema
