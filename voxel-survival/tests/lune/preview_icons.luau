-- Dev tool: dumps every item icon to a raw RGBA sheet (scratch use, not a test).
local fs = require("@lune/fs")
local process = require("@lune/process")
local Loader = require("./Loader")
Loader.globals.Vector3 = (require("@lune/roblox") :: any).Vector3
local IR = Loader.require("src/shared/Items/ItemRegistry")
local Gen = Loader.require("src/shared/Items/ItemIconGen")
local out = process.args[1]
local list = {}
for _, d in IR.list() do
	if not d.block or d.icon then table.insert(list, d) end
end
local cols = 12
local rows = math.ceil(#list / cols)
local W, H = cols * 18, rows * 18
local sheet = buffer.create(W * H * 4)
for i = 0, W * H - 1 do buffer.writeu32(sheet, i * 4, 0xFF6B6B6B) end
local names = {}
for i, d in list do
	local img = Gen.generate(d)
	local cx, cy = ((i - 1) % cols) * 18 + 1, ((i - 1) // cols) * 18 + 1
	for y = 0, 15 do for x = 0, 15 do
		local o = (y * 16 + x) * 4
		if buffer.readu8(img, o + 3) > 0 then
			buffer.writeu32(sheet, ((cy + y) * W + cx + x) * 4, buffer.readu32(img, o))
		end
	end end
	table.insert(names, d.key)
end
fs.writeFile(out .. ".raw", buffer.tostring(sheet))
fs.writeFile(out .. ".txt", W .. " " .. H .. "\n" .. table.concat(names, "\n"))
