-- Dev tool: Phase 9e icons (dyes flat, wool / carpet / stained glass 3D, panes flat) into a raw sheet.
local fs = require("@lune/fs")
local process = require("@lune/process")
local Loader = require("./Loader")
Loader.globals.Vector3 = (require("@lune/roblox") :: any).Vector3
local IR = Loader.require("src/shared/Items/ItemRegistry")
local Gen = Loader.require("src/shared/Items/ItemIconGen")
local BIG = Loader.require("src/shared/Items/BlockIconGen")
local out = process.args[1]
local C = { "white","orange","magenta","light_blue","yellow","lime","pink","gray","light_gray","cyan","purple","blue","brown","green","red","black" }
local S = 64
local rows = { "dye", "wool", "carpet", "stained_glass", "stained_glass_pane" }
local W, H = 16 * (S + 4), #rows * (S + 4)
local sheet = buffer.create(W * H * 4)
for i = 0, W * H - 1 do buffer.writeu32(sheet, i * 4, 0xFF8B8B8B) end
for r, suffix in rows do
	for i, c in C do
		local def = IR.get(`{c}_{suffix}`)
		local shape = BIG.shapeForItem(def)
		local img, size
		if shape then img, size = BIG.render(def.block, shape), S else img, size = Gen.generate(def), 16 end
		local scale = S // size
		local ox, oy = (i - 1) * (S + 4) + 2, (r - 1) * (S + 4) + 2
		for y = 0, S - 1 do for x = 0, S - 1 do
			local o = ((y // scale) * size + x // scale) * 4
			if buffer.readu8(img, o + 3) > 0 then buffer.writeu32(sheet, ((oy + y) * W + ox + x) * 4, buffer.readu32(img, o)) end
		end end
	end
end
fs.writeFile(out .. ".raw", buffer.tostring(sheet))
fs.writeFile(out .. ".txt", W .. " " .. H)
