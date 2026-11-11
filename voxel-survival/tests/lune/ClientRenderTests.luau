--!nocheck
-- Runs the REAL src/client/Render/SpecialPartsBackend.luau in a fake Roblox (FakeRoblox.luau)
-- on what the mesher makes of glass, and checks the Parts it creates.
--
-- Usage (from run.luau):  require("./ClientRenderTests")(test, eq)

local Loader = require("./Loader")
local Fake = require("./FakeRoblox")

local Vector3 = Fake.Vector3
local BS = 3 -- Config.BLOCK_SIZE

return function(test: (string, () -> ()) -> (), eq: (any, any, string?) -> ())
	print("Client rendering (real SpecialPartsBackend in a fake Roblox)")

	local function near(a: number, b: number, label: string)
		if math.abs(a - b) > 1e-4 then
			error(`{label}: expected {b}, got {a}`, 2)
		end
	end

	test("client: a glass pane window is one thin sheet per side; glass blocks are unchanged", function()
		local G = Fake.newGame()
		for k, v in G.env do
			Loader.globals[k] = v
		end
		Loader.forget("src/client/")
		Fake.mount(G.game:GetService("ReplicatedStorage"), "Shared", Loader.node("src/shared"))
		local Backend = Loader.require("src/client/Render/SpecialPartsBackend")
		local GreedyMesher = Loader.require("src/shared/Meshing/GreedyMesher")
		local SectionSampler = Loader.require("src/shared/Meshing/SectionSampler")
		local BlockRegistry = Loader.require("src/shared/Blocks/BlockRegistry")
		local PANE, GLASS = BlockRegistry.id("glass_pane"), BlockRegistry.id("glass")
		local P = SectionSampler.SIZE
		local origin = Vector3.new(3000, 480, -6000)

		local function build(cells: { { number } }): ({ any }, any)
			local padded = buffer.create(SectionSampler.BYTES)
			for _, c in cells do
				buffer.writeu16(padded, ((c[1] + 1) + (c[3] + 1) * P + (c[2] + 1) * P * P) * 2, c[4])
			end
			local light = buffer.create(SectionSampler.VOLUME)
			buffer.fill(light, 0, 15)
			local merge = {}
			for tex in BlockRegistry.textureKeys do
				if Backend.isSpecial(tex) then
					merge[tex] = true
				end
			end
			local r = GreedyMesher.meshLit(padded, light, merge)
			local special = {}
			for tex, quads in r.groups do
				if Backend.isSpecial(tex) then
					special[tex] = quads
				end
			end
			local folder = Fake.Instance.new("Folder")
			local handle = Backend.build(special, padded, origin, folder)
			return if handle then handle.parts else {}, handle
		end
		-- the sheet whose thin side is along `axis` ("X", "Y", "Z") and whose centre is nearest `at`
		local function sheets(parts: { any }, axis: string): { any }
			local out = {}
			for _, part in parts do
				local s = part.Size
				if s[axis] < 0.05 and s[axis] == math.min(s.X, s.Y, s.Z) then
					table.insert(out, part)
				end
			end
			return out
		end

		-- a free 3 x 2 window along z at x = 5, y = 4..5, z = 4..6
		local before = Backend.stats.parts
		local parts, handle = build({
			{ 5, 4, 4, PANE }, { 5, 4, 5, PANE }, { 5, 4, 6, PANE },
			{ 5, 5, 4, PANE }, { 5, 5, 5, PANE }, { 5, 5, 6, PANE },
		})
		eq(#parts, 6) -- two big faces, top, bottom, two ends: nothing inside the glass
		eq(Backend.stats.parts - before, 6)
		for _, part in parts do
			eq(part.Transparency, 0.6)
			eq(part.Anchored, true)
			eq(part.CanCollide, false)
			eq(part.CastShadow, false)
		end
		local big = sheets(parts, "X")
		eq(#big, 2)
		table.sort(big, function(a, b)
			return a.Position.X < b.Position.X
		end)
		-- west face at x = 5 + 7/16, east face at 5 + 9/16; each sheet lies just inside the glass
		near(big[1].Position.X - origin.X, (5 + 7 / 16) * BS + 0.002, "west sheet x")
		near(big[2].Position.X - origin.X, (5 + 9 / 16) * BS - 0.002, "east sheet x")
		for _, part in big do
			near(part.Size.X, 0.004, "sheet thickness")
			near(part.Size.Y, 2 * BS + 0.008, "sheet height (2 blocks and a hair)")
			near(part.Size.Z, (2 + 2 / 16) * BS + 0.008, "sheet length (post to post and a hair)")
			near(part.Position.Y - origin.Y, 5 * BS, "sheet centre y")
			near(part.Position.Z - origin.Z, 5.5 * BS, "sheet centre z")
		end
		local top = sheets(parts, "Y")
		eq(#top, 2)
		near(top[1].Size.X, (2 / 16) * BS + 0.008, "edge width")
		Backend.destroy(handle)
		eq(Backend.stats.parts, before)

		-- in a 16-wide row every pane used to bring its own faces; now it is still 6 sheets
		local row = {}
		for z = 0, 15 do
			table.insert(row, { 8, 3, z, PANE })
		end
		parts, handle = build(row)
		eq(#parts, 6)
		Backend.destroy(handle)

		-- a glass block keeps its 6 whole faces with the old thickness
		parts, handle = build({ { 5, 5, 5, GLASS } })
		eq(#parts, 6)
		for _, part in parts do
			near(math.min(part.Size.X, part.Size.Y, part.Size.Z), 0.02, "glass block sheet thickness")
			near(math.max(part.Size.X, part.Size.Y, part.Size.Z), BS, "glass block sheet size")
		end
		Backend.destroy(handle)

		-- a pane against a glass block: 5 pane sheets (no face between them) + the block's 6
		parts, handle = build({ { 5, 5, 5, PANE }, { 6, 5, 5, GLASS } })
		eq(#parts, 11)
		Backend.destroy(handle)
	end)

	-- leave the loader as the other tests expect it
	for _, k in { "game", "workspace", "Instance", "Enum", "CFrame", "Vector2", "Color3", "UDim2", "UDim", "task", "os", "time", "tick", "warn" } do
		Loader.globals[k] = nil
	end
	Loader.forget("src/client/")
end
