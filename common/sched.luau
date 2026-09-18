--[=[
 * decluau: common/sched.luau - Event Queue and Time Scheduler
 *
 * Adapted from OpenSIMH sim_timer.c and scp.c.
 * Copyright (c) 1993-2022, Robert M. Supnik and OpenSIMH contributors.
 * Copyright (c) 2026, decluau contributors.
 * Licensed under the BSD-2-Clause-Patent license.
 ]=]

--!strict

local types = require("./types")

export type unit_t = types.unit_t
export type stat_t = types.stat_t

export type event_entry_t = {
	unit: unit_t,
	expire_time: number,
}

export type sched_t = {
	sim_time: number,
	queue: { event_entry_t },
}

local sched = {}

function sched.new(): sched_t
	return {
		sim_time = 0,
		queue = {},
	}
end

function sched.is_active(self: sched_t, unit: unit_t): boolean
	for i = 1, #self.queue do
		if self.queue[i].unit == unit then
			return true
		end
	end
	return false
end

function sched.cancel(self: sched_t, unit: unit_t)
	local q = self.queue
	for i = 1, #q do
		if q[i].unit == unit then
			table.remove(q, i)
			return
		end
	end
end

-- Activates a unit to fire after delta_time cycles
function sched.activate(self: sched_t, unit: unit_t, delta_time: number)
	sched.cancel(self, unit)

	local expire = self.sim_time + delta_time
	local q = self.queue
	local idx = #q + 1

	-- Insertion sort maintains ascending expiration order
	for i = 1, #q do
		if expire < q[i].expire_time then
			idx = i
			break
		end
	end

	table.insert(q, idx, {
		unit = unit,
		expire_time = expire,
	})
end

-- Advances simulation time and invokes actions for due events
function sched.step(self: sched_t, delta_cycles: number): stat_t
	self.sim_time += delta_cycles

	local q = self.queue
	while #q > 0 and q[1].expire_time <= self.sim_time do
		local entry = table.remove(q, 1) :: event_entry_t
		local act = entry.unit.action
		if act ~= nil then
			local st = act(entry.unit)
			if st ~= types.SCPE_OK then
				return st
			end
		end
	end

	return types.SCPE_OK
end

return sched
