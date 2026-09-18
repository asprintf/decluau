--[=[
 * decluau: common/binloader.luau - DEC Paper Tape BIN Format Loader
 *
 * Adapted from OpenSIMH pdp8_sys.c (sim_load_bin).
 * Copyright (c) 1993-2022, Robert M. Supnik and OpenSIMH contributors.
 * Copyright (c) 2026, decluau contributors.
 * Licensed under the BSD-2-Clause-Patent license.
 ]=]

--!strict

local types = require("./types")

local band = bit32.band
local bor = bit32.bor
local lshift = bit32.lshift

local binloader = {}

export type mem_writer_t = (addr: number, val: number) -> ()

-- Loads a DEC PDP-8 binary format paper tape into memory
function binloader.load_bin(
	data: buffer,
	write_mem: mem_writer_t
): (types.stat_t, number)
	local len = buffer.len(data)
	local pos = 0
	local words_loaded = 0
	local newf = 0
	local rubout = false

	local function get_char(): number?
		while pos < len do
			local c = buffer.readu8(data, pos)
			pos += 1
			if rubout then
				if c == 0xFF then -- 0377
					rubout = false
				end
			elseif c == 0xFF then
				rubout = true
			elseif c > 0x80 then -- > 0200, channel 8 set (field change)
				newf = lshift(band(c, 0x38), 9) -- (c & 070) << 9
			else
				return c
			end
		end
		return nil
	end

	while pos < len do
		local csum = 0
		local origin = 0
		local field = 0
		newf = 0

		-- Skip leader frames
		local hi = get_char()
		while hi ~= nil and (hi == 0 or hi >= 0x80) do
			hi = get_char()
		end

		if hi == nil then
			break
		end

		-- Read data frames
		while true do
			local lo = get_char()
			if lo == nil then
				return types.SCPE_FMT, words_loaded
			end

			local wd = bor(lshift(hi, 6), lo)
			local t = hi
			hi = get_char()
			if hi == nil then
				return types.SCPE_FMT, words_loaded
			end

			-- 0x80 (0200) marks trailer / checksum verification
			if hi == 0x80 then
				if band(csum - wd, 0xFFF) ~= 0 then
					return types.SCPE_CSUM, words_loaded
				end
				break
			end

			csum = band(csum + t + lo, 0xFFF)
			if wd > 0xFFF then
				-- Channel 7 set indicates new origin address
				origin = band(wd, 0xFFF)
			else
				write_mem(bor(field, origin), wd)
				origin = band(origin + 1, 0xFFF)
				words_loaded += 1
			end
			field = newf
		end
	end

	return types.SCPE_OK, words_loaded
end

return binloader
