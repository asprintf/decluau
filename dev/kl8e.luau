--[=[
 * decluau: dev/kl8e.luau - KL8-E Console Teletype Controller
 *
 * Adapted from OpenSIMH pdp8_tt.c.
 * Copyright (c) 1993-2022, Robert M. Supnik and OpenSIMH contributors.
 * Copyright (c) 2026, decluau contributors.
 * Licensed under the BSD-2-Clause-Patent license.
 ]=]

--!strict

local cpu_mod = require("../pdp8/cpu")

local band = bit32.band
local bor = bit32.bor
local bnot = bit32.bnot

export type kl8e_t = {
	tti_buf: number,
	tto_buf: number,
	out_fn: ((char: number) -> ())?,
}

local kl8e = {}

function kl8e.new(out_fn: ((char: number) -> ())?): kl8e_t
	return {
		tti_buf = 0,
		tto_buf = 0,
		out_fn = out_fn,
	}
end

function kl8e.attach(self: kl8e_t, cpu: cpu_mod.cpu_t)
	local INT_TTO = cpu_mod.INT_TTO
	local INT_TTI = cpu_mod.INT_TTI

	cpu.dev_done = band(cpu.dev_done, bnot(bor(INT_TTO, INT_TTI)))
	cpu_mod.update_int(cpu)

	cpu_mod.add_reset_hook(cpu, function()
		-- CAF clears device done flags
		cpu.dev_done = band(cpu.dev_done, bnot(bor(INT_TTO, INT_TTI)))
		cpu_mod.update_int(cpu)
	end)

	-- Device 003: Keyboard (TTI)
	cpu_mod.set_dev_handler(cpu, 3, function(c, pulse, ir)
		if pulse == 0 then
			-- KCF: Clear flag
			c.dev_done = band(c.dev_done, bnot(INT_TTI))
			cpu_mod.update_int(c)
		elseif pulse == 1 then
			-- KSF: Skip if flag
			if band(c.dev_done, INT_TTI) ~= 0 then
				return 1
			end
		elseif pulse == 2 then
			-- KCC: Clear flag and AC
			c.dev_done = band(c.dev_done, bnot(INT_TTI))
			cpu_mod.update_int(c)
			c.lac = band(c.lac, 0x1000)
		elseif pulse == 4 then
			-- KRS: Read static
			c.lac = bor(c.lac, self.tti_buf)
		elseif pulse == 5 then
			-- KIE: Keyboard Interrupt Enable (bit 11 controls enable)
			if band(c.lac, 1) ~= 0 then
				c.int_enable = bor(c.int_enable, bor(INT_TTI, INT_TTO))
			else
				c.int_enable = band(c.int_enable, bnot(bor(INT_TTI, INT_TTO)))
			end
			cpu_mod.update_int(c)
		elseif pulse == 6 then
			-- KRB: Read buffer
			c.dev_done = band(c.dev_done, bnot(INT_TTI))
			cpu_mod.update_int(c)
			c.lac = bor(band(c.lac, 0x1000), self.tti_buf)
		end
		return 0
	end)

	-- Device 004: Teleprinter (TTO)
	cpu_mod.set_dev_handler(cpu, 4, function(c, pulse, ir)
		if pulse == 0 then
			-- TLF: Set flag
			c.dev_done = bor(c.dev_done, INT_TTO)
			cpu_mod.update_int(c)
		elseif pulse == 1 then
			-- TSF: Skip if flag
			if band(c.dev_done, INT_TTO) ~= 0 then
				return 1
			end
		elseif pulse == 2 then
			-- TCF: Clear flag
			c.dev_done = band(c.dev_done, bnot(INT_TTO))
			cpu_mod.update_int(c)
		elseif pulse == 5 then
			-- SPI: Skip on printer interrupt
			if band(c.int_req, bor(INT_TTI, INT_TTO)) ~= 0 then
				return 1
			end
		elseif pulse == 4 or pulse == 6 then
			-- TPC (4) or TLS (6): Output character
			local ch = band(c.lac, 0xFF)
			self.tto_buf = ch
			if self.out_fn ~= nil then
				self.out_fn(ch)
			end
			c.dev_done = bor(c.dev_done, INT_TTO)
			cpu_mod.update_int(c)
		end
		return 0
	end)
end

return kl8e
