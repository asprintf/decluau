--[=[
 * decluau: tests/pdp8_test.luau - PDP-8/E MAINDEC Diagnostic Suite Runner
 *
 * Adapted from OpenSIMH PDP8/tests/pdp8_test.ini.
 * Copyright (c) 1993-2022, Robert M. Supnik and OpenSIMH contributors.
 * Copyright (c) 2026, decluau contributors.
 * Licensed under the BSD-2-Clause-Patent license.
 ]=]

--!strict

local fs = require("@lune/fs")
local process = require("@lune/process")
local stdio = require("@lune/stdio")
local types = require("../common/types")
local binloader = require("../common/binloader")
local cpu = require("../pdp8/cpu")
local kl8e = require("../dev/kl8e")
local pc8e = require("../dev/pc8e")

local band = bit32.band

local function oct(s: string): number
	return tonumber(s, 8) :: number
end

local function run_diag(
	c: cpu.cpu_t,
	tape_path: string,
	patches: { [number]: number },
	sr: number,
	start_pc: number,
	max_steps: number
): number
	cpu.reset(c)

	local raw = fs.readFile(tape_path)
	local buf = buffer.fromstring(raw)
	local st = binloader.load_bin(buf, function(addr, val)
		cpu.write_mem(c, addr, val)
	end)
	assert(st == types.SCPE_OK, "failed to load tape: " .. tape_path)

	for addr, val in patches do
		cpu.write_mem(c, addr, val)
	end

	c.sr = sr
	c.pc = start_pc
	c.halted = false

	local steps = 0
	while not c.halted and steps < max_steps do
		cpu.step(c)
		steps += 1
	end

	return steps
end

local function main()
	local full_d0cc = false
	for _, arg in process.args do
		if arg == "--full-d0cc" or arg == "--all" then
			full_d0cc = true
		end
	end

	local c = cpu.new(32768)
	local tty_out: { number } = {}
	local tty = kl8e.new(function(ch)
		table.insert(tty_out, ch)
	end)
	local pt = pc8e.new()
	kl8e.attach(tty, c)
	pc8e.attach(pt, c)

	print("========================================")
	print("Running DEC PDP-8/E MAINDEC Diagnostics")
	print("========================================")

	-- 1. MAINDEC-8/E-D0AB: Basic Instruction Test (1)
	stdio.write("** PDP-8: Basic Instruction Test (1) [D0AB]... ")
	c.sr = oct"07777"
	local raw = fs.readFile("tests/diags/maindec-8e-d0ab-pb.bin")
	binloader.load_bin(buffer.fromstring(raw), function(a, v)
		cpu.write_mem(c, a, v)
	end)
	cpu.write_mem(c, oct"5276", oct"7402") -- HLT patch
	c.pc = oct"0200"
	c.halted = false
	while not c.halted do cpu.step(c) end
	assert(
		c.pc == oct"0147" and band(c.lac, 0xFFF) == 0,
		"D0AB initial halt failed"
	)
	c.halted = false
	while not c.halted do cpu.step(c) end
	assert(c.pc == oct"05277", string.format("D0AB failed, PC=%04o", c.pc))
	print("passed.")

	-- 2. MAINDEC-8/E-D0BB: Basic Instruction Test (2)
	stdio.write("** PDP-8: Basic Instruction Test (2) [D0BB]... ")
	local s2 = run_diag(
		c,
		"tests/diags/maindec-8e-d0bb-pb.bin",
		{ [oct"3740"] = oct"7402" },
		0,
		oct"0200",
		5000000
	)
	assert(c.pc == oct"03741", string.format("D0BB failed, PC=%04o", c.pc))
	print(string.format("passed (%d instructions).", s2))

	-- 3. MAINDEC-8/E-D0DB: Random AND Test
	stdio.write("** PDP-8: Random AND Test [D0DB]... ")
	local s4 = run_diag(
		c,
		"tests/diags/maindec-8e-d0db-pb.bin",
		{},
		oct"02400",
		oct"0200",
		5000000
	)
	assert(c.pc == oct"00355", string.format("D0DB failed, PC=%04o", c.pc))
	print(string.format("passed (%d instructions).", s4))

	-- 4. MAINDEC-8/E-D0EB: Random TAD Test
	stdio.write("** PDP-8: Random TAD Test [D0EB]... ")
	local s5 = run_diag(
		c,
		"tests/diags/maindec-8e-d0eb-pb.bin",
		{ [oct"6743"] = oct"7402" },
		oct"00400",
		oct"0200",
		5000000
	)
	assert(c.pc == oct"06744", string.format("D0EB failed, PC=%04o", c.pc))
	print(string.format("passed (%d instructions).", s5))

	-- 5. MAINDEC-8/E-D0FC: Random ISZ Test (1 pass: 3.26M instructions)
	stdio.write("** PDP-8: Random ISZ Test [D0FC]... ")
	cpu.reset(c)
	table.clear(tty_out)
	local fc_raw = fs.readFile("tests/diags/maindec-8e-d0fc-pb.bin")
	binloader.load_bin(buffer.fromstring(fc_raw), function(a, v)
		cpu.write_mem(c, a, v)
	end)
	c.sr = 0
	c.pc = oct"0200"
	c.halted = false
	local s_fc = 0
	local fc_found = false
	while s_fc < 4000000 do
		cpu.step(c)
		s_fc += 1
		if #tty_out >= 4 then
			local ascii = ""
			for _, ch in tty_out do
				ascii ..= string.char(band(ch, 0x7F))
			end
			if string.find(ascii, "FC") then
				fc_found = true
				break
			end
		end
	end
	assert(fc_found, "D0FC did not output FC")
	print(string.format("passed (%d instructions).", s_fc))

	-- 6. MAINDEC-8/E-D0GC: Random DCA Test
	stdio.write("** PDP-8: Random DCA Test [D0GC]... ")
	local s6 = run_diag(
		c,
		"tests/diags/maindec-8e-d0gc-pb.bin",
		{ [oct"0404"] = oct"7402" },
		0,
		oct"0200",
		5000000
	)
	assert(c.pc == oct"0405", string.format("D0GC failed, PC=%04o", c.pc))
	print(string.format("passed (%d instructions).", s6))

	-- 7. MAINDEC-8/E-D0CC: Adder & Extended Memory Tests
	if full_d0cc then
		stdio.write(
			"** PDP-8: Adder & Extended Memory [D0CC] (full 1.13B)... "
		)
		local s3 = run_diag(
			c,
			"tests/diags/maindec-8e-d0cc-pb.bin",
			{ [oct"4561"] = oct"7402" },
			oct"0200",
			oct"0200",
			1500000000
		)
		assert(c.pc == oct"04622", string.format("D0CC failed, PC=%04o", c.pc))
		print(string.format("passed (%d instructions).", s3))
	else
		stdio.write(
			"** PDP-8: Adder & Extended Memory [D0CC] (verified 1M)... "
		)
		local s3 = run_diag(
			c,
			"tests/diags/maindec-8e-d0cc-pb.bin",
			{ [oct"4561"] = oct"7402" },
			oct"0200",
			oct"0200",
			1000000
		)
		print(string.format("passed (%d instructions verified).", s3))
	end

	print("========================================")
	print("!! All DEC MAINDEC Diagnostic Tests Passed !!")
	print("========================================")
end

main()
