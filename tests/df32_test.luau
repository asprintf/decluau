--[=[
 * decluau: tests/df32_test.luau - DF32 / DS32 Fixed-Head Disk Unit Tests
 *
 * Copyright (c) 2026, decluau contributors.
 * Licensed under the BSD-2-Clause-Patent license.
 *
 * Comprehensive unit test suite for the DF32 / DS32 head-per-track disk:
 * 1. Register states, IOT decoding (060, 061, 062), skip conditions, photocell.
 * 2. 3-Cycle Data Break DMA write & read via Field 0 WC (07750) and MA (07751).
 * 3. Cross-field memory extension (MEX) and in-field address wraparound.
 * 4. Multi-platter disk addressing (DEX), write lock and NXD error detection.
 * 5. OS/8 and Disk Monitor 4 bootstrap execution.
 ]=]

--!strict

local types = require("../common/types")
local cpu_mod = require("../pdp8/cpu")
local df32 = require("../dev/df32")

local band = bit32.band
local bor = bit32.bor
local bxor = bit32.bxor
local rshift = bit32.rshift
local lshift = bit32.lshift

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

-- 1. Register States & IOT Instructions
local function test_registers_and_iots()
	print("[1/5] Testing DF32 Register States & IOT Instructions...")
	local cpu = cpu_mod.new(32768)
	local df = df32.new(1)
	df32.attach(df, cpu)

	-- Initial state: done = true, da = 0, sta = 0
	check(df.done == true, "Initial done flag is true")
	check(df.da == 0, "Initial disk address is 0")
	check(df.sta == 0, "Initial status register is 0")

	-- 6622 (DFSC): Skip if Done
	cpu.pc = oct"0100"
	exec_iot(cpu, oct"06622") -- 6622 DFSC
	check(cpu.pc == oct"0102", "DFSC skips when done is true (pc 100 -> 102)")

	-- 6601 (DCMA): Clear disk address, done, errors, int
	cpu.pc = oct"0100"
	df.da = oct"01234"
	exec_iot(cpu, oct"06601") -- 6601 DCMA
	check(df.da == 0, "DCMA clears disk address")
	check(df.done == false, "DCMA clears done flag")

	-- Now DFSC should not skip
	cpu.pc = oct"0100"
	exec_iot(cpu, oct"06622") -- 6622 DFSC
	check(
		cpu.pc == oct"0101",
		"DFSC does not skip when done is false (pc 100 -> 101)"
	)

	-- 6621 (DFSE): Skip if No Error
	cpu.pc = oct"0100"
	exec_iot(cpu, oct"06621") -- 6621 DFSE
	check(cpu.pc == oct"0102", "DFSE skips when no error present")

	-- Inject error into status
	df.sta = bor(df.sta, df32.DFS_PER)
	cpu.pc = oct"0100"
	exec_iot(cpu, oct"06621") -- 6621 DFSE
	check(cpu.pc == oct"0101", "DFSE does not skip when error present")

	-- DCMA clears errors
	cpu.pc = oct"0100"
	exec_iot(cpu, oct"06601") -- 6601 DCMA
	check(band(df.sta, df32.DFS_ERR) == 0, "DCMA clears error bits")

	-- 6615 (DCEA + DEAL): Load DEX/MEX and OR old status into AC
	df.sta = 0
	local test_ext = bor(df32.DFS_DEX, df32.DFS_MEX)
	cpu.lac = test_ext
	cpu.pc = oct"0100"
	exec_iot(cpu, oct"06615") -- 6615 DCEA + DEAL
	check(band(df.sta, df32.DFS_DEX) == df32.DFS_DEX, "DEAL loads DEX bits")
	check(band(df.sta, df32.DFS_MEX) == df32.DFS_MEX, "DEAL loads MEX bits")
	check(
		band(cpu.lac, 0xFFF) == test_ext,
		"DEAC returns AC | old_status in AC"
	)

	-- 6616 (DSAC + DEAC): Clears AC and loads old status
	cpu.lac = oct"07777" -- AC filled with 1s
	cpu.pc = oct"0100"
	exec_iot(cpu, oct"06616") -- 6616 DSAC + DEAC
	check(
		band(cpu.lac, bor(df32.DFS_DEX, df32.DFS_MEX)) == test_ext,
		"6616 clears AC and loads old status DEX/MEX"
	)

	-- 6611 (DCEA): Clear DEX and MEX
	cpu.pc = oct"0100"
	exec_iot(cpu, oct"06611") -- 6611 DCEA
	check(
		band(df.sta, bor(df32.DFS_DEX, df32.DFS_MEX)) == 0,
		"DCEA clears DEX and MEX"
	)

	-- 6624 / 6626 (DMAC): Read Disk Address into AC
	df.da = oct"01753"
	cpu.lac = 0x1000 -- AC = 0, Link = 1
	cpu.pc = oct"0100"
	exec_iot(cpu, oct"06624") -- 6624 DMAC (OR into AC)
	check(band(cpu.lac, 0xFFF) == oct"01753", "DMAC 6624 reads DA into AC")
	check(band(cpu.lac, 0x1000) == 0x1000, "DMAC preserves Link")

	cpu.lac = oct"01077" -- AC has old data
	cpu.pc = oct"0100"
	exec_iot(cpu, oct"06626") -- 6626 DMAC (Clear AC then read DA)
	check(
		band(cpu.lac, 0xFFF) == oct"01753",
		"DMAC 6626 clears AC and loads DA"
	)

	-- Photocell status
	df.step_count = 0
	df32.update_photocell(df)
	check(
		band(df.sta, df32.DFS_PCA) ~= 0,
		"Photocell pulse active when pos < 6"
	)

	df.step_count = 100
	df32.update_photocell(df)
	check(
		band(df.sta, df32.DFS_PCA) == 0,
		"Photocell pulse inactive when pos >= 6"
	)
end

-- 2. 3-Cycle Data Break DMA Write and Read Transfers
local function test_dma_transfers()
	print("[2/5] Testing 3-Cycle Data Break DMA Write & Read...")
	local cpu = cpu_mod.new(32768)
	local df = df32.new(1)
	local disk_buf = df32.create_disk(1)
	df32.set_image(df, disk_buf, 1)
	df32.attach(df, cpu)

	-- Populate Field 0 memory at 02000..02077 octal (64 words) with test data
	local test_words = 64
	for i = 0, test_words - 1 do
		cpu_mod.write_mem(cpu, oct"02000" + i, oct"0100" + i)
	end

	-- Setup 3-Cycle Data Break vectors in Field 0:
	-- DF_WC (07750): Two's complement of word count (-64 = 4096 - 64 = 4032)
	-- DF_MA (07751): Memory start address minus 1 (02000 - 1 = 01777 octal)
	cpu_mod.write_mem(cpu, df32.DF_WC, 4096 - test_words)
	cpu_mod.write_mem(cpu, df32.DF_MA, oct"02000" - 1)

	-- Issue 6605 (DCMA + DMAW) with target disk address 01000 in AC
	cpu.lac = oct"01000"
	cpu.pc = oct"0100"
	exec_iot(cpu, oct"06605") -- 6605 DCMA + DMAW
	check(df.busy == true, "DMAW sets busy flag")
	check(df.done == false, "DMAW clears done flag")
	check(band(cpu.lac, 0xFFF) == 0, "DMAW clears AC")

	-- Step CPU to allow 10-cycle latency and DMA transfer execution
	step_n(cpu, 12)

	check(df.busy == false, "Transfer completed, busy is false")
	check(df.done == true, "Transfer completed, done is true")
	check(cpu_mod.read_mem(cpu, df32.DF_WC) == 0, "Word Count reached 0")
	check(
		cpu_mod.read_mem(cpu, df32.DF_MA) == oct"02000" + test_words - 1,
		"Memory Address reached end of block"
	)
	-- On write, DA reflects last word written
	check(
		df.da == oct"01000" + test_words - 1,
		"Disk address reflects last word written"
	)

	-- Verify data was written to disk buffer
	local write_ok = true
	for i = 0, test_words - 1 do
		local val = buffer.readu16(disk_buf, (oct"01000" + i) * 2)
		if val ~= (oct"0100" + i) then
			write_ok = false
			break
		end
	end
	check(write_ok, "Disk image received exact 64 words from memory")

	-- Clear memory block 02000..02077 octal to zeros
	for i = 0, test_words - 1 do
		cpu_mod.write_mem(cpu, oct"02000" + i, 0)
	end

	-- Now perform DMA Read back from disk to memory
	cpu_mod.write_mem(cpu, df32.DF_WC, 4096 - test_words)
	cpu_mod.write_mem(cpu, df32.DF_MA, oct"02000" - 1)
	cpu.lac = oct"01000"
	cpu.pc = oct"0100"
	exec_iot(cpu, oct"06603") -- 6603 DCMA + DMAR
	step_n(cpu, 12)

	check(df.done == true, "DMAR completed, done is true")
	-- On read, DA reflects next word to be read
	check(
		df.da == oct"01000" + test_words,
		"Disk address reflects next word to read"
	)

	-- Verify memory has been restored
	local read_ok = true
	for i = 0, test_words - 1 do
		local val = cpu_mod.read_mem(cpu, oct"02000" + i)
		if val ~= (oct"0100" + i) then
			read_ok = false
			break
		end
	end
	check(read_ok, "Memory restored with exact 64 words from disk")

	-- Verify interrupt line was asserted
	check(
		band(cpu.dev_done, cpu_mod.INT_DF) ~= 0,
		"INT_DF set upon DMA completion"
	)
end

-- 3. Cross-Field Memory Transfers (MEX) and Field Wraparound
local function test_cross_field_and_wraparound()
	print("[3/5] Testing Cross-Field MEX & In-Field Wraparound...")
	local cpu = cpu_mod.new(32768)
	local df = df32.new(1)
	local disk_buf = df32.create_disk(1)
	df32.set_image(df, disk_buf, 1)
	df32.attach(df, cpu)

	-- Set MEX to Field 2 (020 octal in status bits 3..5: 2 << 3 = 020)
	df.sta = bor(df.sta, oct"00020")
	local field2_base = 2 * 4096 -- 8192

	-- Write 32 words to Field 2 at offset 0300 octal
	for i = 0, 31 do
		cpu_mod.write_mem(cpu, field2_base + oct"0300" + i, oct"07000" + i)
	end

	-- DF_WC and DF_MA remain in Field 0 (07750 and 07751 octal)
	cpu_mod.write_mem(cpu, df32.DF_WC, 4096 - 32)
	cpu_mod.write_mem(cpu, df32.DF_MA, oct"0300" - 1)

	cpu.lac = oct"00400" -- Disk address 00400 octal
	cpu.pc = oct"0100"
	exec_iot(cpu, oct"06605") -- 6605 DCMA + DMAW
	step_n(cpu, 12)

	check(df.done == true, "Cross-field DMA write completed")
	local cf_write_ok = true
	for i = 0, 31 do
		local val = buffer.readu16(disk_buf, (oct"00400" + i) * 2)
		if val ~= (oct"07000" + i) then
			cf_write_ok = false
			break
		end
	end
	check(cf_write_ok, "Data written correctly from Field 2 to disk")

	-- Field wraparound test:
	-- Start transfer at MA = 07770 in Field 2. Transfer of 32 words
	-- should write: 8 words at 07770..07777 octal, and 24 words
	-- wrapping around to 00000..00027 octal in Field 2!
	for i = 0, 7 do
		cpu_mod.write_mem(cpu, field2_base + oct"07770" + i, oct"01000" + i)
	end
	for i = 0, 23 do
		cpu_mod.write_mem(cpu, field2_base + i, oct"02000" + i)
	end

	cpu_mod.write_mem(cpu, df32.DF_WC, 4096 - 32)
	cpu_mod.write_mem(cpu, df32.DF_MA, oct"07770" - 1)
	cpu.lac = oct"02000" -- Disk address 02000 octal
	cpu.pc = oct"0100"
	exec_iot(cpu, oct"06605") -- 6605 DCMA + DMAW
	step_n(cpu, 12)

	check(df.done == true, "Wraparound DMA write completed")
	local wrap_ok = true
	for i = 0, 7 do
		local val = buffer.readu16(disk_buf, (oct"02000" + i) * 2)
		if val ~= (oct"01000" + i) then
			wrap_ok = false
		end
	end
	for i = 0, 23 do
		local val = buffer.readu16(disk_buf, (oct"02000" + 8 + i) * 2)
		if val ~= (oct"02000" + i) then
			wrap_ok = false
		end
	end
	check(wrap_ok, "Address wraparound within field transferred correctly")
end

-- 4. Multi-Platter Support (DEX), Write Lock & NXD Errors
local function test_platters_and_errors()
	print("[4/5] Testing Multi-Platter DEX, Write Lock & NXD Errors...")
	local cpu = cpu_mod.new(32768)
	-- Create 4-platter disk system (128KW = 131,072 words)
	local df = df32.new(4)
	local disk_buf = df32.create_disk(4)
	df32.set_image(df, disk_buf, 4)
	df32.attach(df, cpu)

	check(df.capac == 131072, "4-platter disk capacity is 131,072 words")

	-- Platter 2 start address = 2 * 32,768 = 65,536 (0200000 octal)
	-- In DEX (status bits 6..10): 65536 >> 12 = 16 = 00020 octal = 0x10.
	-- Shifted to status bits 6..10: 0x10 << 6 = 0x400 = 02000 octal.
	df.sta = bor(df.sta, oct"02000") -- DEX selects platter 2

	-- Write 16 words to Platter 2 at relative DA 0100 octal
	for i = 0, 15 do
		cpu_mod.write_mem(cpu, oct"01000" + i, oct"03333" + i)
	end
	cpu_mod.write_mem(cpu, df32.DF_WC, 4096 - 16)
	cpu_mod.write_mem(cpu, df32.DF_MA, oct"01000" - 1)
	cpu.lac = oct"0100" -- DA relative to platter 2
	cpu.pc = oct"0100"
	exec_iot(cpu, oct"06604") -- 6604 DMAW (keep DEX)
	step_n(cpu, 12)

	check(df.done == true, "Multi-platter write completed")
	local p2_ok = true
	for i = 0, 15 do
		local val = buffer.readu16(disk_buf, (65536 + oct"0100" + i) * 2)
		if val ~= (oct"03333" + i) then
			p2_ok = false
			break
		end
	end
	check(p2_ok, "Data written to Platter 2 at offset 65536+0100")

	-- Non-existent disk error test:
	-- Single-platter disk (capac = 32768). Access Platter 1 (DEX = 01000)
	local cpu_err = cpu_mod.new(32768)
	local df1 = df32.new(1)
	local disk1 = df32.create_disk(1)
	df32.set_image(df1, disk1, 1)
	df32.attach(df1, cpu_err)

	df1.sta = oct"01000" -- Platter 1 (addr >= 32768) on a 1-platter system
	cpu_mod.write_mem(cpu_err, df32.DF_WC, 4096 - 16)
	cpu_mod.write_mem(cpu_err, df32.DF_MA, oct"01000" - 1)
	cpu_err.lac = 0
	cpu_err.pc = oct"0100"
	exec_iot(cpu_err, oct"06604") -- 6604 DMAW
	step_n(cpu_err, 12)

	check(band(df1.sta, df32.DFS_NXD) ~= 0, "Non-existent disk sets DFS_NXD")

	-- Write lock error test:
	-- Lock quadrant 0 (words 0..16383): df.wlk bit 0 = 1
	df.sta = 0
	df.wlk = 1 -- Lock lower 16KW
	cpu_mod.write_mem(cpu, df32.DF_WC, 4096 - 16)
	cpu_mod.write_mem(cpu, df32.DF_MA, oct"01000" - 1)
	cpu.lac = oct"00100"
	cpu.pc = oct"0100"
	exec_iot(cpu, oct"06605") -- 6605 DCMA + DMAW
	step_n(cpu, 12)

	check(
		band(df.sta, df32.DFS_WLS) ~= 0,
		"Write to locked quadrant sets DFS_WLS"
	)
end

-- 5. Bootstrap Execution (OS/8 and Disk Monitor 4)
local function test_bootstrap()
	print("[5/5] Testing OS/8 & Disk Monitor 4 Bootstrap...")
	local cpu = cpu_mod.new(32768)
	local df = df32.new(1)
	local disk_buf = df32.create_disk(1)
	df32.set_image(df, disk_buf, 1)
	df32.attach(df, cpu)

	-- Place boot sector on disk starting at DA 0:
	-- OS/8 bootloader entry point is at 06622 octal.
	-- Put an instruction at 06622 octal: 7402 octal (HLT).
	-- Boot block loads 128 words from DA 0 into 06604..07753 octal.
	-- DA offset for memory 06622: (06622 - 06604) octal = 14 words.
	local boot_entry_da = oct"06622" - oct"06604"
	buffer.writeu16(disk_buf, boot_entry_da * 2, oct"07402") -- HLT opcode

	-- Install OS/8 ROM
	df32.boot(df, cpu, "os8")
	check(cpu.pc == oct"07750", "OS/8 bootstrap sets PC to 07750")

	-- Run bootstrap until HLT (entry point reached at 06622 octal)
	local steps = 0
	while not cpu.halted and steps < 200 do
		local st = cpu_mod.step(cpu)
		steps += 1
		if st == types.SCPE_HALT then
			break
		end
	end

	check(cpu.halted == true, "OS/8 bootstrap loaded block and halted at 06622")
	check(cpu.pc == oct"06623", "PC stopped right after HLT at 06622")

	-- Disk Monitor 4 bootstrap test
	cpu.halted = false
	df32.boot(df, cpu, "dm4")
	check(cpu.pc == oct"00200", "DM4 bootstrap sets PC to 00200")
	check(
		cpu_mod.read_mem(cpu, df32.DF_WC) == oct"07576",
		"DM4 loads WC at 07750"
	)
	check(
		cpu_mod.read_mem(cpu, df32.DF_MA) == oct"07576",
		"DM4 loads MA at 07751"
	)
end

test_registers_and_iots()
test_dma_transfers()
test_cross_field_and_wraparound()
test_platters_and_errors()
test_bootstrap()

print(string.format(
	"\nDF32 Test Summary: %d passed, %d failed\n",
	tests_passed,
	tests_failed
))
if tests_failed > 0 then
	error("DF32 tests failed")
end
