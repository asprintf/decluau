--[=[
 * decluau: dev/vc8e.luau - VC8-E / Type 34 Point Plot CRT Display
 *
 * Adapted from OpenSIMH pdp8_dpy.c and DEC Type 34 / VC8-E specifications.
 * Copyright (c) 2025, Lars Brinkhoff.
 * Copyright (c) 2026, decluau contributors.
 * Licensed under the BSD-2-Clause-Patent license.
 *
 * The Type 34 / VC8-E is a point-plotting oscilloscope / CRT vector display
 * interface for the DEC PDP-8. It provides a 10-bit (1024x1024) coordinate
 * deflection space with intensified point plotting, simulating green or
 * amber CRT phosphor decay and exportable to standard PPM raster images.
 *
 * Device Codes:
 *   005: X deflection (DCX, DXL, DIX, DXS)
 *   006: Y deflection (DCY, DYL, DIY, DYS)
 *
 * IOT Micro-operations:
 *   Pulse 1: Clear coordinate register (DCX 6051 / DCY 6061)
 *   Pulse 2: Load coordinate register from AC<2:11> (DXL 6052 / DYL 6062)
 *   Pulse 4: Intensify point at current (X, Y) (DIX 6054 / DIY 6064)
 *   Pulse 6: Load coordinate and intensify (DXS 6056 / DYS 6066)
 *   Pulse 7: Clear, load, and intensify (6057 / 6067)
 ]=]

--!strict

local types = require("../common/types")
local cpu_mod = require("../pdp8/cpu")

local band = bit32.band
local bor = bit32.bor
local bnot = bit32.bnot
local rshift = bit32.rshift
local lshift = bit32.lshift

-- Device codes (octal 005, 006)
local DPY_DEV_X = 5
local DPY_DEV_Y = 6

local DPY_WIDTH = 1024
local DPY_HEIGHT = 1024
local DPY_COORD_MASK = 0x3FF -- 10-bit coordinates: 0..1023

export type phosphor_t = "green" | "amber" | "white"

export type vc8e_t = {
	x: number,
	y: number,
	intensity: number,
	fb: buffer,
	width: number,
	height: number,
	points_plotted: number,
	phosphor: phosphor_t,
	enabled: boolean,
}

local vc8e = {}

vc8e.DPY_DEV_X = DPY_DEV_X
vc8e.DPY_DEV_Y = DPY_DEV_Y
vc8e.DPY_WIDTH = DPY_WIDTH
vc8e.DPY_HEIGHT = DPY_HEIGHT
vc8e.DPY_COORD_MASK = DPY_COORD_MASK

function vc8e.new(phosphor: phosphor_t?): vc8e_t
	return {
		x = 0,
		y = 0,
		intensity = 255,
		fb = buffer.create(DPY_WIDTH * DPY_HEIGHT),
		width = DPY_WIDTH,
		height = DPY_HEIGHT,
		points_plotted = 0,
		phosphor = phosphor or "green",
		enabled = true,
	}
end

function vc8e.reset(self: vc8e_t)
	self.x = 0
	self.y = 0
	self.points_plotted = 0
	buffer.fill(self.fb, 0, 0, self.width * self.height)
end

function vc8e.clear(self: vc8e_t)
	buffer.fill(self.fb, 0, 0, self.width * self.height)
end

function vc8e.plot_point(self: vc8e_t, x: number, y: number, int_val: number?)
	if not self.enabled then
		return
	end
	local px = band(x, DPY_COORD_MASK)
	local py = band(y, DPY_COORD_MASK)
	local iv = int_val or self.intensity

	-- CRT raster space: (0, 0) bottom-left, inverted for standard top-left
	local offset = (DPY_HEIGHT - 1 - py) * DPY_WIDTH + px
	local cur = buffer.readu8(self.fb, offset)
	local new_val = math.min(255, cur + iv)
	buffer.writeu8(self.fb, offset, new_val)
	self.points_plotted += 1
end

function vc8e.decay(self: vc8e_t, factor: number?)
	local f = factor or 0.9
	local total = self.width * self.height
	for i = 0, total - 1 do
		local v = buffer.readu8(self.fb, i)
		if v > 0 then
			buffer.writeu8(self.fb, i, math.floor(v * f))
		end
	end
end

function vc8e.get_pixel(self: vc8e_t, x: number, y: number): number
	local px = band(x, DPY_COORD_MASK)
	local py = band(y, DPY_COORD_MASK)
	local offset = (DPY_HEIGHT - 1 - py) * DPY_WIDTH + px
	return buffer.readu8(self.fb, offset)
end

-- Export framebuffer as binary PPM (P6) format
function vc8e.to_ppm(self: vc8e_t): buffer
	local w = self.width
	local h = self.height
	local header = string.format("P6\n%d %d\n255\n", w, h)
	local header_len = #header
	local out_buf = buffer.create(header_len + w * h * 3)

	buffer.writestring(out_buf, 0, header)
	local dst = header_len

	local phosph = self.phosphor
	for i = 0, (w * h) - 1 do
		local v = buffer.readu8(self.fb, i)
		local r, g, b = 0, 0, 0
		if phosph == "green" then
			-- P7/P31 CRT phosphor green
			r = math.floor(v * 0.1)
			g = v
			b = math.floor(v * 0.2)
		elseif phosph == "amber" then
			-- P134 CRT phosphor amber
			r = v
			g = math.floor(v * 0.7)
			b = math.floor(v * 0.1)
		else
			-- P4 monochrome white
			r = v
			g = v
			b = v
		end
		buffer.writeu8(out_buf, dst, r)
		buffer.writeu8(out_buf, dst + 1, g)
		buffer.writeu8(out_buf, dst + 2, b)
		dst += 3
	end

	return out_buf
end

function vc8e.attach(self: vc8e_t, cpu: cpu_mod.cpu_t)
	cpu_mod.add_reset_hook(cpu, function()
		vc8e.reset(self)
	end)

	-- Common IOT handler for Device 005 (X) and Device 006 (Y)
	local function dpy_handler(c: cpu_mod.cpu_t, pulse: number, ir: number)
		local is_y = band(rshift(ir, 3), 0x3F) == DPY_DEV_Y

		-- Pulse 1: Clear coordinate register
		if band(pulse, 1) ~= 0 then
			if is_y then
				self.y = 0
			else
				self.x = 0
			end
		end

		-- Pulse 2: Load coordinate from AC<2:11> (10 bits)
		if band(pulse, 2) ~= 0 then
			local val = band(c.lac, DPY_COORD_MASK)
			if is_y then
				self.y = bor(self.y, val)
			else
				self.x = bor(self.x, val)
			end
		end

		-- Pulse 4: Intensify point at current (X, Y)
		if band(pulse, 4) ~= 0 then
			vc8e.plot_point(self, self.x, self.y)
		end

		return 0
	end

	cpu_mod.set_dev_handler(cpu, DPY_DEV_X, dpy_handler)
	cpu_mod.set_dev_handler(cpu, DPY_DEV_Y, dpy_handler)
end

return vc8e
