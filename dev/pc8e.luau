--[=[
 * decluau: dev/pc8e.luau - PC8-E Paper Tape Reader/Punch Controller
 *
 * Adapted from OpenSIMH pdp8_pt.c.
 * Copyright (c) 1993-2022, Robert M. Supnik and OpenSIMH contributors.
 * Copyright (c) 2026, decluau contributors.
 * Licensed under the BSD-2-Clause-Patent license.
 ]=]

--!strict

local cpu_mod = require("../pdp8/cpu")

local band = bit32.band
local bor = bit32.bor
local bnot = bit32.bnot

export type pc8e_t = {
	ptr_buf: number,
	ptp_buf: number,
}

local pc8e = {}

function pc8e.new(): pc8e_t
	return {
		ptr_buf = 0,
		ptp_buf = 0,
	}
end

function pc8e.attach(self: pc8e_t, cpu: cpu_mod.cpu_t)
	local INT_PTR = cpu_mod.INT_PTR
	local INT_PTP = cpu_mod.INT_PTP

	-- On cold reset, punch flag is ready
	cpu.dev_done = bor(cpu.dev_done, INT_PTP)
	cpu_mod.update_int(cpu)

	cpu_mod.add_reset_hook(cpu, function()
		cpu.dev_done = band(cpu.dev_done, bnot(bor(INT_PTR, INT_PTP)))
		cpu_mod.update_int(cpu)
	end)

	-- Device 001: Paper Tape Reader (PTR)
	cpu_mod.set_dev_handler(cpu, 1, function(c, pulse, ir)
		if pulse == 0 then
			-- RPE: Reader Interrupt Enable
			c.int_enable = bor(c.int_enable, bor(INT_PTR, INT_PTP))
			cpu_mod.update_int(c)
		elseif pulse == 1 then
			-- RSF: Skip if flag
			if band(c.dev_done, INT_PTR) ~= 0 then
				return 1
			end
		elseif pulse == 2 then
			-- RRB: Read buffer
			c.lac = bor(c.lac, self.ptr_buf)
		elseif pulse == 4 then
			-- RFC: Clear flag
			c.dev_done = band(c.dev_done, bnot(INT_PTR))
			cpu_mod.update_int(c)
		elseif pulse == 6 then
			-- RFC + RRB
			c.dev_done = band(c.dev_done, bnot(INT_PTR))
			cpu_mod.update_int(c)
			c.lac = bor(c.lac, self.ptr_buf)
		end
		return 0
	end)

	-- Device 002: Paper Tape Punch (PTP)
	cpu_mod.set_dev_handler(cpu, 2, function(c, pulse, ir)
		if pulse == 0 then
			-- PCE: Punch Interrupt Disable
			c.int_enable = band(c.int_enable, bnot(bor(INT_PTR, INT_PTP)))
			cpu_mod.update_int(c)
		elseif pulse == 1 then
			-- PSF: Skip if flag
			if band(c.dev_done, INT_PTP) ~= 0 then
				return 1
			end
		elseif pulse == 2 then
			-- PCF: Clear flag
			c.dev_done = band(c.dev_done, bnot(INT_PTP))
			cpu_mod.update_int(c)
		elseif pulse == 4 or pulse == 6 then
			-- PPC (4) or PLS (6): Punch character
			self.ptp_buf = band(c.lac, 0xFF)
			c.dev_done = bor(c.dev_done, INT_PTP)
			cpu_mod.update_int(c)
		end
		return 0
	end)
end

return pc8e
