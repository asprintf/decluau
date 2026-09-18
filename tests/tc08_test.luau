--[=[
 * decluau: tests/tc08_test.luau - TC08 / TU56 DECtape Unit Tests
 *
 * Copyright (c) 2026, decluau contributors.
 * Licensed under the BSD-2-Clause-Patent license.
 *
 * Comprehensive unit test suite for the TC08 / TU56 DECtape controller:
 * 1. Controller reset, register states, and IOT instruction decoding
 *    (6761..6766, 6771..6774).
 * 2. Unattached unit selection and error handling (DTB_SEL, DTB_ERF).
 * 3. Search operation (FNC_SRCH) and block number reporting via CA.
 * 4. Block Read / Write operations via 3-Cycle Data Break (07754/07755).
 * 5. Memory Extension cross-field addressing (DTB_MEX).
 * 6. Write lock protection switch handling.
 * 7. Official DEC 4K DMS / OS/8 hardware bootstrap execution.
 ]=]

--!strict

local types = require("../common/types")
local cpu_mod = require("../pdp8/cpu")
local tc08 = require("../dev/tc08")

local band = bit32.band
local bor = bit32.bor
local bnot = bit32.bnot
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

local function oct(s: string): number
	return tonumber(s, 8) :: number
end

local function step_n(cpu: cpu_mod.cpu_t, n: number)
	for _ = 1, n do
		local st = cpu_mod.step(cpu)
		assert(st == types.SCPE_OK, "step failed")
	end
end

local function exec_iot(cpu: cpu_mod.cpu_t, inst: number)
	cpu_mod.write_mem(cpu, cpu.pc, inst)
	local st = cpu_mod.step(cpu)
	assert(st == types.SCPE_OK, "step failed")
end

-- 1. Controller Reset & IOT Instruction Decoding
local function test_registers_and_iots()
	print("[1/6] Testing TC08 Controller Reset & IOT Instructions...")
	local cpu = cpu_mod.new(32768)
	local tc = tc08.new()
	tc08.attach(tc, cpu)

	check(tc.dtsa == 0, "Initial Status A is 0")
	check(tc.dtsb == 0, "Initial Status B is 0")

	-- 6771 (DTSF): Skip on Flag or Error (initially neither, no skip)
	cpu.pc = oct"0100"
	exec_iot(cpu, oct"06771")
	check(cpu.pc == oct"0101", "DTSF does not skip when idle")

	-- 6774 (DTLB): Load MEX into Status B (Field 1 = 0010 octal = 0x08)
	cpu.lac = 0x08
	cpu.pc = oct"0100"
	exec_iot(cpu, oct"06774") -- DTLB
	check(
		band(tc.dtsb, tc08.DTB_MEX) == 0x08,
		"DTLB loads MEX into Status B"
	)
	check(band(cpu.lac, 0xFFF) == 0, "DTLB clears AC")

	-- 6772 (DTRB): Read Status B
	cpu.lac = 0
	cpu.pc = oct"0100"
	exec_iot(cpu, oct"06772") -- DTRB
	check(band(cpu.lac, 0xFFF) == 0x08, "DTRB reads Status B into AC")

	-- Attach tape image to Unit 0
	local tape0 = tc08.create_tape()
	tc08.set_image(tc, 0, tape0)

	-- 6764 (DTXA): Load Status A (Enable Interrupts + Start Motion)
	-- AC = DTA_ENB (0004) | DTA_STSTP (0200) | DTA_CERF | DTA_CDTF
	cpu.lac = bor(
		tc08.DTA_ENB,
		tc08.DTA_STSTP,
		tc08.DTA_CERF,
		tc08.DTA_CDTF
	)
	cpu.pc = oct"0100"
	exec_iot(cpu, oct"06764")
	check(band(cpu.lac, 0xFFF) == 0, "DTXA clears AC")
	check(band(tc.dtsa, tc08.DTA_ENB) ~= 0, "DTXA sets interrupt enable")

	-- 6761 (DTRA): Read Status A
	cpu.lac = 0
	cpu.pc = oct"0100"
	exec_iot(cpu, oct"06761")
	check(band(cpu.lac, 0xFFF) == tc.dtsa, "DTRA reads Status A into AC")

	-- 6762 (DTCA): Clear Status A
	cpu.pc = oct"0100"
	exec_iot(cpu, oct"06762")
	check(tc.dtsa == 0, "DTCA clears Status A")
end

-- 2. Unattached Unit Selection & Error Handling
local function test_unattached_unit_error()
	print("[2/6] Testing Unattached Unit Select Error Detection...")
	local cpu = cpu_mod.new(32768)
	local tc = tc08.new()
	tc08.attach(tc, cpu)

	-- Select unattached Unit 1 (Unit 1 << 9 = 01000 octal = 0x0200)
	-- Function 2 (READ = 2 << 3 = 0020 octal = 0x10)
	-- DTA_STSTP (0200 octal = 0x80)
	cpu.lac = bor(lshift(1, 9), lshift(tc08.FNC_READ, 3), tc08.DTA_STSTP)
	cpu.pc = oct"0100"
	exec_iot(cpu, oct"06766") -- DTCA!DTXA

	check(
		band(tc.dtsb, tc08.DTB_SEL) ~= 0,
		"Select error set on unattached"
	)
	check(band(tc.dtsb, tc08.DTB_ERF) ~= 0, "Error flag set in Status B")

	-- 6771 (DTSF): Skip on Error
	cpu.pc = oct"0100"
	exec_iot(cpu, oct"06771")
	check(cpu.pc == oct"0102", "DTSF skips when error flag is set")

	-- Clear error using DTXA with CERF bit 0 and stop motion (XOR STSTP)
	cpu.lac = tc08.DTA_STSTP
	cpu.pc = oct"0100"
	exec_iot(cpu, oct"06764")
	check(band(tc.dtsb, tc08.DTB_ERF) == 0, "DTXA with CERF clears error")
end

-- 3. Search Operation (FNC_SRCH)
local function test_search_operation()
	print("[3/6] Testing DECtape Search Operation (FNC_SRCH)...")
	local cpu = cpu_mod.new(32768)
	local tc = tc08.new()
	local tape0 = tc08.create_tape()
	tc08.set_image(tc, 0, tape0)
	tc08.attach(tc, cpu)

	-- Set Word Count (07754) to -1 (07777) so first match triggers flag
	cpu_mod.write_mem(cpu, tc08.DT_WC, oct"07777")
	-- Set Current Address (07755) to 00200 octal
	cpu_mod.write_mem(cpu, tc08.DT_CA, oct"00200")

	-- Position tape at block 10
	tc.drives[1].block = 10

	-- Issue SEARCH command forward:
	-- Unit 0, FNC_SRCH (1 << 3 = 010 octal), Start motion (0200 octal)
	cpu.lac = bor(lshift(tc08.FNC_SRCH, 3), tc08.DTA_STSTP)
	cpu.pc = oct"0100"
	exec_iot(cpu, oct"06766") -- DTCA!DTXA

	-- Step CPU to advance tape
	step_n(cpu, 5)

	check(band(tc.dtsb, tc08.DTB_DTF) ~= 0, "Search completed, DTF set")
	check(
		cpu_mod.read_mem(cpu, oct"00200") == 11,
		"Next block number (11) written to CA (00200)"
	)
	check(tc.drives[1].block == 11, "Tape advanced to block 11")
end

-- 4. Block Read and Write via 3-Cycle Data Break
local function test_block_read_write()
	print("[4/6] Testing Block Read & Write via 3-Cycle Data Break...")
	local cpu = cpu_mod.new(32768)
	local tc = tc08.new()
	local tape0 = tc08.create_tape()
	tc08.set_image(tc, 0, tape0)
	tc08.attach(tc, cpu)

	-- Populate memory buffer at 01000..01200 with test pattern
	for i = 0, 128 do
		cpu_mod.write_mem(cpu, oct"01000" + i, oct"05000" + i)
	end

	-- Prepare WC and CA in Field 0:
	-- WC = -129 = 4096 - 129 = 3967 = 07577 octal
	cpu_mod.write_mem(cpu, tc08.DT_WC, oct"07577")
	-- CA = 00777 (so first word written from 00777 + 1 = 01000)
	cpu_mod.write_mem(cpu, tc08.DT_CA, oct"00777")

	-- Position tape at block 20
	tc.drives[1].block = 20

	-- Issue WRITE command forward: FNC_WRIT (4 << 3 = 040 octal = 0x20)
	cpu.lac = bor(lshift(tc08.FNC_WRIT, 3), tc08.DTA_STSTP)
	cpu.pc = oct"0100"
	exec_iot(cpu, oct"06766") -- DTCA!DTXA

	step_n(cpu, 5)
	check(
		band(tc.dtsb, tc08.DTB_DTF) ~= 0,
		"Block write completed, DTF set"
	)

	-- Verify block on tape buffer directly
	local write_ok = true
	for i = 0, 128 do
		local val = tc08.read_tape_word(tape0, 20, i)
		if val ~= (oct"05000" + i) then
			write_ok = false
			break
		end
	end
	check(write_ok, "Tape block 20 contains exact 129 written words")

	-- Now read back into memory at 03000..03200
	-- Clear DTF
	tc.dtsb = band(tc.dtsb, bnot(tc08.DTB_DTF))
	cpu_mod.write_mem(cpu, tc08.DT_WC, oct"07577")
	cpu_mod.write_mem(cpu, tc08.DT_CA, oct"02777") -- reads to 03000..03200

	tc.drives[1].block = 20 -- Rewind to block 20
	cpu.lac = bor(lshift(tc08.FNC_READ, 3), tc08.DTA_STSTP)
	cpu.pc = oct"0100"
	exec_iot(cpu, oct"06766") -- DTCA!DTXA

	step_n(cpu, 5)
	check(band(tc.dtsb, tc08.DTB_DTF) ~= 0, "Block read completed, DTF set")

	local read_ok = true
	for i = 0, 128 do
		local val = cpu_mod.read_mem(cpu, oct"03000" + i)
		if val ~= (oct"05000" + i) then
			read_ok = false
			break
		end
	end
	check(read_ok, "Memory at 03000..03200 matches tape block data")
end

-- 5. Memory Extension (KM8-E) Cross-Field DMA
local function test_cross_field_dma()
	print("[5/6] Testing Memory Extension Cross-Field Transfers (MEX)...")
	local cpu = cpu_mod.new(32768)
	local tc = tc08.new()
	local tape0 = tc08.create_tape()
	tc08.set_image(tc, 0, tape0)
	tc08.attach(tc, cpu)

	-- Put known words on tape block 5
	for i = 0, 128 do
		tc08.write_tape_word(tape0, 5, i, oct"04321" + i)
	end

	-- Set Status B to Field 1 (MEX = 1 << 3 = 0010 octal = 0x08)
	cpu.lac = 0x08
	cpu.pc = oct"0100"
	exec_iot(cpu, oct"06774") -- DTLB

	-- Configure Field 0 Data Break vectors:
	cpu_mod.write_mem(cpu, tc08.DT_WC, oct"07577") -- 129 words
	-- target in Field 1: 02000
	cpu_mod.write_mem(cpu, tc08.DT_CA, oct"01777")

	-- Read block 5 into Field 1
	tc.drives[1].block = 5
	cpu.lac = bor(lshift(tc08.FNC_READ, 3), tc08.DTA_STSTP)
	cpu.pc = oct"0100"
	exec_iot(cpu, oct"06766")

	step_n(cpu, 5)
	check(
		band(tc.dtsb, tc08.DTB_DTF) ~= 0,
		"Field 1 read completed, DTF set"
	)

	-- Check that data was written to Field 1 (010000 + 02000)
	local field1_addr = oct"010000" + oct"02000"
	local field1_ok = true
	for i = 0, 128 do
		local target = cpu_mod.read_mem(cpu, field1_addr + i)
		if target ~= (oct"04321" + i) then
			field1_ok = false
			break
		end
	end
	check(field1_ok, "Field 1 received block data accurately")
end

-- 6. DEC 4K DMS / OS/8 Hardware Bootstrap Execution
local function test_bootstrap()
	print("[6/6] Testing DEC 4K DMS / OS/8 Hardware Bootstrap Routine...")
	local cpu = cpu_mod.new(32768)
	local tc = tc08.new()
	local tape0 = tc08.create_tape()
	tc08.set_image(tc, 0, tape0)
	tc08.attach(tc, cpu)

	-- On block 0 of tape, place a boot program starting at word 0:
	-- The bootstrap reads into 07600 (starting from CA = 07577).
	-- Let's put a HLT (07402) at word 0 of block 0 (which lands at 07600):
	tc08.write_tape_word(tape0, 0, 0, oct"07402") -- HLT at 07600
	-- Word 1..128: NOP (07000)
	for i = 1, 128 do
		tc08.write_tape_word(tape0, 0, i, oct"07000")
	end

	-- Install TC08 bootstrap loader for Unit 0
	tc08.boot(tc, cpu, 0)
	check(
		cpu.pc == oct"00200",
		"TC08 bootstrap initializes PC to 00200 octal"
	)

	-- Step CPU until HLT reached
	local steps = 0
	while not cpu.halted and steps < 2000 do
		local st = cpu_mod.step(cpu)
		steps += 1
		if st == types.SCPE_HALT then
			break
		end
	end

	check(cpu.halted == true, "TC08 bootloader executed and halted")
	check(
		cpu_mod.read_mem(cpu, oct"07600") == oct"07402",
		"Location 07600 loaded with HLT from tape block 0"
	)
end

test_registers_and_iots()
test_unattached_unit_error()
test_search_operation()
test_block_read_write()
test_cross_field_dma()
test_bootstrap()

print(string.format(
	"\nTC08 Test Summary: %d passed, %d failed\n",
	tests_passed,
	tests_failed
))
if tests_failed > 0 then
	error("TC08 tests failed")
end
