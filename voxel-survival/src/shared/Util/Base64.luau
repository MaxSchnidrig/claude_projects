--!strict
-- Base64 (RFC 4648, with padding). DataStores only store valid UTF-8 text, so binary chunk diffs
-- are encoded with this before saving.

local Base64 = {}

local ALPHABET = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
local enc: { string } = {}
local dec: { [number]: number } = {}
for i = 1, 64 do
	local c = string.sub(ALPHABET, i, i)
	enc[i - 1] = c
	dec[string.byte(c)] = i - 1
end

function Base64.encode(data: string): string
	local out = table.create(math.ceil(#data / 3) * 4)
	local n = #data
	for i = 1, n, 3 do
		local a, b, c = string.byte(data, i, i + 2)
		local v = a * 65536 + (b or 0) * 256 + (c or 0)
		out[#out + 1] = enc[bit32.rshift(v, 18)]
		out[#out + 1] = enc[bit32.band(bit32.rshift(v, 12), 63)]
		out[#out + 1] = if b then enc[bit32.band(bit32.rshift(v, 6), 63)] else "="
		out[#out + 1] = if c then enc[bit32.band(v, 63)] else "="
	end
	return table.concat(out)
end

-- Returns nil for malformed input.
function Base64.decode(text: string): string?
	if #text % 4 ~= 0 then
		return nil
	end
	local out = table.create(#text // 4 * 3)
	for i = 1, #text, 4 do
		local c1, c2, c3, c4 = string.byte(text, i, i + 3)
		local v1, v2 = dec[c1], dec[c2]
		if v1 == nil or v2 == nil then
			return nil
		end
		local v3 = if c3 == 61 then 0 else dec[c3]
		local v4 = if c4 == 61 then 0 else dec[c4]
		if v3 == nil or v4 == nil then
			return nil
		end
		local v = v1 * 262144 + v2 * 4096 + v3 * 64 + v4
		out[#out + 1] = string.char(bit32.rshift(v, 16))
		if c3 ~= 61 then
			out[#out + 1] = string.char(bit32.band(bit32.rshift(v, 8), 255))
		end
		if c4 ~= 61 then
			out[#out + 1] = string.char(bit32.band(v, 255))
		end
	end
	return table.concat(out)
end

return Base64
