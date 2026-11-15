-- Compiles (parses) every .luau file under src/ to catch syntax errors in Roblox-only modules
-- that the headless tests can't execute, and checks that no local function is called on a line
-- above its definition (it would be nil there: this bug happened three times).
-- Run: lune run tests/lune/compile_all
local fs = require("@lune/fs")
local luau = require("@lune/luau")
local process = require("@lune/process")

local failures, count = 0, 0

local function escape(s: string): string
	return (string.gsub(s, "[%^%$%(%)%%%.%[%]%*%+%-%?]", "%%%0"))
end

-- `local function f` used (called) above its definition, unless declared earlier with `local f`.
local function useBeforeDefinition(path: string, source: string)
	local lines = string.split(source, "\n")
	local defs: { [string]: number } = {}
	local forward: { [string]: number } = {}
	for i, l in lines do
		local name = string.match(l, "^%s*local function ([%w_]+)")
		if name and not defs[name] then
			defs[name] = i
		end
		local fwd = string.match(l, "^%s*local ([%w_]+)%s*$") or string.match(l, "^%s*local ([%w_]+)%s*:[^=]*$")
		if fwd and not forward[fwd] then
			forward[fwd] = i
		end
	end
	for name, at in defs do
		if not (forward[name] and forward[name] < at) then
			local pattern = escape(name) .. "%s*%("
			for i = 1, at - 1 do
				local code = string.split(lines[i], "--")[1]
				local s = string.find(code, pattern)
				while s do
					local before = if s > 1 then string.sub(code, s - 1, s - 1) else ""
					if not string.match(before, "[%w_%.:]") then
						failures += 1
						print(`FAIL {path}:{i}: '{name}' is called above its definition (line {at}), where it is still nil`)
						break
					end
					s = string.find(code, pattern, s + 1)
				end
			end
		end
	end
end

local function walk(dir: string)
	for _, name in fs.readDir(dir) do
		local p = dir .. "/" .. name
		if fs.isDir(p) then
			walk(p)
		elseif string.sub(name, -5) == ".luau" then
			count += 1
			local source = fs.readFile(p)
			local ok, err = pcall(luau.compile, source)
			if not ok then
				failures += 1
				print(`FAIL {p}\n  {err}`)
			else
				useBeforeDefinition(p, source)
			end
		end
	end
end
walk("src")
print(`compiled {count} files, {failures} failed`)
if failures > 0 then
	process.exit(1)
end
