--[=[
 * decluau: tests/rk8e_test.luau - RK8-E / RK05 & DK8-EA Unit Tests
 *
 * Copyright (c) 2026, decluau contributors.
 * Licensed under the BSD-2-Clause-Patent license.
 ]=]

--!strict

local types = require("../common/types")
local cpu_mod = require("../pdp8/cpu")
local rk8e = require("../dev/rk8e")
local dk8ea = require("../dev/dk8ea")

local band = bit32.band
local bor = bit32.bor
local lshift = bit32.lshift
local rshift = bit32.rshift

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

-- Helper: execute an IOT instruction on CPU
local function exec_iot(cpu: cpu_mod.cpu_t, inst: number)
	cpu.mem = cpu.mem -- suppress unused warning
	cpu_mod.write_mem(cpu, cpu.pc, inst)
	local st = cpu_mod.step(cpu)
	assert(st == types.SCPE_OK, "step failed")
end

-- 1. Test Controller Reset and Initial State
local function test_init()
	print("[1/5] Testing RK8-E Controller Reset & Register Access...")
	local cpu = cpu_mod.new(32768)
	local rk = rk8e.new()
	rk8e.attach(rk, cpu)

	check(rk.sta == 0, "Initial status register is 0")
	check(rk.cmd == 0, "Initial command register is 0")
	check(rk.da == 0, "Initial disk address is 0")
	check(rk.ma == 0, "Initial memory address is 0")
	check(rk.busy == false, "Initial busy flag is false")

	-- Test DLDC (6746): Load command
	cpu.lac = 0x0525 -- 02445 octal: function 2 (WLK), MEX=2, unit=2
	exec_iot(cpu, 0x0DE6) -- 6746 DLDC
	check(rk.cmd == 0x0525, "DLDC loads command register")
	check(band(cpu.lac, 0xFFF) == 0, "DLDC clears AC")

	-- Test DLCA (6744): Load memory address
	cpu.lac = 0x0750
	exec_iot(cpu, 0x0DE4) -- 6744 DLCA
	check(rk.ma == 0x0750, "DLCA loads memory address register")
	check(band(cpu.lac, 0xFFF) == 0, "DLCA clears AC")

	-- Test DCLR (6742): Clear control (AC & 3 == 1)
	cpu.lac = 1 -- CLC
	exec_iot(cpu, 0x0DE2) -- 6742 DCLR
	check(rk.cmd == 0, "DCLR (CLC) clears command register")
	check(rk.ma == 0, "DCLR (CLC) clears memory address register")
	check(band(cpu.lac, 0xFFF) == 0, "DCLR clears AC")

	-- Test DRST (6745): Read status
	rk.sta = 0x0800 -- RKS_DONE
	cpu.lac = 0x1000 -- Set Link
	exec_iot(cpu, 0x0DE5) -- 6745 DRST
	check(band(cpu.lac, 0x0800) == 0x0800, "DRST reads DONE status into AC")
	check(band(cpu.lac, 0x0080) == 0x0080, "DRST reports NRDY for unattached drive")
	check(band(cpu.lac, 0x1000) == 0x1000, "DRST preserves Link")

	-- Test DSKP (6741): Skip on done/error
	rk.sta = 0x0800
	local old_pc = cpu.pc
	exec_iot(cpu, 0x0DE1) -- 6741 DSKP
	check(cpu.pc == band(old_pc + 2, 0xFFF), "DSKP skips when DONE is set")

	rk.sta = 0
	old_pc = cpu.pc
	exec_iot(cpu, 0x0DE1) -- 6741 DSKP
	check(cpu.pc == band(old_pc + 1, 0xFFF), "DSKP does not skip when idle")
end

-- 2. Test Sector Write and Readback
local function test_sector_rw()
	print("[2/5] Testing RK8-E Sector Read / Write...")
	local cpu = cpu_mod.new(32768)
	local rk = rk8e.new()
	rk8e.attach(rk, cpu)

	local img = buffer.create(rk8e.RK_BYTES)
	rk8e.attach_drive(rk, 0, img)

	-- Populate Field 0 memory buffer with 256 distinct words
	local mem_buf_addr = 0x0200
	for i = 0, 255 do
		local val = band(i * 17 + 0x0ABC, 0xFFF)
		cpu_mod.write_mem(cpu, mem_buf_addr + i, val)
	end

	-- Target disk address: cylinder 25, surface 1, sector 9
	local da = bor(lshift(25, 5), lshift(1, 4), 9)

	-- Write: DLCA = 0200, DLDC = Write (func 4, MEX 0, unit 0)
	cpu.lac = mem_buf_addr
	exec_iot(cpu, 0x0DE4) -- 6744 DLCA
	cpu.lac = lshift(4, 9) -- Write function
	exec_iot(cpu, 0x0DE6) -- 6746 DLDC
	cpu.lac = da
	exec_iot(cpu, 0x0DE3) -- 6743 DLAG

	-- Run CPU until DMA completes
	while rk.busy do
		cpu_mod.step(cpu)
	end

	check(band(rk.sta, 0x800) ~= 0, "Write sector sets RKS_DONE")
	check(rk.ma == band(mem_buf_addr + 256, 0xFFF), "Write increments MA")

	-- Clear memory buffer in Field 1 (offset 0x1000 words = 4096)
	local read_buf_addr = 0x1400
	for i = 0, 255 do
		cpu_mod.write_mem(cpu, read_buf_addr + i, 0)
	end

	-- Read: DLCA = 0400, DLDC = Read (func 0, MEX 1, unit 0)
	cpu.lac = 0x0400
	exec_iot(cpu, 0x0DE4) -- 6744 DLCA
	cpu.lac = bor(lshift(0, 9), lshift(1, 3)) -- Read func, MEX=1
	exec_iot(cpu, 0x0DE6) -- 6746 DLDC
	cpu.lac = da
	exec_iot(cpu, 0x0DE3) -- 6743 DLAG

	while rk.busy do
		cpu_mod.step(cpu)
	end

	check(band(rk.sta, 0x800) ~= 0, "Read sector sets RKS_DONE")

	local match = true
	for i = 0, 255 do
		local expected = band(i * 17 + 0x0ABC, 0xFFF)
		local actual = cpu_mod.read_mem(cpu, read_buf_addr + i)
		if actual ~= expected then
			match = false
			break
		end
	end
	check(match, "Readback data matches written data word-for-word")
end

-- 3. Test Field Wraparound DMA
local function test_field_wrap()
	print("[3/5] Testing RK8-E Field Wraparound DMA...")
	local cpu = cpu_mod.new(32768)
	local rk = rk8e.new()
	rk8e.attach(rk, cpu)

	local img = buffer.create(rk8e.RK_BYTES)
	rk8e.attach_drive(rk, 0, img)

	-- Start address near the top of Field 0: 07700 octal = 0x0FC0
	-- 256 words will transfer 64 words at 0FC0..0FFF and 192 words at 0000..00BF
	local start_ma = 0x0FC0
	for i = 0, 63 do
		cpu_mod.write_mem(cpu, start_ma + i, band(0x0100 + i, 0xFFF))
	end
	for i = 0, 191 do
		cpu_mod.write_mem(cpu, i, band(0x0200 + i, 0xFFF))
	end

	local da = 0x0010
	cpu.pc = 0x0500
	cpu.lac = start_ma
	exec_iot(cpu, 0x0DE4) -- DLCA
	cpu.lac = lshift(4, 9) -- Write, Field 0
	exec_iot(cpu, 0x0DE6) -- DLDC
	cpu.lac = da
	exec_iot(cpu, 0x0DE3) -- DLAG

	while rk.busy do
		cpu_mod.step(cpu)
	end

	check(rk.ma == band(start_ma + 256, 0xFFF), "MA wrapped correctly")

	-- Clear memory in Field 2
	for i = 0, 4095 do
		cpu_mod.write_mem(cpu, 0x2000 + i, 0)
	end

	-- Read back into Field 2 starting at 0x0FC0
	cpu.pc = 0x0500
	cpu.lac = start_ma
	exec_iot(cpu, 0x0DE4) -- DLCA
	cpu.lac = bor(lshift(0, 9), lshift(2, 3)) -- Read, Field 2
	exec_iot(cpu, 0x0DE6) -- DLDC
	cpu.lac = da
	exec_iot(cpu, 0x0DE3) -- DLAG

	while rk.busy do
		cpu_mod.step(cpu)
	end

	local wrap_ok = true
	for i = 0, 63 do
		local actual = cpu_mod.read_mem(cpu, 0x2000 + start_ma + i)
		if actual ~= band(0x0100 + i, 0xFFF) then
			wrap_ok = false
			break
		end
	end
	for i = 0, 191 do
		if cpu_mod.read_mem(cpu, 0x2000 + i) ~= band(0x0200 + i, 0xFFF) then
			wrap_ok = false
			break
		end
	end
	check(wrap_ok, "Cross-field wraparound transferred data accurately")
end

-- 4. Test Hardware ROM Bootstrap Loader
local function test_boot_rom()
	print("[4/5] Testing RK8-E 8-Word ROM Bootstrap Sequence...")
	local cpu = cpu_mod.new(32768)
	local rk = rk8e.new()
	rk8e.attach(rk, cpu)

	local img = buffer.create(rk8e.RK_BYTES)
	rk8e.attach_drive(rk, 0, img)

	-- Populate sector 0 with a test boot program:
	-- 0030: 6741 DSKP
	-- 0031: 5030 JMP 30
	-- 0032: 7000 NOP
	-- 0033: 7402 HLT
	buffer.writeu16(img, 0x18 * 2, 0x0DE1) -- 0030: 6741 DSKP
	buffer.writeu16(img, 0x19 * 2, 0x0A18) -- 0031: 5030 JMP 30
	buffer.writeu16(img, 0x1A * 2, 0x0E00) -- 0032: 7000 NOP
	buffer.writeu16(img, 0x1B * 2, 0x0F02) -- 0033: 7402 HLT

	rk8e.install_boot(cpu, 0)
	check(cpu.pc == 0x13, "Boot entry point loaded to 0023")

	local steps = 0
	while not cpu.halted and steps < 200 do
		cpu_mod.step(cpu)
		steps += 1
	end

	check(cpu.halted, "CPU successfully booted sector 0 and reached HLT")
	check(cpu.pc == 0x1C, "CPU halted at address 0034")
	check(steps < 100, string.format("Boot sequence completed in %d steps", steps))
end

-- 5. Test DK8-EA Real-Time Line Clock
local function test_dk8ea()
	print("[5/5] Testing DK8-EA Real-Time Clock...")
	local cpu = cpu_mod.new(32768)
	local clk = dk8ea.new(10)
	dk8ea.attach(clk, cpu)

	-- Test CLEI (6131): Enable clock interrupts
	exec_iot(cpu, 0x0C59) -- 6131 CLEI
	check(band(cpu.int_enable, cpu_mod.INT_CLK) ~= 0, "CLEI enables clock int")

	-- Test CLDI (6132): Disable clock interrupts
	exec_iot(cpu, 0x0C5A) -- 6132 CLDI
	check(band(cpu.int_enable, cpu_mod.INT_CLK) == 0, "CLDI disables clock int")

	-- Step CPU 10 times to trigger clock tick
	for _ = 1, 10 do
		cpu_mod.step(cpu)
	end
	check(band(cpu.dev_done, cpu_mod.INT_CLK) ~= 0, "Clock ticks after interval")

	-- Test CLSK (6133): Skip and clear
	local old_pc = cpu.pc
	exec_iot(cpu, 0x0C5B) -- 6133 CLSK
	check(cpu.pc == band(old_pc + 2, 0xFFF), "CLSK skips on clock tick")
	check(band(cpu.dev_done, cpu_mod.INT_CLK) == 0, "CLSK clears clock flag")
end

local function main()
	print("========================================")
	print("Running PDP-8 RK8-E & DK8-EA Unit Tests")
	print("========================================")
	test_init()
	test_sector_rw()
	test_field_wrap()
	test_boot_rom()
	test_dk8ea()
	print("========================================")
	print(string.format("Passed: %d, Failed: %d", tests_passed, tests_failed))
	print("========================================")
	if tests_failed > 0 then
		error("Tests failed")
	end
end

main()
