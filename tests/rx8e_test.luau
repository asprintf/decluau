--[=[
 * decluau: tests/rx8e_test.luau - RX8-E / RX01 Floppy Disk Unit Tests
 *
 * Copyright (c) 2026, decluau contributors.
 * Licensed under the BSD-2-Clause-Patent license.
 *
 * Comprehensive unit test suite for the RX8-E / RX01 floppy disk controller:
 * 1. Controller reset, register states, and IOT instruction decoding
 *    (6751..6757).
 * 2. 12-bit word packing into 8-bit sector buffer (FILL and EMPTY commands).
 * 3. 8-bit byte streaming mode buffer transfers.
 * 4. Sector Read / Write operations across track and sector addressing.
 * 5. Multi-drive selection (Drive 0 and 1) and error handling.
 * 6. DEC RX01 hardware bootstrap execution.
 ]=]

--!strict

local types = require("../common/types")
local cpu_mod = require("../pdp8/cpu")
local rx8e = require("../dev/rx8e")

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
	print("[1/6] Testing RX8-E Controller Reset & Register Flags...")
	local cpu = cpu_mod.new(32768)
	local rx = rx8e.new()
	rx8e.attach(rx, cpu)

	check(rx.done == true, "Initial done is true")
	check(rx.tr == false, "Initial TR is false")
	check(rx.err == false, "Initial ERR is false")
	check(rx.int_enable == false, "Initial interrupt enable is false")

	-- 6755 (SDN): Skip on Done
	cpu.pc = oct"0100"
	exec_iot(cpu, oct"06755") -- SDN
	check(
		cpu.pc == oct"0102",
		"SDN skips when done is true (pc 100 -> 102)"
	)
	check(rx.done == false, "SDN clears done flag")

	-- SDN when done is false
	cpu.pc = oct"0100"
	exec_iot(cpu, oct"06755")
	check(cpu.pc == oct"0101", "SDN does not skip when done is false")

	-- 6756 (INTR): Enable interrupts
	cpu.lac = 1
	cpu.pc = oct"0100"
	exec_iot(cpu, oct"06756")
	check(rx.int_enable == true, "INTR enables interrupts")

	cpu.lac = 0
	cpu.pc = oct"0100"
	exec_iot(cpu, oct"06756")
	check(rx.int_enable == false, "INTR disables interrupts")

	-- 6757 (INIT): Reset controller
	cpu.pc = oct"0100"
	exec_iot(cpu, oct"06757")
	check(rx.done == true, "INIT sets done flag")
	check(rx.drives[1].track == 1, "INIT sets Drive 0 to track 1")
	check(rx.drives[2].track == 0, "INIT sets Drive 1 to track 0")
end

-- 2. 12-Bit Word Packing & Buffer Transfers (FILL and EMPTY)
local function test_12bit_buffer()
	print("[2/6] Testing 12-Bit Word Packing (FILL & EMPTY)...")
	local cpu = cpu_mod.new(32768)
	local rx = rx8e.new()
	rx8e.attach(rx, cpu)

	-- Issue FILL command (function = 0, 12-bit mode): AC = 0
	cpu.lac = 0
	cpu.pc = oct"0100"
	exec_iot(cpu, oct"06751") -- 6751 LCD
	check(rx.done == false, "LCD clears done flag")
	check(rx.tr == true, "FILL asserts TR for word 0")

	-- Transfer 64 test 12-bit words into sector buffer
	for i = 0, 63 do
		check(
			rx.tr == true,
			string.format("TR asserted for word %d", i)
		)
		cpu.lac = oct"04000" + i -- 12-bit word
		cpu.pc = oct"0100"
		exec_iot(cpu, oct"06752") -- 6752 XDR
	end

	check(rx.done == true, "FILL completes after 64 words, sets done")

	-- Issue EMPTY command (function = 1, AC = 1 << 1 = 2): AC = 2
	cpu.lac = lshift(rx8e.RXCS_EMPTY, 1)
	cpu.pc = oct"0100"
	exec_iot(cpu, oct"06751") -- 6751 LCD
	check(rx.done == false, "LCD clears done flag for EMPTY")

	-- Read back 64 words and verify exact values
	local empty_ok = true
	for i = 0, 63 do
		cpu.pc = oct"0100"
		exec_iot(cpu, oct"06752") -- 6752 XDR
		local val = band(cpu.lac, 0xFFF)
		if val ~= (oct"04000" + i) then
			empty_ok = false
			break
		end
	end
	check(empty_ok, "EMPTY retrieved exact 64 12-bit words")
	check(rx.done == true, "EMPTY completes after 64 words, sets done")
end

-- 3. 8-Bit Byte Mode Buffer Transfers
local function test_8bit_buffer()
	print("[3/6] Testing 8-Bit Byte Mode Buffer Transfers...")
	local cpu = cpu_mod.new(32768)
	local rx = rx8e.new()
	rx8e.attach(rx, cpu)

	-- Issue FILL command in 8-bit mode (RXCS_MODE = 0100 octal = 0x40)
	cpu.lac = rx8e.RXCS_MODE -- FILL + 8-bit mode
	cpu.pc = oct"0100"
	exec_iot(cpu, oct"06751") -- LCD

	-- Transfer 128 bytes
	for i = 0, 127 do
		cpu.lac = band(0x80 + i, 0xFF)
		cpu.pc = oct"0100"
		exec_iot(cpu, oct"06752") -- XDR
	end
	check(rx.done == true, "8-bit FILL completes after 128 bytes")

	-- Issue EMPTY command in 8-bit mode
	cpu.lac = bor(lshift(rx8e.RXCS_EMPTY, 1), rx8e.RXCS_MODE)
	cpu.pc = oct"0100"
	exec_iot(cpu, oct"06751") -- LCD

	local empty_8b_ok = true
	for i = 0, 127 do
		cpu.pc = oct"0100"
		exec_iot(cpu, oct"06752") -- XDR
		local val = band(cpu.lac, 0xFF)
		if val ~= band(0x80 + i, 0xFF) then
			empty_8b_ok = false
			break
		end
	end
	check(empty_8b_ok, "8-bit EMPTY retrieved exact 128 bytes")
end

-- 4. Sector Read & Write Operations
local function test_sector_read_write()
	print("[4/6] Testing Sector Read & Write Operations...")
	local cpu = cpu_mod.new(32768)
	local rx = rx8e.new()
	local disk = rx8e.create_disk()
	rx8e.set_image(rx, 0, disk)
	rx8e.attach(rx, cpu)

	-- Fill buffer with 64 words
	cpu.lac = 0 -- FILL
	cpu.pc = oct"0100"
	exec_iot(cpu, oct"06751")
	for i = 0, 63 do
		cpu.lac = oct"01234" + i
		cpu.pc = oct"0100"
		exec_iot(cpu, oct"06752")
	end

	-- Issue WRITE command (function 2): AC = 2 << 1 = 4
	cpu.lac = lshift(rx8e.RXCS_WRITE, 1)
	cpu.pc = oct"0100"
	exec_iot(cpu, oct"06751") -- LCD
	check(rx.tr == true, "WRITE command asserts TR for sector")

	-- Send sector 5
	cpu.lac = 5
	cpu.pc = oct"0100"
	exec_iot(cpu, oct"06752") -- XDR
	check(rx.tr == true, "XDR asserts TR for track")

	-- Send track 10
	cpu.lac = 10
	cpu.pc = oct"0100"
	exec_iot(cpu, oct"06752") -- XDR
	check(rx.tr == false, "XDR starts transfer, clears TR")

	-- Step CPU to allow seek and sector write
	step_n(cpu, 10)
	check(rx.done == true, "Sector write completed, done is true")
	check(rx.err == false, "Sector write completed without error")

	-- Clear internal sector buffer
	for i = 0, 127 do
		buffer.writeu8(rx.buf, i, 0)
	end

	-- Issue READ command (function 3): AC = 3 << 1 = 6
	cpu.lac = lshift(rx8e.RXCS_READ, 1)
	cpu.pc = oct"0100"
	exec_iot(cpu, oct"06751") -- LCD

	-- Send sector 5
	cpu.lac = 5
	cpu.pc = oct"0100"
	exec_iot(cpu, oct"06752")

	-- Send track 10
	cpu.lac = 10
	cpu.pc = oct"0100"
	exec_iot(cpu, oct"06752")

	step_n(cpu, 10)
	check(rx.done == true, "Sector read completed, done is true")

	-- Now empty buffer and verify written data was read back
	cpu.lac = lshift(rx8e.RXCS_EMPTY, 1)
	cpu.pc = oct"0100"
	exec_iot(cpu, oct"06751")

	local readback_ok = true
	for i = 0, 63 do
		cpu.pc = oct"0100"
		exec_iot(cpu, oct"06752")
		if band(cpu.lac, 0xFFF) ~= (oct"01234" + i) then
			readback_ok = false
			break
		end
	end
	check(readback_ok, "Read sector data matches written sector data")
end

-- 5. Multi-Drive Selection & Error Detection
local function test_drives_and_errors()
	print("[5/6] Testing Multi-Drive Selection & Error Detection...")
	local cpu = cpu_mod.new(32768)
	local rx = rx8e.new()
	local disk1 = rx8e.create_disk()
	-- Attach only to Drive 1 (Drive 0 remains unattached)
	rx8e.set_image(rx, 1, disk1)
	rx8e.attach(rx, cpu)

	-- Attempt READ on unattached Drive 0: command = READ (6) + Unit 0 (0)
	cpu.lac = lshift(rx8e.RXCS_READ, 1)
	cpu.pc = oct"0100"
	exec_iot(cpu, oct"06751")
	cpu.lac = 1 -- sector 1
	cpu.pc = oct"0100"
	exec_iot(cpu, oct"06752")
	cpu.lac = 1 -- track 1
	cpu.pc = oct"0100"
	exec_iot(cpu, oct"06752")
	step_n(cpu, 10)

	check(rx.err == true, "Unattached drive sets ERR flag")

	-- 6754 (SER): Skip on Error
	cpu.pc = oct"0100"
	exec_iot(cpu, oct"06754") -- SER
	check(cpu.pc == oct"0102", "SER skips when error is true")
	check(rx.err == false, "SER clears ERR flag")

	-- Now access attached Drive 1: RXCS_DRV = 0x10
	cpu.lac = bor(lshift(rx8e.RXCS_READ, 1), rx8e.RXCS_DRV)
	cpu.pc = oct"0100"
	exec_iot(cpu, oct"06751")
	cpu.lac = 1
	cpu.pc = oct"0100"
	exec_iot(cpu, oct"06752")
	cpu.lac = 1
	cpu.pc = oct"0100"
	exec_iot(cpu, oct"06752")
	step_n(cpu, 10)

	check(rx.err == false, "Attached Drive 1 completes without error")
end

-- 6. DEC RX01 Hardware Bootstrap Execution
local function test_bootstrap()
	print("[6/6] Testing DEC RX01 Hardware Bootstrap Execution...")
	local cpu = cpu_mod.new(32768)
	local rx = rx8e.new()
	local disk = rx8e.create_disk()
	rx8e.set_image(rx, 0, disk)
	rx8e.attach(rx, cpu)

	-- Put a boot sector on disk at Track 1, Sector 1:
	local sector_offset = (1 * 26 + 0) * 128
	-- Prepare 64 sector words: Word 0 = HLT (07402), words 1..15 = NOP
	-- (07000)
	local sector_words: { number } = {}
	for i = 0, 63 do
		sector_words[i + 1] = oct"07000"
	end
	sector_words[1] = oct"07402" -- Stored at location 0002

	for i = 1, #rx8e.BOOT_ROM do
		local entry = rx8e.BOOT_ROM[i]
		local word_idx = entry.addr - 2
		if word_idx >= 0 and word_idx < 64 then
			sector_words[word_idx + 1] = entry.val
		end
	end
	-- Location 0050 octal (word 38): as the bootloader runs, location 0050
	-- self-modifies from DCA 2 (03002) up to DCA 50 (03050). Preserving
	-- its running state prevents resetting dest pointer mid-transfer.
	sector_words[38 + 1] = oct"03050"

	-- Pack 64 12-bit words into 96 bytes at sector_offset
	for i = 0, 63 do
		local w = sector_words[i + 1]
		local byptr = sector_offset + math.floor((3 * i) / 2)
		if band(i, 1) ~= 0 then
			local prev = buffer.readu8(disk, byptr)
			buffer.writeu8(
				disk,
				byptr,
				bor(band(prev, 0xF0), band(rshift(w, 8), 0xF))
			)
			buffer.writeu8(disk, byptr + 1, band(w, 0xFF))
		else
			buffer.writeu8(disk, byptr, band(rshift(w, 4), 0xFF))
			buffer.writeu8(disk, byptr + 1, lshift(band(w, 0xF), 4))
		end
	end

	-- Install RX8-E bootloader for unit 0
	rx8e.boot(rx, cpu, 0)
	check(
		cpu.pc == oct"00022",
		"RX bootloader initializes PC to 00022 octal"
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

	check(cpu.halted == true, "RX bootloader loaded sector and halted")
	check(cpu_mod.read_mem(cpu, 2) == oct"07402", "Location 2 contains HLT")
end

test_registers_and_iots()
test_12bit_buffer()
test_8bit_buffer()
test_sector_read_write()
test_drives_and_errors()
test_bootstrap()

print(string.format(
	"\nRX8-E Test Summary: %d passed, %d failed\n",
	tests_passed,
	tests_failed
))
if tests_failed > 0 then
	error("RX8-E tests failed")
end
