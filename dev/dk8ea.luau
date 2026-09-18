--[=[
 * decluau: dev/dk8ea.luau - DK8-EA Line Frequency Real-Time Clock
 *
 * Adapted from OpenSIMH pdp8_clk.c.
 * Copyright (c) 1993-2021, Robert M. Supnik and OpenSIMH contributors.
 * Copyright (c) 2026, decluau contributors.
 * Licensed under the BSD-2-Clause-Patent license.
 ]=]

--!strict

local types = require("../common/types")
local cpu_mod = require("../pdp8/cpu")

local band = bit32.band
local bor = bit32.bor
local bnot = bit32.bnot

-- Device 013 (octal): DK8-EA Real-Time Clock
local CLK_DEV = 11 -- 013 octal

-- Default clock tick interval (instructions per line tick at ~60 Hz)
local DEFAULT_INTERVAL = 8000

export type dk8ea_t = {
	interval: number,
	counter: number,
}

local dk8ea = {}

dk8ea.DEFAULT_INTERVAL = DEFAULT_INTERVAL

function dk8ea.new(interval: number?): dk8ea_t
	local t = interval or DEFAULT_INTERVAL
	return {
		interval = t,
		counter = t,
	}
end

function dk8ea.reset(self: dk8ea_t, cpu: cpu_mod.cpu_t)
	self.counter = self.interval
	cpu.dev_done = band(cpu.dev_done, bnot(cpu_mod.INT_CLK))
	cpu_mod.update_int(cpu)
end

function dk8ea.tick(self: dk8ea_t, cpu: cpu_mod.cpu_t)
	cpu.dev_done = bor(cpu.dev_done, cpu_mod.INT_CLK)
	cpu_mod.update_int(cpu)
end

function dk8ea.step(self: dk8ea_t, cpu: cpu_mod.cpu_t)
	self.counter -= 1
	if self.counter <= 0 then
		self.counter = self.interval
		dk8ea.tick(self, cpu)
	end
end

function dk8ea.attach(self: dk8ea_t, cpu: cpu_mod.cpu_t)
	cpu_mod.add_reset_hook(cpu, function()
		dk8ea.reset(self, cpu)
	end)

	cpu_mod.add_step_hook(cpu, function(c)
		dk8ea.step(self, c)
	end)

	-- Device 013 (octal): DK8-EA IOT handlers
	cpu_mod.set_dev_handler(cpu, CLK_DEV, function(c, pulse, ir)
		if pulse == 1 then
			-- CLEI (6131): Enable clock interrupts
			c.int_enable = bor(c.int_enable, cpu_mod.INT_CLK)
			cpu_mod.update_int(c)
		elseif pulse == 2 then
			-- CLDI (6132): Disable clock interrupts
			c.int_enable = band(c.int_enable, bnot(cpu_mod.INT_CLK))
			cpu_mod.update_int(c)
		elseif pulse == 3 then
			-- CLSK / CLSC (6133): Skip if clock flag set, clear flag
			if band(c.dev_done, cpu_mod.INT_CLK) ~= 0 then
				c.dev_done = band(c.dev_done, bnot(cpu_mod.INT_CLK))
				cpu_mod.update_int(c)
				return 1
			end
		elseif pulse == 5 then
			-- CLLE (6135): Load interrupt enable from AC<11>
			if band(c.lac, 1) ~= 0 then
				c.int_enable = bor(c.int_enable, cpu_mod.INT_CLK)
			else
				c.int_enable = band(c.int_enable, bnot(cpu_mod.INT_CLK))
			end
			cpu_mod.update_int(c)
		elseif pulse == 6 then
			-- CLCL (6136): Clear clock flag
			c.dev_done = band(c.dev_done, bnot(cpu_mod.INT_CLK))
			cpu_mod.update_int(c)
		elseif pulse == 7 then
			-- CLSK (6137, PDP-8/A): Skip if clock flag set
			if band(c.dev_done, cpu_mod.INT_CLK) ~= 0 then
				return 1
			end
		end

		return 0
	end)
end

return dk8ea
