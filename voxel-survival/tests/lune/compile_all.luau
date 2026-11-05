-- Compiles (parses) every .luau file under src/ to catch syntax errors in Roblox-only modules
-- that the headless tests can't execute. Run: lune run tests/lune/compile_all
local fs = require("@lune/fs")
local luau = require("@lune/luau")
local process = require("@lune/process")

local failures, count = 0, 0
local function walk(dir: string)
	for _, name in fs.readDir(dir) do
		local p = dir .. "/" .. name
		if fs.isDir(p) then
			walk(p)
		elseif string.sub(name, -5) == ".luau" then
			count += 1
			local ok, err = pcall(luau.compile, fs.readFile(p))
			if not ok then
				failures += 1
				print(`FAIL {p}\n  {err}`)
			end
		end
	end
end
walk("src")
print(`compiled {count} files, {failures} failed`)
if failures > 0 then
	process.exit(1)
end
