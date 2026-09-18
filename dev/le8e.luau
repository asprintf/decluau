--[=[
 * decluau: dev/le8e.luau - PDP-8/E LE8-E / LP08 Line Printer Controller
 *
 * Adapted from OpenSIMH pdp8_lp.c.
 * Copyright (c) 1993-2021, Robert M. Supnik and OpenSIMH contributors.
 * Copyright (c) 2026, decluau contributors.
 * Licensed under the BSD-2-Clause-Patent license.
 ]=]

--!strict

local types = require("../common/types")
local cpu = require("../pdp8/cpu")

local band = bit32.band
local bor = bit32.bor
local bnot = bit32.bnot

local DEV_LPT = 0x36 -- 066 octal

export type le8e_t = {
	buf: number,
	err: boolean,
	write_fn: ((number) -> ())?,
	output_chars: { number },
}

local le8e = {}

function le8e.new(write_fn: ((number) -> ())?): le8e_t
	return {
		buf = 0,
		err = false,
		write_fn = write_fn,
		output_chars = {},
	}
end

function le8e.reset(self: le8e_t, c: cpu.cpu_t)
	self.buf = 0
	c.dev_done = band(c.dev_done, bnot(cpu.INT_LPT))
	c.int_req = band(c.int_req, bnot(cpu.INT_LPT))
	c.int_enable = bor(c.int_enable, cpu.INT_LPT)
	cpu.update_int(c)
end

function le8e.set_error(self: le8e_t, err: boolean)
	self.err = err
end

function le8e.get_output(self: le8e_t): string
	local s = ""
	for i = 1, #self.output_chars do
		s ..= string.char(self.output_chars[i])
	end
	return s
end

function le8e.clear_output(self: le8e_t)
	table.clear(self.output_chars)
end

function le8e.attach(self: le8e_t, c: cpu.cpu_t)
	cpu.add_reset_hook(c, function()
		le8e.reset(self, c)
	end)

	cpu.set_dev_handler(c, DEV_LPT, function(_cpu: cpu.cpu_t, pulse: number, ir: number): number
		if pulse == 0 then
			-- PKSTF (6660): Set line printer done flag
			c.dev_done = bor(c.dev_done, cpu.INT_LPT)
			cpu.update_int(c)
			return 0

		elseif pulse == 1 then
			-- PSKF (6661): Skip if done flag is set
			if band(c.dev_done, cpu.INT_LPT) ~= 0 then
				return 1
			end
			return 0

		elseif pulse == 2 then
			-- PCLF (6662): Clear done flag and int req
			c.dev_done = band(c.dev_done, bnot(cpu.INT_LPT))
			c.int_req = band(c.int_req, bnot(cpu.INT_LPT))
			return 0

		elseif pulse == 3 then
			-- PSKE (6663): Skip on printer error
			if self.err then
				return 1
			end
			return 0

		elseif pulse == 4 then
			-- PSTB (6664): Load buffer and print character
			local ch = band(c.lac, 0x7F)
			self.buf = ch
			table.insert(self.output_chars, ch)
			if self.write_fn ~= nil then
				self.write_fn(ch)
			end
			c.dev_done = bor(c.dev_done, cpu.INT_LPT)
			cpu.update_int(c)
			return 0

		elseif pulse == 5 then
			-- PSIE (6665): Set interrupt enable
			c.int_enable = bor(c.int_enable, cpu.INT_LPT)
			cpu.update_int(c)
			return 0

		elseif pulse == 6 then
			-- PCLF!PSTB (6666): Clear flag then print character
			c.dev_done = band(c.dev_done, bnot(cpu.INT_LPT))
			c.int_req = band(c.int_req, bnot(cpu.INT_LPT))
			local ch = band(c.lac, 0x7F)
			self.buf = ch
			table.insert(self.output_chars, ch)
			if self.write_fn ~= nil then
				self.write_fn(ch)
			end
			c.dev_done = bor(c.dev_done, cpu.INT_LPT)
			cpu.update_int(c)
			return 0

		elseif pulse == 7 then
			-- PCIE (6667): Clear interrupt enable
			c.int_enable = band(c.int_enable, bnot(cpu.INT_LPT))
			c.int_req = band(c.int_req, bnot(cpu.INT_LPT))
			return 0
		end

		return 0
	end)

	le8e.reset(self, c)
end

return le8e
