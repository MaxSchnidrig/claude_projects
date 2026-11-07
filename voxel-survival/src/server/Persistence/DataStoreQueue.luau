--!strict
-- All DataStore traffic goes through here.
--
--   get(key)            GetAsync with retries; waits for request budget first
--   markDirty(key, fn)  remember that `key` needs writing; `fn(old)` builds the value at write
--                       time from the stored value (inside UpdateAsync, so it must not yield);
--                       many changes to one key merge into a single write
--   flush(deadline?)    write dirty keys with UpdateAsync, oldest first, honouring:
--                         * the request budget (GetRequestBudgetForRequestType) before each call
--                         * at most one write per key every 6 s (DataStore per-key limit)
--                         * retries with exponential backoff + jitter (1, 2, 4, 8 s ... max 16)
--                       A key that keeps failing stays dirty and is tried again next flush.
--
-- Without DataStore access (Studio with API access off, or any error creating the store) it
-- falls back to an in-memory store and says so once: the game runs, nothing persists.

local DataStoreService = game:GetService("DataStoreService")

local DataStoreQueue = {}
DataStoreQueue.__index = DataStoreQueue

local KEY_INTERVAL = 6
local MAX_ATTEMPTS = 5

export type Queue = {
	store: GlobalDataStore?,
	memory: { [string]: any }?,
	dirty: { [string]: { fn: (any) -> any, since: number } },
	lastWrite: { [string]: number },
	stats: { reads: number, writes: number, failures: number, lastError: string, pending: number },
	flushing: boolean,
}

local function backoff(attempt: number)
	task.wait(math.min(2 ^ (attempt - 1), 16) * (0.75 + math.random() * 0.5))
end

local function waitBudget(kind: Enum.DataStoreRequestType, deadline: number?)
	while DataStoreService:GetRequestBudgetForRequestType(kind) <= 0 do
		if deadline and os.clock() > deadline then
			return
		end
		task.wait(0.5)
	end
end

function DataStoreQueue.new(name: string): Queue
	local self = setmetatable({
		store = nil,
		memory = nil,
		dirty = {},
		lastWrite = {},
		stats = { reads = 0, writes = 0, failures = 0, lastError = "", pending = 0 },
		flushing = false,
	}, DataStoreQueue) :: any
	local ok, store = pcall(function()
		local s = DataStoreService:GetDataStore(name)
		-- a cheap probe: in Studio without API access this throws
		s:GetAsync("__probe")
		return s
	end)
	if ok then
		self.store = store
	else
		warn(`[Persistence] DataStores unavailable ({store}). Playing WITHOUT saving. In Studio: Game Settings > Security > Enable Studio Access to API Services.`)
		self.memory = {}
	end
	return self
end

function DataStoreQueue.isPersistent(self: Queue): boolean
	return self.store ~= nil
end

-- Read a key (yields). Returns (ok, value); ok is false only if every retry failed.
function DataStoreQueue.get(self: Queue, key: string): (boolean, any)
	if self.memory then
		return true, self.memory[key]
	end
	local store = self.store :: GlobalDataStore
	for attempt = 1, MAX_ATTEMPTS do
		waitBudget(Enum.DataStoreRequestType.GetAsync)
		local ok, value = pcall(function()
			return store:GetAsync(key)
		end)
		self.stats.reads += 1
		if ok then
			return true, value
		end
		self.stats.failures += 1
		self.stats.lastError = tostring(value)
		warn(`[Persistence] read {key} failed (attempt {attempt}): {value}`)
		if attempt < MAX_ATTEMPTS then
			backoff(attempt)
		end
	end
	return false, nil
end

function DataStoreQueue.markDirty(self: Queue, key: string, fn: (any) -> any)
	local d = self.dirty[key]
	if d then
		d.fn = fn
	else
		self.dirty[key] = { fn = fn, since = os.clock() }
	end
	self.stats.pending = 0
	for _ in self.dirty do
		self.stats.pending += 1
	end
end

-- Write one key now (yields). Returns true on success.
function DataStoreQueue.write(self: Queue, key: string, fn: (any) -> any, deadline: number?): boolean
	if self.memory then
		self.memory[key] = fn(self.memory[key])
		return true
	end
	local store = self.store :: GlobalDataStore
	for attempt = 1, MAX_ATTEMPTS do
		local wait = KEY_INTERVAL - (os.clock() - (self.lastWrite[key] or -math.huge))
		if wait > 0 then
			task.wait(wait)
		end
		waitBudget(Enum.DataStoreRequestType.UpdateAsync, deadline)
		local ok, err = pcall(function()
			store:UpdateAsync(key, function(old)
				return fn(old)
			end)
		end)
		self.lastWrite[key] = os.clock()
		self.stats.writes += 1
		if ok then
			return true
		end
		self.stats.failures += 1
		self.stats.lastError = tostring(err)
		warn(`[Persistence] write {key} failed (attempt {attempt}): {err}`)
		if deadline and os.clock() > deadline then
			return false
		end
		if attempt < MAX_ATTEMPTS then
			backoff(attempt)
		end
	end
	return false
end

-- Write all dirty keys (yields). Keys written in parallel threads so one slow key (6 s rule)
-- doesn't hold up the rest; returns when all are done or the deadline passes.
function DataStoreQueue.flush(self: Queue, deadline: number?)
	if self.flushing and not deadline then
		return
	end
	self.flushing = true
	local jobs = {}
	for key, d in self.dirty do
		table.insert(jobs, { key = key, d = d })
	end
	table.sort(jobs, function(a, b)
		return a.d.since < b.d.since
	end)
	local remaining = #jobs
	for _, job in jobs do
		self.dirty[job.key] = nil
		task.spawn(function()
			local ok = DataStoreQueue.write(self, job.key, job.d.fn, deadline)
			if not ok and not self.dirty[job.key] then
				self.dirty[job.key] = job.d -- try again next time
			end
			remaining -= 1
		end)
	end
	while remaining > 0 and (not deadline or os.clock() < deadline) do
		task.wait(0.1)
	end
	self.stats.pending = 0
	for _ in self.dirty do
		self.stats.pending += 1
	end
	self.flushing = false
end

return DataStoreQueue
