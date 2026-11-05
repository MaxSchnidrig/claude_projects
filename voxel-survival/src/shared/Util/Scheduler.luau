--!strict
-- Cooperative, time-sliced job runner.
--
-- Heavy work (generation, meshing, collision) runs inside coroutines. Jobs call
-- `Scheduler.checkpoint()` at convenient points; when the frame's budget is spent the job yields
-- and resumes next frame. Jobs come from a `picker` callback so the owner can always choose the
-- most urgent work right now (e.g. the chunk closest to the player), instead of a stale queue.
--
-- IMPORTANT: jobs must not call yielding Roblox APIs (e.g. *Async methods, task.wait). Those
-- would be resumed by the engine, not by us. Spawn async work with task.spawn instead.

local Scheduler = {}
Scheduler.__index = Scheduler

export type Picker = () -> (() -> ())?

export type Scheduler = typeof(setmetatable(
	{} :: {
		budget: number, -- seconds per step
		picker: Picker,
		current: thread?,
		stats: { jobs: number, steps: number, busyTime: number, lastStepTime: number },
	},
	Scheduler
))

local clock = os.clock
local deadline = math.huge -- shared: only one scheduler steps at a time (single-threaded Luau)

function Scheduler.new(budgetMs: number, picker: Picker): Scheduler
	return setmetatable({
		budget = budgetMs / 1000,
		picker = picker,
		current = nil :: thread?,
		stats = { jobs = 0, steps = 0, busyTime = 0, lastStepTime = 0 },
	}, Scheduler)
end

function Scheduler.setBudget(self: Scheduler, budgetMs: number)
	self.budget = budgetMs / 1000
end

-- Yield the running job if this frame's budget is used up. Safe to call outside a scheduler job
-- (then it does nothing), which lets the same code run synchronously in tests.
function Scheduler.checkpoint()
	if clock() > deadline and coroutine.isyieldable() then
		coroutine.yield()
	end
end

-- Run jobs until the budget is spent or there is nothing to do.
function Scheduler.step(self: Scheduler)
	local start = clock()
	deadline = start + self.budget
	while clock() < deadline do
		local co = self.current
		if co == nil then
			local job = self.picker()
			if job == nil then
				break
			end
			co = coroutine.create(job)
			self.current = co
		end
		local ok, err = coroutine.resume(co :: thread)
		if not ok then
			warn(`[Scheduler] job failed: {err}\n{debug.traceback(co :: thread)}`)
			self.current = nil
		elseif coroutine.status(co :: thread) == "dead" then
			self.current = nil
			self.stats.jobs += 1
		end
	end
	deadline = math.huge
	local spent = clock() - start
	self.stats.steps += 1
	self.stats.busyTime += spent
	self.stats.lastStepTime = spent
end

function Scheduler.isBusy(self: Scheduler): boolean
	return self.current ~= nil
end

return Scheduler
