--[=[
 * decluau: tests/vc8e_test.luau - VC8-E / Type 34 CRT Display Unit Tests
 *
 * Copyright (c) 2026, decluau contributors.
 * Licensed under the BSD-2-Clause-Patent license.
 *
 * Comprehensive unit test suite for the Type 34 / VC8-E point plot display:
 * 1. Register initialization and deflection controls (dev 005 and 006).
 * 2. IOT micro-operations (DCX, DXL, DIX, DXS, DCY, DYL, DIY, DYS).
 * 3. 10-bit coordinate bounds, intensity accumulation and phosphor decay.
 * 4. OpenSIMH DEC dpy_test.do diagnostic program execution.
 * 5. Netpbm PPM (P6) binary raster export across phosphor profiles.
 ]=]

--!strict

local types = require("../common/types")
local cpu_mod = require("../pdp8/cpu")
local vc8e = require("../dev/vc8e")

local band = bit32.band
local bor = bit32.bor

local tests_passed = 0
local tests_failed = 0

local function check(cond: boolean, name: string)
	if cond then
		tests_passed += 1
		print(string.format("  PASS: %s", name))
	else
		tests_failed += 1
		print(string.format("! FAIL: %s", name))
	end
end

local function oct(s: string): number
	return tonumber(s, 8) :: number
end

local function exec_iot(cpu: cpu_mod.cpu_t, inst: number)
	cpu_mod.write_mem(cpu, cpu.pc, inst)
	local st = cpu_mod.step(cpu)
	assert(st == types.SCPE_OK, "step failed")
end

-- 1. Register States & Direct Deflection Controls
local function test_registers()
	print("[1/5] Testing VC8-E / Type 34 Register Deflection Controls...")
	local cpu = cpu_mod.new(32768)
	local dpy = vc8e.new("green")
	vc8e.attach(dpy, cpu)

	check(dpy.x == 0, "Initial X is 0")
	check(dpy.y == 0, "Initial Y is 0")
	check(dpy.points_plotted == 0, "Initial points plotted is 0")

	-- 6052 (DXL): Load X coordinate from AC
	cpu.lac = oct"00525" -- 341 decimal
	cpu.pc = oct"0100"
	exec_iot(cpu, oct"06052")
	check(dpy.x == oct"00525", "DXL loads X coordinate")

	-- 6051 (DCX): Clear X coordinate
	cpu.pc = oct"0100"
	exec_iot(cpu, oct"06051")
	check(dpy.x == 0, "DCX clears X coordinate")

	-- 6062 (DYL): Load Y coordinate from AC
	cpu.lac = oct"00712" -- 458 decimal
	cpu.pc = oct"0100"
	exec_iot(cpu, oct"06062")
	check(dpy.y == oct"00712", "DYL loads Y coordinate")

	-- 6061 (DCY): Clear Y coordinate
	cpu.pc = oct"0100"
	exec_iot(cpu, oct"06061")
	check(dpy.y == 0, "DCY clears Y coordinate")

	-- Coordinate masking (10 bits: 0..1023)
	cpu.lac = oct"07777" -- 12-bit max
	cpu.pc = oct"0100"
	exec_iot(cpu, oct"06052")
	check(dpy.x == 1023, "X coordinate masked to 10 bits (1023)")
end

-- 2. Point Plotting & Combined IOT Micro-operations
local function test_plotting()
	print("[2/5] Testing Point Plotting & Combined Micro-operations...")
	local cpu = cpu_mod.new(32768)
	local dpy = vc8e.new("green")
	vc8e.attach(dpy, cpu)

	-- Plot point at (200, 300) using individual loads and DIX
	cpu.lac = 200
	cpu.pc = oct"0100"
	exec_iot(cpu, oct"06052") -- DXL
	cpu.lac = 300
	cpu.pc = oct"0100"
	exec_iot(cpu, oct"06062") -- DYL
	cpu.pc = oct"0100"
	exec_iot(cpu, oct"06054") -- DIX (intensify)

	check(dpy.points_plotted == 1, "DIX increments points plotted")
	check(vc8e.get_pixel(dpy, 200, 300) == 255, "Pixel (200, 300) intensified")

	-- Clear X then combined 6056 (DXS): Load X and Intensify
	cpu.pc = oct"0100"
	exec_iot(cpu, oct"06051") -- DCX
	cpu.lac = 450
	cpu.pc = oct"0100"
	exec_iot(cpu, oct"06056") -- DXS
	check(dpy.points_plotted == 2, "DXS increments points plotted")
	check(dpy.x == 450, "DXS updates X register")
	check(vc8e.get_pixel(dpy, 450, 300) == 255, "Pixel (450, 300) intensified")

	-- Clear Y then combined 6066 (DYS): Load Y and Intensify
	cpu.pc = oct"0100"
	exec_iot(cpu, oct"06061") -- DCY
	cpu.lac = 600
	cpu.pc = oct"0100"
	exec_iot(cpu, oct"06066") -- DYS
	check(dpy.points_plotted == 3, "DYS increments points plotted")
	check(dpy.y == 600, "DYS updates Y register")
	check(vc8e.get_pixel(dpy, 450, 600) == 255, "Pixel (450, 600) intensified")

	-- Clear, load, and intensify: 6057
	cpu.lac = 100
	cpu.pc = oct"0100"
	exec_iot(cpu, oct"06057") -- DCX + DXL + DIX
	check(dpy.x == 100, "6057 sets X register to 100")
	check(vc8e.get_pixel(dpy, 100, 600) == 255, "Pixel (100, 600) intensified")
end

-- 3. Phosphor Persistence & Decay Simulation
local function test_phosphor_decay()
	print("[3/5] Testing CRT Phosphor Decay Simulation...")
	local dpy = vc8e.new("amber")

	-- Plot a single point
	vc8e.plot_point(dpy, 500, 500, 200)
	check(
		vc8e.get_pixel(dpy, 500, 500) == 200,
		"Point plotted at intensity 200"
	)

	-- Apply decay (factor = 0.5)
	vc8e.decay(dpy, 0.5)
	check(vc8e.get_pixel(dpy, 500, 500) == 100, "Phosphor decayed to 100")

	-- Another decay step
	vc8e.decay(dpy, 0.5)
	check(vc8e.get_pixel(dpy, 500, 500) == 50, "Phosphor decayed to 50")

	-- Multiple hits accumulate intensity up to saturation limit 255
	vc8e.plot_point(dpy, 500, 500, 150)
	check(
		vc8e.get_pixel(dpy, 500, 500) == 200,
		"Hits accumulate intensity (200)"
	)

	vc8e.plot_point(dpy, 500, 500, 100)
	check(vc8e.get_pixel(dpy, 500, 500) == 255, "Intensity saturates at 255")

	-- Clear resets all phosphor
	vc8e.clear(dpy)
	check(vc8e.get_pixel(dpy, 500, 500) == 0, "Clear resets framebuffer to 0")
end

-- 4. OpenSIMH DEC dpy_test.do Diagnostic Program
local function test_dec_program()
	print("[4/5] Executing DEC dpy_test.do Diagnostic Program...")
	local cpu = cpu_mod.new(32768)
	local dpy = vc8e.new("green")
	vc8e.attach(dpy, cpu)

	-- Program from OpenSIMH tests/dpy_test.do:
	-- 0200: 7200  CLA
	-- 0201: 1207  TAD 207 (1000 octal = 512 decimal)
	-- 0202: 6052  DXL (Load X = 512)
	-- 0203: 6066  DYS (Load Y = 512 and intensify: center point!)
	-- 0204: 1210  TAD 210 (400 octal = 256 decimal, AC = 768)
	-- 0205: 6056  DXS (Load X = 768 and intensify: right point!)
	-- 0206: 7402  HLT (modified from JMP 200 to halt after 1 frame)
	-- 0207: 1000  Constant 1000 octal (512)
	-- 0210: 0400  Constant 0400 octal (256)
	cpu_mod.write_mem(cpu, oct"00200", oct"07200")
	cpu_mod.write_mem(cpu, oct"00201", oct"01207")
	cpu_mod.write_mem(cpu, oct"00202", oct"06052")
	cpu_mod.write_mem(cpu, oct"00203", oct"06066")
	cpu_mod.write_mem(cpu, oct"00204", oct"01210")
	cpu_mod.write_mem(cpu, oct"00205", oct"06056")
	cpu_mod.write_mem(cpu, oct"00206", oct"07402") -- HLT
	cpu_mod.write_mem(cpu, oct"00207", oct"01000")
	cpu_mod.write_mem(cpu, oct"00210", oct"00400")

	cpu.pc = oct"00200"

	local steps = 0
	while not cpu.halted and steps < 20 do
		local st = cpu_mod.step(cpu)
		steps += 1
		if st == types.SCPE_HALT then
			break
		end
	end

	check(cpu.halted == true, "Program executed and halted")
	check(dpy.points_plotted == 2, "Exactly 2 points plotted by program")

	-- Point 1: center (512, 512)
	check(vc8e.get_pixel(dpy, 512, 512) == 255, "Center point (512, 512) lit")

	-- Point 2: mid-way to right (768, 512)
	check(vc8e.get_pixel(dpy, 768, 512) == 255, "Right point (768, 512) lit")

	-- Other pixels dark
	check(vc8e.get_pixel(dpy, 0, 0) == 0, "Background pixel (0, 0) dark")
	check(
		vc8e.get_pixel(dpy, 500, 500) == 0,
		"Background pixel (500, 500) dark"
	)
end

-- 5. Netpbm PPM (P6) Binary Raster Export
local function test_ppm_export()
	print("[5/5] Testing Netpbm PPM (P6) Raster Export...")
	local dpy = vc8e.new("green")

	-- Plot diagonal test line
	for i = 0, 99 do
		vc8e.plot_point(dpy, i, i, 255)
	end

	local ppm = vc8e.to_ppm(dpy)
	local expected_len = 17 + (1024 * 1024 * 3)
	check(
		buffer.len(ppm) == expected_len,
		"PPM output buffer matches 1024x1024x3"
	)

	local header = buffer.readstring(ppm, 0, 17)
	check(header == "P6\n1024 1024\n255\n", "PPM header is valid P6 format")

	-- Test amber profile export
	dpy.phosphor = "amber"
	local ppm_amber = vc8e.to_ppm(dpy)
	check(
		buffer.len(ppm_amber) == expected_len,
		"Amber PPM exported successfully"
	)

	-- Test white profile export
	dpy.phosphor = "white"
	local ppm_white = vc8e.to_ppm(dpy)
	check(
		buffer.len(ppm_white) == expected_len,
		"White PPM exported successfully"
	)
end

test_registers()
test_plotting()
test_phosphor_decay()
test_dec_program()
test_ppm_export()

print(string.format(
	"\nVC8-E Test Summary: %d passed, %d failed\n",
	tests_passed,
	tests_failed
))
if tests_failed > 0 then
	error("VC8-E tests failed")
end
