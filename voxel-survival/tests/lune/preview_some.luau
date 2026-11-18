-- Dev tool: a few icons, given by key, into a raw sheet (scratch use).
local fs = require("@lune/fs")
local process = require("@lune/process")
local Loader = require("./Loader")
Loader.globals.Vector3 = (require("@lune/roblox") :: any).Vector3
local IR = Loader.require("src/shared/Items/ItemRegistry")
local Gen = Loader.require("src/shared/Items/ItemIconGen")
local out = process.args[1]
local keys = {}
for i = 2, #process.args do table.insert(keys, process.args[i]) end
local W, H = #keys * 18, 18
local sheet = buffer.create(W * H * 4)
for i = 0, W * H - 1 do buffer.writeu32(sheet, i * 4, 0xFF8B8B8B) end
for i, k in keys do
	local img = Gen.generate(IR.get(k))
	for y = 0, 15 do for x = 0, 15 do
		local o = (y * 16 + x) * 4
		if buffer.readu8(img, o + 3) > 0 then
			buffer.writeu32(sheet, ((1 + y) * W + (i - 1) * 18 + 1 + x) * 4, buffer.readu32(img, o))
		end
	end end
end
fs.writeFile(out .. ".raw", buffer.tostring(sheet))
fs.writeFile(out .. ".txt", W .. " " .. H)
