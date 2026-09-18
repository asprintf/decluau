--[=[
 * decluau: tests/le8e_test.luau - Unit test suite for LE8-E Line Printer Controller
 *
 * Verifies LP8-E / LE8-E line printer IOT instructions:
 * PKSTF (6660), PSKF (6661), PCLF (6662), PSKE (6663),
 * PSTB (6664), PSIE (6665), PCLF!PSTB (6666), PCIE (6667).
 *
 * Copyright (c) 2026, decluau contributors.
 * Licensed under the BSD-2-Clause-Patent license.
 ]=]

--!strict

local stdio = require("@lune/stdio")
local cpu = require("../pdp8/cpu")
local le8e = require("../dev/le8e")

local band = bit32.band
local bor = bit32.bor

local tests_passed = 0
local tests_total = 0

local function check(cond: boolean, msg: string)
	tests_total += 1
	if not cond then
		stdio.write(string.format("  FAIL: %s\n", msg))
		error(msg)
	end
	tests_passed += 1
	stdio.write(string.format("  PASS: %s\n", msg))
end

local function oct(s: string): number
	return tonumber(s, 8) :: number
end

local function main()
	print("==========================================")
	print("Running PDP-8 LE8-E Line Printer Unit Tests")
	print("==========================================")

	local c = cpu.new(32768)
	local lp = le8e.new()
	le8e.attach(lp, c)

	-- 1. Initial State & Flags
	print("[1/4] Testing Controller Reset & Initial Flags...")
	check(band(c.dev_done, cpu.INT_LPT) == 0, "Initial done flag is clear")
	check(band(c.int_enable, cpu.INT_LPT) ~= 0, "Initial interrupt enable is set")

	-- 2. IOT Instructions: PSKF, PKSTF, PCLF
	print("[2/4] Testing Done Flag IOT Instructions...")
	-- PSKF (6661) should not skip when not done
	cpu.write_mem(c, oct"0200", oct"6661")
	c.pc = oct"0200"
	cpu.step(c)
	check(c.pc == oct"0201", "PSKF does not skip when done is clear")

	-- PKSTF (6660) sets done flag
	cpu.write_mem(c, oct"0201", oct"6660")
	cpu.step(c)
	check(band(c.dev_done, cpu.INT_LPT) ~= 0, "PKSTF sets done flag")

	-- PSKF now skips
	cpu.write_mem(c, oct"0202", oct"6661")
	cpu.step(c)
	check(c.pc == oct"0204", "PSKF skips when done flag is set")

	-- PCLF (6662) clears done flag
	cpu.write_mem(c, oct"0204", oct"6662")
	cpu.step(c)
	check(band(c.dev_done, cpu.INT_LPT) == 0, "PCLF clears done flag")

	-- 3. Printing Characters via PSTB & PCLF!PSTB
	print("[3/4] Testing Character Transmission & Output Streaming...")
	c.lac = string.byte("H")
	cpu.write_mem(c, oct"0205", oct"6664") -- PSTB
	cpu.step(c)
	check(lp.buf == string.byte("H"), "PSTB loaded buffer with 'H'")
	check(band(c.dev_done, cpu.INT_LPT) ~= 0, "PSTB sets done flag")

	-- PCLF!PSTB (6666)
	c.lac = string.byte("I")
	cpu.write_mem(c, oct"0206", oct"6666")
	cpu.step(c)
	check(lp.buf == string.byte("I"), "PCLF!PSTB loaded buffer with 'I'")
	check(le8e.get_output(lp) == "HI", "Accumulated output stream is 'HI'")

	-- 4. Interrupt Enable & Error Detection
	print("[4/4] Testing Interrupt Enables & Error Detection...")
	-- PCIE (6667) clears interrupt enable
	cpu.write_mem(c, oct"0207", oct"6667")
	cpu.step(c)
	check(band(c.int_enable, cpu.INT_LPT) == 0, "PCIE clears interrupt enable")

	-- PSIE (6665) sets interrupt enable
	cpu.write_mem(c, oct"0210", oct"6665")
	cpu.step(c)
	check(band(c.int_enable, cpu.INT_LPT) ~= 0, "PSIE sets interrupt enable")

	-- PSKE (6663) with no error
	le8e.set_error(lp, false)
	cpu.write_mem(c, oct"0211", oct"6663")
	cpu.step(c)
	check(c.pc == oct"0212", "PSKE does not skip when no error")

	-- PSKE with error set
	le8e.set_error(lp, true)
	cpu.write_mem(c, oct"0212", oct"6663")
	cpu.step(c)
	check(c.pc == oct"0214", "PSKE skips when error flag is set")

	print("==========================================")
	print(string.format("LE8-E Test Summary: %d passed, %d failed", tests_passed, tests_total - tests_passed))
	print("==========================================")
end

main()
