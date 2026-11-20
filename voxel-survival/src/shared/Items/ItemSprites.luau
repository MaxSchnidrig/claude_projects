--!strict
-- ROCRAFT's own 16x16 item sprites (original designs). Every non-block item is drawn here so the
-- set shares one look:
--   * a sprite is a silhouette of material letters ("." = empty); the letters are given colours
--     per item (tools and armour reuse one template per kind in every material)
--   * one renderer shades every sprite the same way: light from the top left (exposed top/left
--     edges brighter, bottom/right edges darker), a faint fixed grain inside, and a 1-pixel
--     outline in a dark tint of the colour it surrounds
--   * capital letters are the same material one step darker (details: seams, grooves, holes);
--     "*" is a white glint
-- Output: 16 x 16 RGBA buffers (row 0 at the top), transparent background.

local ItemSprites = {}

type RGB = { number }
export type Sprite = { rows: { string }, colors: { [string]: RGB }, noOutline: boolean? }

-- Shared palette (one place, so materials look the same on every item) ----------------------
local P = {
	wood = { 150, 108, 62 },
	darkWood = { 104, 74, 44 },
	stone = { 132, 132, 136 },
	iron = { 214, 216, 222 },
	gold = { 250, 206, 66 },
	diamond = { 92, 222, 214 },
	leather = { 160, 96, 54 },
	chain = { 150, 156, 168 },
	copper = { 222, 128, 82 },
	string = { 236, 236, 236 },
	flint = { 70, 70, 76 },
	bone = { 232, 228, 210 },
	feather = { 244, 244, 240 },
	paper = { 240, 236, 220 },
	coal = { 52, 50, 54 },
	charcoal = { 72, 60, 52 },
	emerald = { 70, 210, 110 },
	lapis = { 44, 82, 200 },
	redstone = { 214, 54, 44 },
	clay = { 166, 172, 188 },
	snow = { 246, 250, 255 },
	glow = { 90, 230, 200 },
	void = { 60, 210, 170 },
	gunpowder = { 96, 96, 100 },
	sugar = { 246, 246, 250 },
	bonemeal = { 236, 236, 228 },
	water = { 60, 110, 226 },
	lava = { 246, 120, 30 },
	milk = { 250, 250, 248 },
	apple = { 216, 40, 40 },
	leaf = { 70, 150, 50 },
	stem = { 110, 80, 44 },
	carrot = { 244, 140, 30 },
	potato = { 206, 168, 92 },
	baked = { 214, 150, 64 },
	poison = { 176, 196, 82 },
	beet = { 168, 34, 56 },
	bread = { 204, 150, 74 },
	melon = { 226, 60, 52 },
	rind = { 90, 160, 50 },
	pie = { 222, 138, 58 },
	crust = { 214, 176, 112 },
	egg = { 238, 222, 190 },
	rawMeat = { 234, 120, 120 },
	fat = { 248, 226, 220 },
	cooked = { 156, 88, 48 },
	rawChicken = { 240, 196, 170 },
	cookedChicken = { 214, 150, 84 },
	rotten = { 120, 128, 70 },
	spider = { 150, 30, 58 },
	seedLight = { 120, 170, 60 },
	wheat = { 220, 190, 90 },
	pumpkinSeed = { 232, 220, 160 },
	melonSeed = { 46, 34, 26 },
	beetSeed = { 150, 110, 70 },
	bowl = { 130, 90, 52 },
	soup = { 176, 40, 52 },
	red = { 190, 40, 40 },
	ink = { 60, 200, 190 },
	frameWood = { 156, 112, 66 },
	backing = { 120, 74, 44 },
	glowBacking = { 70, 170, 150 },
}
ItemSprites.PALETTE = P

-- Tool / armour tiers (the head or plates; handles are always wood).
ItemSprites.TIERS = {
	wooden = { 168, 128, 76 },
	stone = { 136, 136, 140 },
	iron = P.iron,
	golden = P.gold,
	diamond = P.diamond,
	leather = P.leather,
	chainmail = P.chain,
}

-- Templates ------------------------------------------------------------------------------------
-- (h = handle wood, m = the tier material, others per sprite)

local T: { [string]: { string } } = {}

T.sword = {
	"................",
	"............mmm.",
	"............mMm.",
	"...........mmM..",
	"...........mMm..",
	"..........mmM...",
	".........mmM....",
	"........mmM.....",
	"....g..mmM......",
	"....ggmmM.......",
	".....ggg........",
	"....hg.gg.......",
	"...hh..gg.......",
	"..hh.ggg........",
	".gg.............",
	"................",
}

T.pickaxe = {
	"................",
	"....mmmmmm......",
	"...mmmmmmmmm....",
	"..mm.....mmmm...",
	"..m.......Mmm...",
	"..........hMmm..",
	".........h..mm..",
	"........h...mm..",
	".......h.....m..",
	"......h......m..",
	".....h..........",
	"....h...........",
	"...h............",
	"..h.............",
	".h..............",
	"................",
}

T.axe = {
	"................",
	"......mmm.......",
	".....mmmmm.mm...",
	".....mmmmmmmmm..",
	"......mmmmmhmm..",
	".......mmmh.m...",
	"........mh......",
	".......h........",
	"......h.........",
	".....h..........",
	"....h...........",
	"...h............",
	"..h.............",
	".h..............",
	"................",
	"................",
}

T.shovel = {
	"................",
	".........mmmmmm.",
	".........mMmmmm.",
	".........mmMmmm.",
	"..........mmMm..",
	"..........mmM...",
	".........ggg....",
	"........hh......",
	".......hh.......",
	"......hh........",
	".....hh.........",
	"...ghh..........",
	"..g..g..........",
	".g..g...........",
	"..gg............",
	"................",
}

T.hoe = {
	"................",
	"........mmmmm...",
	".......mmmmmmm..",
	"..........hMm...",
	".........h......",
	"........h.......",
	".......h........",
	"......h.........",
	".....h..........",
	"....h...........",
	"...h............",
	"..h.............",
	".h..............",
	"................",
	"................",
	"................",
}

T.helmet = {
	"................",
	"................",
	"................",
	"....mmmmmmmm....",
	"...mmmmmmmmmm...",
	"...mmMMMMMMmm...",
	"...mm......mm...",
	"...mm......mm...",
	"...mm......mm...",
	"................",
	"................",
	"................",
	"................",
	"................",
	"................",
	"................",
}

T.chestplate = {
	"................",
	"..mmm......mmm..",
	"..mmmm....mmmm..",
	"..mmmmmmmmmmmm..",
	"..mmmmmmmmmmmm..",
	"...mmmmmmmmmm...",
	"....mmmMmmmm....",
	"....mmmMmmmm....",
	"....mmmMmmmm....",
	"....mmmMmmmm....",
	"....mmmmmmmm....",
	"....MMMMMMMM....",
	"................",
	"................",
	"................",
	"................",
}

T.leggings = {
	"................",
	"................",
	"....mmmmmmmm....",
	"....MMMMMMMM....",
	"....mmmmmmmm....",
	"....mmm..mmm....",
	"....mmm..mmm....",
	"....mmm..mmm....",
	"....mmm..mmm....",
	"....mmm..mmm....",
	"....mmm..mmm....",
	"....mmm..mmm....",
	"................",
	"................",
	"................",
	"................",
}

T.boots = {
	"................",
	"................",
	"................",
	"................",
	"................",
	"................",
	"...mmm....mmm...",
	"...mmm....mmm...",
	"...mmm....mmm...",
	"...mmm....mmm...",
	"..mmmm....mmmm..",
	"..MMMM....MMMM..",
	"................",
	"................",
	"................",
	"................",
}

T.ingot = {
	"................",
	"................",
	"................",
	"................",
	"................",
	"......mmmmmmm...",
	".....mmmmmmmmm..",
	"....mmmmmmmmmm..",
	"...mmmmmmmmmm...",
	"..mmmmmmmmmm....",
	"..MMMMMMMMM.....",
	"................",
	"................",
	"................",
	"................",
	"................",
}

T.nugget = {
	"................",
	"................",
	"................",
	"................",
	"................",
	"......mm........",
	".....mmmm.......",
	"....mmmmmm.mm...",
	"....mmMmmmmmmm..",
	".....mmmmmmMmm..",
	"......mm.mmmm...",
	"..........mm....",
	"................",
	"................",
	"................",
	"................",
}

T.gem = {
	"................",
	"................",
	".....mmmmmm.....",
	"....m*mmmmmm....",
	"...m*mmmmmmmm...",
	"..mmmmmmmmmmmm..",
	"..MmmmmmmmmmmM..",
	"...MmmmmmmmmM...",
	"....MmmmmmmM....",
	".....MmmmmM.....",
	"......MmmM......",
	".......MM.......",
	"................",
	"................",
	"................",
	"................",
}

T.lapis = {
	"................",
	"................",
	"................",
	"......mmm.......",
	".....mmmmm......",
	"....mmmMmmm.....",
	"...mmmmmmmmm....",
	"...mmMmmmmmmm...",
	"....mmmmmmMmm...",
	".....mmmmmmm....",
	"......mmmmm.....",
	".......mmm......",
	"................",
	"................",
	"................",
	"................",
}

T.raw = {
	"................",
	"................",
	"................",
	"......mmmm......",
	"....mmmmmmmm....",
	"...mmmMmmmmmm...",
	"...mmmmmmMmmm...",
	"..mmmmmmmmmmmm..",
	"..mmMmmmmmmmmm..",
	"..mmmmmmMmmmm...",
	"...mmmmmmmmm....",
	"....mmmmmmm.....",
	"......mmm.......",
	"................",
	"................",
	"................",
}

T.lump = {
	"................",
	"................",
	"................",
	".......mmm......",
	".....mmmmmm.....",
	"....mmmmmmmmm...",
	"...mmmmMmmmmm...",
	"...mmmmmmmmmmm..",
	"..mmmMmmmmmMmm..",
	"..mmmmmmmmmmmm..",
	"...mmmmmmMmmm...",
	"....mmmmmmmm....",
	".....mmmmmm.....",
	"................",
	"................",
	"................",
}

T.dust = {
	"................",
	"................",
	"................",
	"................",
	"................",
	".......m........",
	"......mmm..m....",
	"....m.mmmm......",
	"...mmmmmmmm.....",
	"..mmmmmmmmmmm...",
	".mmmmmmmmmmmmm..",
	"..MMMMMMMMMMMm..",
	"................",
	"................",
	"................",
	"................",
}

T.stick = {
	"................",
	"................",
	"............mm..",
	"...........mm...",
	"..........mm....",
	".........mm.....",
	"........mm......",
	".......mm.......",
	"......mm........",
	".....mm.........",
	"....mm..........",
	"...mm...........",
	"..mm............",
	"................",
	"................",
	"................",
}

T.string = {
	"................",
	"................",
	"............m...",
	"...........m.m..",
	"..........m.....",
	"..........m.....",
	".........m......",
	"........m.......",
	".......m........",
	"......m.........",
	".....m..........",
	".....m..........",
	"....m...........",
	"..m.m...........",
	"...m............",
	"................",
}

T.feather = {
	"................",
	"............mm..",
	"..........mmmm..",
	".........mmmmm..",
	"........mmmmm...",
	".......mmmmm....",
	"......mmmmm.....",
	".....mmmmm......",
	"....mmmMm.......",
	"....mmMm........",
	"....mMm.........",
	"...ss...........",
	"..s.............",
	".s..............",
	"................",
	"................",
}

T.bone = {
	"................",
	"............mm..",
	"...........mmmm.",
	"...........mmmm.",
	"..........mmmm..",
	".........mmm....",
	"........mmm.....",
	".......mmm......",
	"......mmm.......",
	".....mmm........",
	"....mmm.........",
	"..mmmm..........",
	".mmmm...........",
	".mmmm...........",
	"..mm............",
	"................",
}

T.arrow = {
	"................",
	"...........mmm..",
	"............mm..",
	"...........m.m..",
	"..........s.....",
	".........s......",
	"........s.......",
	".......s........",
	"......s.........",
	".....s..........",
	"....s...........",
	"..fs............",
	"..ff............",
	".f.f............",
	"................",
	"................",
}

-- (drawn from lines below)
T.bow = {}

T.crossbow = {}

T.crossbow_loaded = {}

T.shield = {
	"................",
	"...rrrrrrrrrr...",
	"...rwwwwwwwwr...",
	"...rwwwwwwwwr...",
	"...rwwwRRwwwr...",
	"...rwwwRRwwwr...",
	"...rRRRRRRRRr...",
	"...rwwwRRwwwr...",
	"...rwwwRRwwwr...",
	"...rwwwRRwwwr...",
	"....rwwRRwwr....",
	"....rwwwwwwr....",
	".....rwwwwr.....",
	"......rrrr......",
	"................",
	"................",
}

T.shears = {
	"................",
	"................",
	"...........m....",
	"..........mm....",
	".........mm..m..",
	"........mm..mm..",
	".......mm..mm...",
	"......mmMmmm....",
	".....hh.mm......",
	"....h..h........",
	"....h..h.hh.....",
	".....hh.h..h....",
	"........h..h....",
	".........hh.....",
	"................",
	"................",
}

T.flint_and_steel = {
	"................",
	"................",
	"........mmmm....",
	".......m....m...",
	"......m......m..",
	"......m......m..",
	".......m....m...",
	"........mmmm....",
	"................",
	"...fff..........",
	"..fffff.........",
	"..ffFff.........",
	"..fffff.........",
	"...fff..........",
	"................",
	"................",
}

T.tripwire_hook = {
	"................",
	"................",
	"......mmmm......",
	".....m....m.....",
	".....m....m.....",
	"......mmmm......",
	".......mm.......",
	".......mm.......",
	".......mm.......",
	".......hh.......",
	"......hhhh......",
	"......hhhh......",
	"......hHHh......",
	"......hhhh......",
	"................",
	"................",
}

T.frame = {
	"................",
	".ffffffffffffff.",
	".ffffffffffffff.",
	".ffbbbbbbbbbbff.",
	".ffbbbbbbbbbbff.",
	".ffbbbbbbbbbbff.",
	".ffbbbbbbbbbbff.",
	".ffbbbbbbbbbbff.",
	".ffbbbbbbbbbbff.",
	".ffbbbbbbbbbbff.",
	".ffbbbbbbbbbbff.",
	".ffbbbbbbbbbbff.",
	".ffbbbbbbbbbbff.",
	".ffffffffffffff.",
	".ffffffffffffff.",
	"................",
}

T.bucket = {
	"................",
	"................",
	"....mmmmmmmm....",
	"...m........m...",
	"...mmmmmmmmmm...",
	"...MllllllllM...",
	"...mllllllllm...",
	"....mmmmmmmm....",
	"....mmmmmmmm....",
	"....mmmmmmmm....",
	".....mmmmmm.....",
	".....mmmmmm.....",
	".....MMMMMM.....",
	"................",
	"................",
	"................",
}

T.bucket_empty = {
	"................",
	"................",
	"....mmmmmmmm....",
	"...m........m...",
	"...mmmmmmmmmm...",
	"...mMMMMMMMMm...",
	"...mMMMMMMMMm...",
	"....mmmmmmmm....",
	"....mmmmmmmm....",
	"....mmmmmmmm....",
	".....mmmmmm.....",
	".....mmmmmm.....",
	".....MMMMMM.....",
	"................",
	"................",
	"................",
}

T.bowl = {
	"................",
	"................",
	"................",
	"................",
	"................",
	"................",
	"................",
	"..mmmmmmmmmmmm..",
	"..mMMMMMMMMMMm..",
	"...mmmmmmmmmm...",
	"....mmmmmmmm....",
	".....mmmmmm.....",
	"................",
	"................",
	"................",
	"................",
}

T.soup = {
	"................",
	"................",
	"................",
	"................",
	"................",
	"................",
	"................",
	"..mmmmmmmmmmmm..",
	"..msssssssssSm..",
	"...mmmmmmmmmm...",
	"....mmmmmmmm....",
	".....mmmmmm.....",
	"................",
	"................",
	"................",
	"................",
}

T.fruit = {
	"................",
	"........s.......",
	".......sll......",
	".......s.ll.....",
	"....mmmsmmm.....",
	"...mmmmmmmmm....",
	"..m*mmmmmmmmm...",
	"..m*mmmmmmmmm...",
	"..mmmmmmmmmmm...",
	"..mmmmmmmmmmm...",
	"..mmmmmmmmmMm...",
	"...mmmmmmmMm....",
	"....mmmmmMm.....",
	".....mm.mm......",
	"................",
	"................",
}

T.carrot = {
	"................",
	"...........l.l..",
	"..........llll..",
	"...........ll...",
	"..........mm....",
	".........mmmm...",
	"........mmmMm...",
	".......mmmmm....",
	"......mMmmm.....",
	".....mmmmm......",
	"....mmmMm.......",
	"...mmmm.........",
	"..mmm...........",
	"..m.............",
	"................",
	"................",
}

T.potato = {
	"................",
	"................",
	"................",
	"................",
	"......mmmmm.....",
	"....mmmmmmmmm...",
	"...mmMmmmmmmmm..",
	"..mmmmmmmmMmmm..",
	"..mmmmmmmmmmmm..",
	"..mmmMmmmmmmm...",
	"...mmmmmmmmm....",
	".....mmmmm......",
	"................",
	"................",
	"................",
	"................",
}

T.beetroot = {
	"................",
	"........l.l.....",
	".......llll.....",
	"........ll......",
	"......mmmm......",
	".....mmmmmm.....",
	"....mmmmmmmm....",
	"....mmmmmmMm....",
	"....mmmmmmMm....",
	".....mmmmMm.....",
	"......mmmm......",
	".......mm.......",
	".......m........",
	"................",
	"................",
	"................",
}

T.bread = {
	"................",
	"................",
	"................",
	".......mmm......",
	".....mmmMmmm....",
	"....mmMmmMmmm...",
	"...mmMmmMmmMmm..",
	"..mmmmMmmMmmmmm.",
	"..mmMmmMmmMmmmm.",
	"..mmmMmmMmmmmmm.",
	"...mmmmmmmmmMM..",
	"....mMMMMMMMM...",
	"......MMMM......",
	"................",
	"................",
	"................",
}

T.melon_slice = {
	"................",
	"................",
	"................",
	"................",
	"..rrrrrrrrrrrr..",
	"..wmmmmmmmmmmw..",
	"...wmmkmmkmmw...",
	"....wmmmmmmw....",
	".....wmkmmw.....",
	"......wmmw......",
	".......ww.......",
	"................",
	"................",
	"................",
	"................",
	"................",
}

T.pie = {
	"................",
	"................",
	"................",
	"................",
	"................",
	"................",
	"....mmmmmmmm....",
	"..mmmmmmmmmmmm..",
	".cmmMmmmmmMmmmc.",
	".cccccccccccccc.",
	".cccccccccccccc.",
	"..CCCCCCCCCCCC..",
	"................",
	"................",
	"................",
	"................",
}

T.egg = {
	"................",
	"................",
	"......mmmm......",
	".....mmmmmm.....",
	"....m*mmmmmm....",
	"....m*mmmmmm....",
	"...mmmmmmmmmm...",
	"...mmmmmmmmmm...",
	"...mmmmmmmmmm...",
	"...mmmmmmmmMm...",
	"....mmmmmmMm....",
	".....mmmmMm.....",
	"......mmmm......",
	"................",
	"................",
	"................",
}

T.chop = {
	"................",
	"................",
	"................",
	"......mmmmm.....",
	"....mmmmmmmmm...",
	"...mmmmmmmmmmf..",
	"..mmmmmmmmmmmf..",
	"..mmmmmmMmmmmf..",
	"..mmmmmmmmmmf...",
	"...mmmmmmmmf....",
	"....mmmmmff.....",
	"....bb..........",
	"...bb...........",
	"................",
	"................",
	"................",
}

T.steak = {
	"................",
	"................",
	"................",
	"................",
	".....ffmmmmm....",
	"...ffmmmmmmmmm..",
	"..fmmmmmMmmmmm..",
	"..fmmmmmmmmmmmm.",
	"..fmmMmmmmmMmmm.",
	"...fmmmmmmmmmm..",
	"....ffmmmmmmm...",
	"......fffff.....",
	"................",
	"................",
	"................",
	"................",
}

T.drumstick = {
	"................",
	"................",
	"................",
	"......mmmmm.....",
	".....mmmmmmm....",
	"....mmmmmmmmm...",
	"....mmmmmmMmm...",
	"....mmmmmmMmm...",
	".....mmmmmMm....",
	"......mmmmm.....",
	".....bb.........",
	"....bb..........",
	"..bbbb..........",
	"..bb............",
	"................",
	"................",
}

T.mutton = {
	"................",
	"................",
	"................",
	".......mmmm.....",
	".....mmmmmmmm...",
	"....mmmmmmmmmm..",
	"...fmmmmMmmmmm..",
	"...fmmmmmmmmmm..",
	"...fmmMmmmmmmm..",
	"....fmmmmmmmm...",
	".....ffmmmm.....",
	"........bb......",
	".........bb.....",
	".........bbb....",
	"................",
	"................",
}

T.flesh = {
	"................",
	"................",
	"................",
	"....mmm.........",
	"...mmmmmm.mm....",
	"...mmMmmmmmmm...",
	"....mmmmmMmmmm..",
	"...mmmmmmmmmm...",
	"..mmmMmmmmmm....",
	"..mmmmmmMmmmm...",
	"...mmmmmmmmmmm..",
	".....mm..mmmm...",
	"................",
	"................",
	"................",
	"................",
}

T.eye = {
	"................",
	"................",
	"................",
	"................",
	"......mmmm......",
	"....mmmmmmmm....",
	"...mmmmmmmmmm...",
	"...mmmkkmmmmm...",
	"...mmmkkmmmmm...",
	"...mmmmmmmmmm...",
	"....mmmmmmmm....",
	"......mmmm......",
	"................",
	"................",
	"................",
	"................",
}

T.seeds = {
	"................",
	"................",
	"................",
	"................",
	"................",
	".........m......",
	"....m...mm......",
	"...mm.....m.....",
	"........m.mm....",
	".....mm.mm......",
	"....mm.....m....",
	"..........mm....",
	"......m.........",
	".....mm.........",
	"................",
	"................",
}

T.big_seeds = {
	"................",
	"................",
	"................",
	"................",
	"................",
	"........mm......",
	"....mm..mmm.....",
	"...mmm...m......",
	"....m.......mm..",
	"..........mmm...",
	"......mm...m....",
	".....mmm........",
	"......m.........",
	"................",
	"................",
	"................",
}

T.wheat = {
	"................",
	"...........m.m..",
	"..........mmm...",
	".........mmmm.m.",
	"........mmmmmm..",
	".......m.mmm....",
	"......m.mmm.....",
	".....m.m........",
	"....m.m.........",
	"...m.m..........",
	"..mmm...........",
	".mmm............",
	"..m.............",
	"................",
	"................",
	"................",
}

T.ball = {
	"................",
	"................",
	"................",
	"................",
	"......mmmm......",
	".....mmmmmm.....",
	"....m*mmmmmm....",
	"....m*mmmmmm....",
	"....mmmmmmmm....",
	"....mmmmmmMm....",
	".....mmmmMm.....",
	"......mmmm......",
	"................",
	"................",
	"................",
	"................",
}

T.sac = {
	"................",
	"................",
	"................",
	".......mm.......",
	"......mmmm......",
	".....mmmmmm.....",
	"....mmmmmmmm....",
	"....m*mmmmmm....",
	"...mm*mmmmmmm...",
	"...mmmmmmmmMm...",
	"...mmmmmmmMmm...",
	"....mmmmmmmm....",
	".....mmmmmm.....",
	"................",
	"................",
	"................",
}

T.leather = {
	"................",
	"................",
	"................",
	"...mmm....mmm...",
	"...mmmmmmmmmm...",
	"....mmmmmmmm....",
	"....mmmMmmmm....",
	"...mmmmmmmmmm...",
	"...mmmmmmMmmm...",
	"....mmmmmmmm....",
	"...mmmmmmmmmm...",
	"...mmm....mmm...",
	"................",
	"................",
	"................",
	"................",
}

T.paper = {
	"................",
	"................",
	"...mmmmmmmmmm...",
	"...mMMMMMMMmm...",
	"...mmmmmmmmmm...",
	"...mMMMMMMMmm...",
	"...mmmmmmmmmm...",
	"...mMMMMMMmmm...",
	"...mmmmmmmmmm...",
	"...mMMMMMMMmm...",
	"...mmmmmmmmmm...",
	"...mmmmmmmmm....",
	"...mmmmmmmm.....",
	"................",
	"................",
	"................",
}

-- Book (Phase 10b, our own design): a thick closed book, cover "c", page edges "p",
-- a band "g" around the spine
T.book = {
	"................",
	"................",
	"....cccccccc....",
	"...cCccccccccp..",
	"...cCcccccccpp..",
	"...gGggggggppp..",
	"...cCccccccppp..",
	"...cCccccccppp..",
	"...cCccccccppp..",
	"...cCccccccppp..",
	"...gGgggggpppp..",
	"...cCcccccppp...",
	"...cCccccccpp...",
	"....cccccccc....",
	"................",
	"................",
}

-- Enchanted book (our own design): the same book, a violet cover with a gold star emblem "s"
T.enchanted_book = {
	"................",
	"................",
	"....cccccccc....",
	"...cCccccccccp..",
	"...cCcccccccpp..",
	"...gGggggggppp..",
	"...cCcccsccppp..",
	"...cCccsssfppp..",
	"...cCcccscfppp..",
	"...cCccccccppp..",
	"...gGgggggpppp..",
	"...cCcccccppp...",
	"...cCccccccpp...",
	"....cccccccc....",
	"................",
	"................",
}

T.flint = {
	"................",
	"................",
	"................",
	"........mm......",
	".......mmmm.....",
	"......mmmmmm....",
	".....mmMmmmmm...",
	"....mmmmmmmmm...",
	"....mmmmmMmmm...",
	"...mmmmmmmmm....",
	"...mmmmmmmm.....",
	"....mmmmmm......",
	"................",
	"................",
	"................",
	"................",
}

T.shard = {
	"................",
	"................",
	"........m.......",
	".......mmm......",
	"......mm*mm.....",
	".....mmm*mmm....",
	"....mmmmmmmmm...",
	"...mmmmmmmmmmm..",
	"....mmmmmmmMm...",
	".....mmmmmMm....",
	"......mmmMm.....",
	".......mMm......",
	"........m.......",
	"................",
	"................",
	"................",
}

T.torch = {
	"................",
	"................",
	"................",
	"................",
	".......ff.......",
	"......fFFf......",
	"......fFFf......",
	".......ss.......",
	".......ss.......",
	".......ss.......",
	".......ss.......",
	".......ss.......",
	".......ss.......",
	".......ss.......",
	"................",
	"................",
}

-- Dye (Phase 9e, our own design): a round drop of colour with a highlight.
T.dye = {
	"................",
	"................",
	"................",
	".......m........",
	"......mmm.......",
	".....mmmmm......",
	"....m*mmmmm.....",
	"...mm*mmmmmm....",
	"...mmmmmmmmm....",
	"...mmmmmmmmMm...",
	"...mmmmmmmMMm...",
	"....mmmmmMMm....",
	".....mmmmmm.....",
	"................",
	"................",
	"................",
}

T.enchanted_sparkle = { -- (overlay for the enchanted apple)
	"................",
	"...........*....",
	"..........***...",
	"...........*....",
	"................",
	"................",
	"................",
	"................",
	"................",
	"................",
	"................",
	"................",
	"................",
	"................",
	".*..............",
	"................",
}

-- Line-drawn templates ------------------------------------------------------------------------

local function canvas(): { { string } }
	local g = {}
	for y = 1, 16 do
		g[y] = table.create(16, ".")
	end
	return g
end
local function set(g: { { string } }, x: number, y: number, ch: string)
	if x >= 0 and y >= 0 and x < 16 and y < 16 then
		g[y + 1][x + 1] = ch
	end
end
local function line(g: { { string } }, x0: number, y0: number, x1: number, y1: number, ch: string)
	local n = math.max(math.abs(x1 - x0), math.abs(y1 - y0))
	for i = 0, n do
		local t = if n == 0 then 0 else i / n
		set(g, math.floor(x0 + (x1 - x0) * t + 0.5), math.floor(y0 + (y1 - y0) * t + 0.5), ch)
	end
end
local function rows(g: { { string } }): { string }
	local out = {}
	for y = 1, 16 do
		out[y] = table.concat(g[y])
	end
	return out
end

-- bow: a curved limb bulging to the top left, grip in the middle, a straight string
do
	local g = canvas()
	for y = 0, 15 do
		for x = 0, 15 do
			local d = math.sqrt((x - 14) ^ 2 + (y - 14) ^ 2)
			if d >= 10.6 and d < 12.4 and x <= 13 and y <= 13 then
				set(g, x, y, "w")
			end
		end
	end
	for _, p in { { 5, 5 }, { 6, 4 }, { 4, 6 } } do
		set(g, p[1], p[2], "g") -- grip wrap
	end
	line(g, 13, 2, 2, 13, "s")
	T.bow = rows(g)
end

-- crossbow: a wooden stock from the bottom left, iron limbs across its front, the string
-- pulled back; loaded: an arrow lies along the stock
local function crossbow(loaded: boolean): { string }
	local g = canvas()
	for i = 0, 8 do
		set(g, 2 + i, 13 - i, "w")
		set(g, 3 + i, 13 - i, "w")
	end
	set(g, 1, 14, "W")
	set(g, 2, 14, "W")
	line(g, 6, 2, 14, 10, "i")
	line(g, 7, 2, 14, 9, "i")
	if loaded then
		line(g, 6, 2, 8, 8, "s")
		line(g, 14, 10, 8, 8, "s")
		line(g, 8, 7, 13, 2, "a")
		set(g, 13, 1, "A")
		set(g, 14, 2, "A")
	else
		line(g, 6, 2, 7, 7, "s")
		line(g, 14, 10, 9, 9, "s")
	end
	return rows(g)
end
T.crossbow = crossbow(false)
T.crossbow_loaded = crossbow(true)

-- Items -> sprite ---------------------------------------------------------------------------

local SPRITES: { [string]: Sprite } = {}
ItemSprites.SPRITES = SPRITES

local function add(key: string, rows: { string }, colors: { [string]: RGB })
	SPRITES[key] = { rows = rows, colors = colors }
end

for prefix, c in ItemSprites.TIERS do
	if prefix ~= "leather" and prefix ~= "chainmail" then
		for _, kind in { "sword", "pickaxe", "axe", "shovel", "hoe" } do
			add(`{prefix}_{kind}`, T[kind], { m = c, h = P.wood, g = P.darkWood })
		end
	end
	if prefix ~= "wooden" and prefix ~= "stone" then
		local armorPrefix = if prefix == "golden" then "golden" else prefix
		for _, slot in { "helmet", "chestplate", "leggings", "boots" } do
			add(`{armorPrefix}_{slot}`, T[slot], { m = c })
		end
	end
end

add("iron_ingot", T.ingot, { m = P.iron })
add("gold_ingot", T.ingot, { m = P.gold })
add("copper_ingot", T.ingot, { m = P.copper })
add("gold_nugget", T.nugget, { m = P.gold })
add("diamond", T.gem, { m = P.diamond })
add("emerald", T.gem, { m = P.emerald })
add("lapis_lazuli", T.lapis, { m = P.lapis })
add("raw_iron", T.raw, { m = { 200, 166 , 140 } })
add("raw_gold", T.raw, { m = { 236, 186, 60 } })
add("raw_copper", T.raw, { m = { 200, 112, 76 } })
add("coal", T.lump, { m = P.coal })
add("charcoal", T.lump, { m = P.charcoal })
add("gunpowder", T.dust, { m = P.gunpowder })
add("brewing_stand", {
	"................",
	"....sssssssss...",
	"....ss.....ss...",
	"....gg....cccc..",
	"....gg.....SS...",
	"...gbbg...cccc..",
	"..gbbbbG...SS...",
	".bgBbbbbb.cccc..",
	".bbBbbbbb..SS...",
	"..bbbbbb..gg....",
	"...BBBB...bbg...",
	"..cccccc..bbb...",
	"ssssssssssssssss",
	".SSSSSSSkkllkck.",
	".SSSSSSSkkkkkkk.",
	"................",
}, { s = { 150, 162, 170 }, g = { 210, 237, 240 }, b = { 35, 171, 218 }, c = { 228, 135, 54 }, k = { 44, 49, 54 }, l = { 147, 216, 89 } })
local bottleSprite = {
	"................",
	"......hhhh......",
	"......gggg......",
	".......gg.......",
	".......gg.......",
	"......g..g......",
	".....g....g.....",
	"....g......g....",
	"...gmmmmmmmmg...",
	"...gmGmmmmmmg...",
	"...gmGmmmmmmg...",
	"...gmmmmmmmmg...",
	"....gmmmmmmg....",
	".....gggggg.....",
	"................",
	"................",
}
add("glass_bottle", bottleSprite, { g = { 165, 209, 216 }, h = P.wood, m = { 195, 222, 225 } })
add("water_bottle", bottleSprite, { g = { 165, 209, 216 }, h = P.wood, m = { 63, 145, 226 } })
add("potion_base", bottleSprite, { g = { 165, 209, 216 }, h = P.wood, m = { 153, 147, 182 } })
add("potion_speed", bottleSprite, { g = { 165, 209, 216 }, h = P.wood, m = { 61, 207, 230 } })
add("potion_strength", bottleSprite, { g = { 165, 209, 216 }, h = P.wood, m = { 218, 102, 61 } })
add("potion_regeneration", bottleSprite, { g = { 165, 209, 216 }, h = P.wood, m = { 230, 100, 171 } })
add("sugar", T.dust, { m = P.sugar })
add("bone_meal", T.dust, { m = P.bonemeal })
add("volt_dust", T.dust, { m = P.redstone })
add("stick", T.stick, { m = P.wood })
add("string", T.string, { m = P.string })
add("feather", T.feather, { m = P.feather, s = { 200, 200, 196 } })
add("bone", T.bone, { m = P.bone })
add("arrow", T.arrow, { m = P.flint, s = P.wood, f = P.feather })
add("bow", T.bow, { w = P.wood, s = P.string, g = P.leather })
add("crossbow", T.crossbow, { w = P.wood, i = P.chain, s = P.string })
add("crossbow_loaded", T.crossbow_loaded, { w = P.wood, i = P.chain, s = P.string, a = P.wood, A = P.flint })
add("shield", T.shield, { w = P.wood, r = P.iron, R = { 160, 162, 170 } })
add("shears", T.shears, { m = P.iron, h = P.red })
add("flint_and_steel", T.flint_and_steel, { m = P.iron, f = P.flint })
add("tripwire_hook", T.tripwire_hook, { m = P.iron, h = P.wood })
add("item_frame", T.frame, { f = P.frameWood, b = P.backing })
add("glow_item_frame", T.frame, { f = P.frameWood, b = P.glowBacking })
add("bucket", T.bucket_empty, { m = P.iron })
add("water_bucket", T.bucket, { m = P.iron, l = P.water })
add("lava_bucket", T.bucket, { m = P.iron, l = P.lava })
add("milk_bucket", T.bucket, { m = P.iron, l = P.milk })
add("bowl", T.bowl, { m = P.bowl })
add("beetroot_soup", T.soup, { m = P.bowl, s = P.soup })
add("apple", T.fruit, { m = P.apple, s = P.stem, l = P.leaf })
add("golden_apple", T.fruit, { m = P.gold, s = P.stem, l = P.leaf })
add("enchanted_golden_apple", T.fruit, { m = { 252, 196, 90 }, s = P.stem, l = { 210, 120, 230 } })
add("carrot", T.carrot, { m = P.carrot, l = P.leaf })
add("golden_carrot", T.carrot, { m = P.gold, l = { 230, 220, 120 } })
add("potato", T.potato, { m = P.potato })
add("baked_potato", T.potato, { m = P.baked })
add("poisonous_potato", T.potato, { m = P.poison })
add("beetroot", T.beetroot, { m = P.beet, l = P.leaf })
add("bread", T.bread, { m = P.bread })
add("melon_slice", T.melon_slice, { m = P.melon, r = P.rind, w = { 236, 240, 200 }, k = { 30, 24, 20 } })
add("pumpkin_pie", T.pie, { m = P.pie, c = P.crust })
add("egg", T.egg, { m = P.egg })
add("raw_porkchop", T.chop, { m = P.rawMeat, f = P.fat, b = P.bone })
add("cooked_porkchop", T.chop, { m = P.cooked, f = { 220, 180, 130 }, b = P.bone })
local fishShapes = {
	stream = {
		"................",
		"................",
		"................",
		"................",
		"......f.........",
		".f.....ff.......",
		".ff..mmmmmmm....",
		".ffmmmmmmmmemm..",
		".ffmmmmmmmmmmm..",
		".ffmmmmmmmmmmm..",
		".ff..fffffff....",
		".f..............",
		"................",
		"................",
		"................",
		"................",
	},
	long = {
		"................",
		"................",
		"................",
		"................",
		"................",
		".f....f.........",
		".ff....ffmmm....",
		".fff...mmmmem...",
		".ffmmmmmmmmmmm..",
		".fffffffff...f..",
		".ff..fff........",
		".f..............",
		"................",
		"................",
		"................",
		"................",
	},
	deep = {
		"................",
		"................",
		"................",
		"......f.........",
		".......ff.......",
		".f....mmmmm.....",
		".ff.mmmmmmmmm...",
		".fffmmmmmmmem...",
		".fffmmmmmmmmm...",
		".fffmmmmmmmmm...",
		".ff.fffffffff...",
		".f....fffff.....",
		"................",
		"................",
		"................",
		"................",
	},
	tropical = {
		"................",
		"................",
		"................",
		"......f.........",
		".......ff.......",
		".f....gmmgm.....",
		".ff..mgmmgmm....",
		".fffmmgmmgmem...",
		".fffmmgmmgmmm...",
		".fffmmgmmgmmm...",
		".ff..fffffff....",
		".f....fffff.....",
		"................",
		"................",
		"................",
		"................",
	},
	puffer = {
		"................",
		"................",
		"........f.......",
		".....f....f.....",
		"........m.......",
		".f....mmmmm.....",
		".ff..mmmmmmm....",
		".fffmmmmmmmem...",
		".fffmmmmmmmmm...",
		".fffmmmmmmmmm...",
		".ff..fffffff....",
		".f....fffff.....",
		".....f..f..f....",
		"................",
		"................",
		"................",
	},
}
for _, fish in require(script.Parent.Fishing).SPECIES do
	add(fish.key, fishShapes[fish.shape], { m = fish.color, f = { 166, 178, 142 }, g = { 239, 219, 170 }, e = { 29, 43, 49 } })
end
add("fishing_rod", {
		"................",
		"...........wwww.",
		"..........ww..g.",
		".........ww...g.",
		"........ww....g.",
		".......ww.....g.",
		"......ww......g.",
		".....ww.......g.",
		"....ww........r.",
		"...ww........rrr",
		"..wmm.........g.",
		"..wmm...........",
		".ww.............",
		".ww.............",
		"................",
		"................",
	}, { w = P.wood, m = P.iron, g = { 210, 213, 198 }, r = { 226, 86, 55 } })
add("cooked_fish", T.steak, { m = { 205, 136, 81 }, f = { 237, 192, 125 } })
add("raw_beef", T.steak, { m = { 200, 56, 56 }, f = P.fat })
add("steak", T.steak, { m = { 124, 68, 38 }, f = { 176, 120, 74 } })
add("raw_chicken", T.drumstick, { m = P.rawChicken, b = P.bone })
add("cooked_chicken", T.drumstick, { m = P.cookedChicken, b = P.bone })
add("raw_mutton", T.mutton, { m = { 210, 70, 70 }, f = P.fat, b = P.bone })
add("cooked_mutton", T.mutton, { m = { 140, 76, 46 }, f = { 200, 160, 110 }, b = P.bone })
add("rotten_flesh", T.flesh, { m = P.rotten })
add("spider_eye", T.eye, { m = P.spider, k = { 30, 10, 14 } })
add("wheat_seeds", T.seeds, { m = P.seedLight })
add("beetroot_seeds", T.seeds, { m = P.beetSeed })
add("pumpkin_seeds", T.big_seeds, { m = P.pumpkinSeed })
add("melon_seeds", T.big_seeds, { m = P.melonSeed })
add("wheat", T.wheat, { m = P.wheat })
add("snowball", T.ball, { m = P.snow })
add("clay_ball", T.ball, { m = P.clay })
add("glow_ink_sac", T.sac, { m = P.ink })
add("leather", T.leather, { m = P.leather })
add("paper", T.paper, { m = P.paper })
add("book", T.book, { c = { 132, 70, 40 }, p = P.paper, g = { 196, 150, 70 } })
add("enchanted_book", T.enchanted_book, { c = { 98, 52, 150 }, p = P.paper, g = P.gold, s = { 255, 226, 110 }, f = { 200, 160, 60 } })
add("flint", T.flint, { m = P.flint })
add("void_shard", T.shard, { m = P.void })
add("torch", T.torch, { s = P.wood, f = { 255, 214, 90 }, F = { 255, 160, 40 } })
do
	local DYE = {
		white = { 236, 238, 238 }, orange = { 240, 118, 20 }, magenta = { 190, 68, 180 }, light_blue = { 58, 176, 218 },
		yellow = { 248, 198, 40 }, lime = { 112, 186, 26 }, pink = { 238, 142, 172 }, gray = { 70, 76, 80 },
		light_gray = { 150, 150, 142 }, cyan = { 22, 138, 146 }, purple = { 122, 42, 172 }, blue = { 54, 58, 158 },
		brown = { 114, 72, 40 }, green = { 84, 108, 28 }, red = { 170, 40, 36 }, black = { 40, 40, 46 },
	}
	for c, rgb in DYE do
		add(`{c}_dye`, T.dye, { m = rgb })
	end
end

-- Rendering ------------------------------------------------------------------------------------

local N = 16

local function clamp8(v: number): number
	return math.clamp(math.floor(v + 0.5), 0, 255)
end

-- deterministic grain: -1, 0 or 1 (three levels, so the 3D item meshes can still merge
-- neighbouring pixels of one shade)
local function grain(x: number, y: number): number
	local h = (x * 374761393 + y * 668265263) % 2147483647
	h = (h * 1274126177) % 2147483647
	local r = h % 5
	return if r == 0 then -1 elseif r == 1 then 1 else 0
end

-- Render a sprite to a 16x16 RGBA buffer. `overlay` (optional) draws on top (white glints).
function ItemSprites.render(sprite: Sprite, overlay: { string }?): buffer
	local img = buffer.create(N * N * 4)
	local mat: { [number]: string } = {}
	for y = 0, N - 1 do
		local row = sprite.rows[y + 1] or ""
		for x = 0, N - 1 do
			local ch = string.sub(row, x + 1, x + 1)
			if ch ~= "" and ch ~= "." then
				mat[y * N + x] = ch
			end
		end
	end
	local function at(x: number, y: number): string?
		if x < 0 or y < 0 or x >= N or y >= N then
			return nil
		end
		return mat[y * N + x]
	end
	local function base(ch: string): ({ number }, number)
		if ch == "*" then
			return { 255, 255, 255 }, 1
		end
		local lower = string.lower(ch)
		local c = sprite.colors[ch] or sprite.colors[lower]
		if not c then
			return { 255, 0, 255 }, 1 -- missing colour shows as magenta (the test catches it)
		end
		local dark = if ch ~= lower and sprite.colors[ch] == nil then 0.72 else 1
		return c, dark
	end
	local function same(a: string?, b: string): boolean
		return a ~= nil and string.lower(a) == string.lower(b)
	end
	local colorAt: { [number]: { number } } = {}
	local baseAt: { [number]: { number } } = {} -- unshaded colour (outlines use it)
	for i, ch in mat do
		local x, y = i % N, i // N
		local c, f = base(ch)
		baseAt[i] = { c[1] * f, c[2] * f, c[3] * f }
		if ch ~= "*" then
			-- light from the top left
			local upLeftOpen = not same(at(x, y - 1), ch) or not same(at(x - 1, y), ch)
			local downRightOpen = not same(at(x, y + 1), ch) or not same(at(x + 1, y), ch)
			if upLeftOpen and not downRightOpen then
				f *= 1.2
			elseif downRightOpen and not upLeftOpen then
				f *= 0.78
			end
			f *= 1 + grain(x, y) * 0.04
		end
		local col = { c[1] * f, c[2] * f, c[3] * f }
		-- highlights also lift toward white a little (keeps dark materials readable)
		if f > 1.1 then
			col = { col[1] + (255 - col[1]) * 0.12, col[2] + (255 - col[2]) * 0.12, col[3] + (255 - col[3]) * 0.12 }
		end
		colorAt[i] = col
		local o = i * 4
		buffer.writeu8(img, o, clamp8(col[1]))
		buffer.writeu8(img, o + 1, clamp8(col[2]))
		buffer.writeu8(img, o + 2, clamp8(col[3]))
		buffer.writeu8(img, o + 3, 255)
	end
	if overlay then
		for y = 0, N - 1 do
			local row = overlay[y + 1] or ""
			for x = 0, N - 1 do
				if string.sub(row, x + 1, x + 1) == "*" then
					local o = (y * N + x) * 4
					buffer.writeu32(img, o, 0xFFFFFFFF)
					colorAt[y * N + x] = { 255, 255, 255 }
					baseAt[y * N + x] = { 255, 255, 255 }
				end
			end
		end
	end
	if not sprite.noOutline then
		-- tinted outline: empty pixels next to the sprite take a dark shade of their neighbour
		local outs: { [number]: { number } } = {}
		for y = 0, N - 1 do
			for x = 0, N - 1 do
				local i = y * N + x
				if colorAt[i] == nil then
					local best: { number }? = nil
					local bestSum = math.huge
					for _, d in { { 1, 0 }, { -1, 0 }, { 0, 1 }, { 0, -1 } } do
						local nx, ny = x + d[1], y + d[2]
						if nx >= 0 and ny >= 0 and nx < N and ny < N then
							local c = baseAt[ny * N + nx]
							if c and c[1] + c[2] + c[3] < bestSum then
								best, bestSum = c, c[1] + c[2] + c[3]
							end
						end
					end
					if best then
						outs[i] = { best[1] * 0.3 + 6, best[2] * 0.3 + 4, best[3] * 0.3 + 8 }
					end
				end
			end
		end
		for i, c in outs do
			local o = i * 4
			buffer.writeu8(img, o, clamp8(c[1]))
			buffer.writeu8(img, o + 1, clamp8(c[2]))
			buffer.writeu8(img, o + 2, clamp8(c[3]))
			buffer.writeu8(img, o + 3, 255)
		end
	end
	return img
end

-- The icon for an item key, or nil if it has no sprite.
function ItemSprites.icon(key: string): buffer?
	local s = SPRITES[key]
	if not s then
		return nil
	end
	return ItemSprites.render(s, if key == "enchanted_golden_apple" then T.enchanted_sparkle else nil)
end

ItemSprites.TEMPLATES = T
return ItemSprites
