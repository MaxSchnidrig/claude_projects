--!strict
--[[
	Format
	======
	Turns numbers into short, readable text for the UI.

	Usage:
		Format.short(950)         -> "950"
		Format.short(12500)       -> "12.5K"
		Format.short(3400000)     -> "3.4M"
		Format.short(2.5e9)       -> "2.5B"
		Format.decimal(21.347, 1) -> "21.3"
]]

local Format = {}

local SUFFIXES = { "", "K", "M", "B", "T", "Qa", "Qi", "Sx", "Sp", "Oc", "No", "Dc" }

function Format.short(value: number): string
	local sign = if value < 0 then "-" else ""
	local n = math.abs(value)
	if n < 1000 then
		return sign .. tostring(math.floor(n))
	end
	local index = 1
	while n >= 1000 and index < #SUFFIXES do
		n /= 1000
		index += 1
	end
	-- One decimal below 100 (12.5K), none above (125K). Always round DOWN so
	-- we never show more than the player really has.
	local text
	if n < 100 then
		text = string.format("%.1f", math.floor(n * 10) / 10)
		text = (string.gsub(text, "%.0$", ""))
	else
		text = tostring(math.floor(n))
	end
	return sign .. text .. SUFFIXES[index]
end

function Format.decimal(value: number, places: number): string
	return string.format(`%.{places}f`, value)
end

return Format
