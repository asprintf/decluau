--[=[
 * decluau: tests/ta8e_test.luau - TA8-E / TU60 Cassette Controller Unit Tests
 *
 * Copyright (c) 2026, decluau contributors.
 * Licensed under the BSD-2-Clause-Patent license.
 ]=]

--!strict

local types = require("../common/types")
local cpu_mod = require("../pdp8/cpu")
local ta8e = require("../dev/ta8e")

local band = bit32.band
local bor = bit32.bor
local bxor = bit32.bxor

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

local function exec_iot(cpu: cpu_mod.cpu_t, inst: number)
	cpu_mod.write_mem(cpu, cpu.pc, inst)
	local st = cpu_mod.step(cpu)
	assert(st == types.SCPE_OK, "step failed")
end

-- 1. Test Controller Reset and Status Flags
local function test_init()
	print("[1/4] Testing TA8-E Controller Reset & Register Flags...")
	local cpu = cpu_mod.new(32768)
	local ct = ta8e.new()
	ta8e.attach(ct, cpu)

	-- Enable drive 0 (0200 octal = 0x80) to inspect unattached drive
	cpu.lac = 0x80
	exec_iot(cpu, 0x0DC4) -- 6704 KLSA
	cpu.lac = 0
	exec_iot(cpu, 0x0DC7) -- 6707 KSRB
	check(band(cpu.lac, 0x08) ~= 0, "Unattached drive sets SRB_EMP")

	-- Attach dummy tape buffer
	local tape = buffer.create(1024)
	ta8e.attach_tape(ct, 0, tape)

	-- Load SRA: enable drive 0 (0200 octal = 0x80)
	cpu.lac = 0x80
	exec_iot(cpu, 0x0DC4) -- 6704 KLSA
	check(ct.sra == 0x80, "KLSA loads SRA")
	check(band(cpu.lac, 0xFF) == bxor(0x80, 0xFF), "KLSA returns SRA ^ 0xFF")

	-- Now check SRB: drive attached and ready
	cpu.lac = 0
	exec_iot(cpu, 0x0DC7) -- 6707 KSRB
	check(band(cpu.lac, 0x01) ~= 0, "Attached drive reports SRB_RDY")
	check(band(cpu.lac, 0x08) == 0, "Attached drive clears SRB_EMP")
end

-- 2. Test Record Write and CRC Generation
local function test_write_record()
	print("[2/4] Testing TA8-E Record Write with CRC...")
	local cpu = cpu_mod.new(32768)
	local ct = ta8e.new()
	ta8e.attach(ct, cpu)

	local tape = buffer.create(4096)
	ta8e.attach_tape(ct, 0, tape)

	-- Select Write on Drive 0: SRA = ENAB | WRITE = 0x80 | 0x10 = 0x90
	cpu.lac = 0x90
	exec_iot(cpu, 0x0DC4) -- KLSA

	-- Write 5 test bytes: [0x41, 0x42, 0x43, 0x44, 0x45] ("ABCDE")
	local payload = { 0x41, 0x42, 0x43, 0x44, 0x45 }
	for i = 1, #payload do
		cpu.lac = payload[i]
		exec_iot(cpu, 0x0DC6) -- KGOA
		check(ct.df, string.format("Byte %d triggers data flag", i))
	end

	-- Switch to CRC mode to finalize block: SRA = ENAB | CRC = 0x80 | 0x30 = 0xB0
	cpu.lac = 0xB0
	exec_iot(cpu, 0x0DC4) -- KLSA
	cpu.lac = 0
	exec_iot(cpu, 0x0DC6) -- KGOA (finalize CRC and write record)

	-- Verify record layout in tape image:
	-- Header: 32-bit count (5)
	local bc = buffer.readu32(tape, 0)
	check(bc == 5, "Tape header has 32-bit count = 5")

	-- Data bytes
	local data_ok = true
	for i = 1, 5 do
		if buffer.readu8(tape, 4 + i - 1) ~= payload[i] then
			data_ok = false
			break
		end
	end
	check(data_ok, "Tape contains payload bytes ABCDE")

	-- Trailing count at offset 4 + 5 + 1 (odd pad) = 10
	local trail_bc = buffer.readu32(tape, 10)
	check(trail_bc == 5, "Tape trailer has matching 32-bit count = 5")
end

-- 3. Test Record Read and Byte Streaming
local function test_read_record()
	print("[3/4] Testing TA8-E Record Read & Data Flag Streaming...")
	local cpu = cpu_mod.new(32768)
	local ct = ta8e.new()
	ta8e.attach(ct, cpu)

	-- Pre-populate tape buffer with 4-byte record "TEST" (0x54, 0x45, 0x53, 0x54)
	local tape = buffer.create(4096)
	buffer.writeu32(tape, 0, 4)
	buffer.writeu8(tape, 4, 0x54)
	buffer.writeu8(tape, 5, 0x45)
	buffer.writeu8(tape, 6, 0x53)
	buffer.writeu8(tape, 7, 0x54)
	buffer.writeu32(tape, 8, 4)
	ta8e.attach_tape(ct, 0, tape)

	-- Select Read: SRA = ENAB | READ = 0x80 | 0x00 = 0x80
	cpu.lac = 0x80
	exec_iot(cpu, 0x0DC4) -- KLSA
	cpu.lac = 0
	exec_iot(cpu, 0x0DC6) -- KGOA (start read)

	local read_bytes = {}
	for _ = 1, 4 do
		check(ct.df, "Data flag asserted for read byte")
		cpu.lac = 0
		exec_iot(cpu, 0x0DC6) -- KGOA: reads byte into AC
		table.insert(read_bytes, band(cpu.lac, 0xFF))
	end

	check(read_bytes[1] == 0x54, "Read byte 1 = 'T'")
	check(read_bytes[2] == 0x45, "Read byte 2 = 'E'")
	check(read_bytes[3] == 0x53, "Read byte 3 = 'S'")
	check(read_bytes[4] == 0x54, "Read byte 4 = 'T'")
end

-- 4. Test File Gap & Spacing Operations
local function test_gaps_and_spacing()
	print("[4/4] Testing File Gaps & Space Operations...")
	local cpu = cpu_mod.new(32768)
	local ct = ta8e.new()
	ta8e.attach(ct, cpu)

	local tape = buffer.create(4096)
	ta8e.attach_tape(ct, 0, tape)

	-- Write a file gap: SRA = ENAB | WFG = 0x80 | 0x20 = 0xA0
	cpu.lac = 0xA0
	exec_iot(cpu, 0x0DC4) -- KLSA
	cpu.lac = 0
	exec_iot(cpu, 0x0DC6) -- KGOA
	check(buffer.readu32(tape, 0) == 0, "WFG writes 0-byte file gap")

	-- Rewind: SRA = ENAB | REW = 0x80 | 0x08 = 0x88
	cpu.lac = 0x88
	exec_iot(cpu, 0x0DC4) -- KLSA
	cpu.lac = 0
	exec_iot(cpu, 0x0DC6) -- KGOA
	check(ct.drives[1].pos == 0, "Rewind resets tape position to 0")

	-- Read at file gap should trigger EOF
	cpu.lac = 0x80 -- READ
	exec_iot(cpu, 0x0DC4) -- KLSA
	cpu.lac = 0
	exec_iot(cpu, 0x0DC6) -- KGOA
	check(band(ct.srb, 0x10) ~= 0, "Reading file gap sets SRB_EOF")
end

-- 5. Test Hardware Cassette Bootstrap Loader
local function test_boot_rom()
	print("[5/5] Testing TA8-E Hardware Bootstrap Loader...")
	local cpu = cpu_mod.new(32768)
	local ct = ta8e.new()
	ta8e.attach(ct, cpu)

	local boot_pc = ta8e.install_boot(cpu)
	check(boot_pc == 0x800, "Cassette boot entry point loaded to 04000 octal")
	check(cpu.pc == 0x800, "CPU PC initialized to boot entry point")
	check(cpu_mod.read_mem(cpu, 0x800) == 0x029F, "Bootloader first word verified")
end

local function main()
	print("========================================")
	print("Running PDP-8 TA8-E Cassette Unit Tests")
	print("========================================")
	test_init()
	test_write_record()
	test_read_record()
	test_gaps_and_spacing()
	test_boot_rom()
	print("========================================")
	print(string.format("Passed: %d, Failed: %d", tests_passed, tests_failed))
	print("========================================")
	if tests_failed > 0 then
		error("Tests failed")
	end
end

main()
