-- Headless module loader for Lune.
--
-- Our ModuleScripts use Roblox-style requires: `require(script.Parent.Config)`. This loader
-- emulates just enough of the Instance tree (`script`, `.Parent`, child lookup by name) over the
-- filesystem so the PURE shared modules (noise, generation, meshing, registry) run unmodified.
-- Anything that touches Roblox services is not loadable here, by design.

local fs = require("@lune/fs")
local luau = require("@lune/luau")

local Loader = {}

local cache: { [string]: any } = {}
local codegen = false

function Loader.setCodegen(enabled: boolean)
	codegen = enabled
	table.clear(cache)
end

local nodeMeta = {}

-- fs calls yield in Lune, and yielding inside a metamethod is illegal, so we index the whole
-- source tree up front and only consult these tables from __index.
local files: { [string]: boolean } = {}
local dirs: { [string]: boolean } = {}
local function indexTree(dir: string)
	if dirs[dir] then
		return
	end
	dirs[dir] = true
	for _, name in fs.readDir(dir) do
		local p = dir .. "/" .. name
		if fs.isDir(p) then
			indexTree(p)
		else
			files[p] = true
		end
	end
end

local function makeNode(path: string, isDir: boolean, parentPath: string?)
	return setmetatable({ __path = path, __isDir = isDir, __parentPath = parentPath }, nodeMeta)
end

local function dirname(p: string): string
	return string.match(p, "^(.*)/[^/]+$") or "."
end

nodeMeta.__index = function(self, key: string)
	if key == "Parent" then
		local pp = rawget(self, "__parentPath")
		return makeNode(pp, true, dirname(pp))
	elseif key == "Name" then
		return string.match(rawget(self, "__path"), "([^/]+)$")
	end
	local base = rawget(self, "__path") .. "/" .. key
	if files[base .. ".luau"] then
		return makeNode(base .. ".luau", false, rawget(self, "__path"))
	elseif dirs[base] then
		return makeNode(base, true, rawget(self, "__path"))
	end
	error(`Loader: '{key}' is not a child of {rawget(self, "__path")}`, 2)
end

local function requireNode(node: any): any
	local path = rawget(node, "__path")
	assert(path and not rawget(node, "__isDir"), "Loader: require() expects a module node")
	local hit = cache[path]
	if hit ~= nil then
		return hit
	end
	local source = fs.readFile(path)
	local env = setmetatable({}, { __index = _G })
	env.script = node
	env.require = requireNode
	local fn = luau.load(source, { debugName = path, environment = env, codegenEnabled = codegen })
	local result = fn()
	cache[path] = result
	return result
end

-- Require a module by filesystem path, e.g. Loader.require("src/shared/World/TerrainGen")
function Loader.require(path: string): any
	indexTree(string.match(path, "^([^/]+)") or ".")
	local file = path .. ".luau"
	return requireNode(makeNode(file, false, dirname(file)))
end

return Loader
