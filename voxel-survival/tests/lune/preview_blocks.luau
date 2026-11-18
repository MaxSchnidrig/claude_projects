-- Dev tool: 3D block icons into a raw sheet (scratch use).
local fs = require("@lune/fs")
local process = require("@lune/process")
local Loader = require("./Loader")
Loader.globals.Vector3 = (require("@lune/roblox") :: any).Vector3
local IR = Loader.require("src/shared/Items/ItemRegistry")
local BIG = Loader.require("src/shared/Items/BlockIconGen")
local out = process.args[1]
local list = {}
for _, d in IR.list() do
	if BIG.shapeForItem(d) then table.insert(list, d) end
end
local S = BIG.SIZE
local cols = 12
local rows = math.ceil(#list / cols)
local W, H = cols * (S + 4), rows * (S + 4)
local sheet = buffer.create(W * H * 4)
for i = 0, W * H - 1 do buffer.writeu32(sheet, i * 4, 0xFF8B8B8B) end
local t0 = os.clock()
for i, d in list do
	local img = BIG.render(d.block, BIG.shapeForItem(d))
	local cx, cy = ((i - 1) % cols) * (S + 4) + 2, ((i - 1) // cols) * (S + 4) + 2
	for y = 0, S - 1 do for x = 0, S - 1 do
		local o = (y * S + x) * 4
		if buffer.readu8(img, o + 3) > 0 then
			buffer.writeu32(sheet, ((cy + y) * W + cx + x) * 4, buffer.readu32(img, o))
		end
	end end
end
print(#list, "icons in", os.clock() - t0)
fs.writeFile(out .. ".raw", buffer.tostring(sheet))
fs.writeFile(out .. ".txt", W .. " " .. H)
