--[=[
 * decluau: tests/pdp8_cpu_test.luau - Unit tests for subtle PDP-8/E CPU behaviors
 *
 * Verifies the 5 subtle architecture behaviors:
 * 1. Auto-Indexing (locations 0010-0017 in current IF)
 * 2. CIF Delayed Branching (IB latched until next JMP/JMS, interrupt inhibit)
 * 3. Interrupt Delay after ION (1-instruction safety window)
 * 4. User Mode Restriction (KM8-E: trapping on IOT and HALT/OSR, SINT/CINT/CUF/SUF)
 * 5. Group 3 OPR / EAE (MQA, MQL, SWP, SCA, MUY, DVI, NMI, SHL, ASR, LSR, SWAB/SWBA)
 *
 * Copyright (c) 2026, decluau contributors.
 * Licensed under the BSD-2-Clause-Patent license.
 ]=]

--!strict

local stdio = require("@lune/stdio")
local types = require("../common/types")
local cpu = require("../pdp8/cpu")

local band = bit32.band
local bor = bit32.bor
local rshift = bit32.rshift
local lshift = bit32.lshift

local tests_passed = 0
local tests_total = 0

local function check(cond: boolean, msg: string)
	tests_total += 1
	if not cond then
		stdio.write(string.format("FAILED: %s\n", msg))
		error(msg)
	end
	tests_passed += 1
end

local function oct(s: string): number
	return tonumber(s, 8) :: number
end

-- ============================================================================
-- 1. Auto-Indexing (Locations 0010-0017 octal)
-- ============================================================================
local function test_autoindex()
	local c = cpu.new(32768)

	-- Direct access to 0010 must not increment
	cpu.reset(c)
	cpu.write_mem(c, oct"0010", oct"0200")
	cpu.write_mem(c, oct"0200", oct"1010") -- TAD 0010 (direct, page zero)
	c.pc = oct"0200"
	cpu.step(c)
	check(c.lac == oct"0200", "direct TAD 0010 loaded value")
	check(cpu.read_mem(c, oct"0010") == oct"0200", "direct 0010 was not incremented")

	-- Indirect access through 0007 (not in 0010-0017) must not increment
	cpu.reset(c)
	cpu.write_mem(c, oct"0007", oct"0300")
	cpu.write_mem(c, oct"0300", oct"0123")
	cpu.write_mem(c, oct"0200", oct"1407") -- TAD I 0007 (indirect, page zero)
	c.pc = oct"0200"
	cpu.step(c)
	check(c.lac == oct"0123", "indirect TAD I 0007 loaded target value")
	check(cpu.read_mem(c, oct"0007") == oct"0300", "0007 was not incremented")

	-- Indirect access through 0010 must increment before fetching target
	cpu.reset(c)
	cpu.write_mem(c, oct"0010", oct"0300")
	cpu.write_mem(c, oct"0301", oct"0555")
	cpu.write_mem(c, oct"0200", oct"1410") -- TAD I 0010
	c.pc = oct"0200"
	cpu.step(c)
	check(cpu.read_mem(c, oct"0010") == oct"0301", "0010 incremented to 0301")
	check(c.lac == oct"0555", "TAD I 0010 fetched from incremented address 0301")

	-- Autoindex wraps from 07777 to 00000
	cpu.reset(c)
	cpu.write_mem(c, oct"0017", oct"7777")
	cpu.write_mem(c, oct"0000", oct"0777")
	cpu.write_mem(c, oct"0200", oct"1417") -- TAD I 0017
	c.pc = oct"0200"
	cpu.step(c)
	check(cpu.read_mem(c, oct"0017") == 0, "0017 wrapped from 7777 to 0000")
	check(c.lac == oct"0777", "TAD I 0017 fetched from location 0000")

	-- Autoindex in Field 1 (IF = 1): must increment Field 1's 0012, not Field 0's
	cpu.reset(c)
	c.if_field = oct"10000" -- Field 1
	c.ib_field = oct"10000"
	cpu.write_mem(c, oct"0012", oct"0100") -- Field 0 loc 0012
	cpu.write_mem(c, oct"10012", oct"0400") -- Field 1 loc 0012
	cpu.write_mem(c, oct"00401", oct"0666") -- Field 0 loc 0401 (DF is 0)
	cpu.write_mem(c, oct"10200", oct"1412") -- TAD I 0012 in Field 1
	c.pc = oct"0200"
	cpu.step(c)
	check(cpu.read_mem(c, oct"10012") == oct"0401", "Field 1 0012 incremented")
	check(cpu.read_mem(c, oct"0012") == oct"0100", "Field 0 0012 unchanged")
	check(c.lac == oct"0666", "operand read from DF:0401")

	-- Autoindex with DCA
	cpu.reset(c)
	cpu.write_mem(c, oct"0011", oct"0500")
	cpu.write_mem(c, oct"0200", oct"3411") -- DCA I 0011
	c.lac = oct"0123"
	c.pc = oct"0200"
	cpu.step(c)
	check(cpu.read_mem(c, oct"0011") == oct"0501", "0011 incremented by DCA I")
	check(cpu.read_mem(c, oct"0501") == oct"0123", "value stored at 0501")
	check(band(c.lac, 0xFFF) == 0, "AC cleared after DCA")

	-- Autoindex with ISZ
	cpu.reset(c)
	cpu.write_mem(c, oct"0013", oct"0600")
	cpu.write_mem(c, oct"0601", oct"7777")
	cpu.write_mem(c, oct"0200", oct"2413") -- ISZ I 0013
	c.pc = oct"0200"
	cpu.step(c)
	check(cpu.read_mem(c, oct"0013") == oct"0601", "0013 incremented by ISZ I")
	check(cpu.read_mem(c, oct"0601") == 0, "target 0601 incremented to 0")
	check(c.pc == oct"0202", "ISZ skipped next instruction because target == 0")

	-- Autoindex with JMP
	cpu.reset(c)
	cpu.write_mem(c, oct"0014", oct"0677")
	cpu.write_mem(c, oct"0200", oct"5414") -- JMP I 0014
	c.pc = oct"0200"
	cpu.step(c)
	check(cpu.read_mem(c, oct"0014") == oct"0700", "0014 incremented by JMP I")
	check(c.pc == oct"0700", "JMP jumped to incremented address 0700")

	-- Autoindex with JMS
	cpu.reset(c)
	cpu.write_mem(c, oct"0015", oct"0750")
	cpu.write_mem(c, oct"0200", oct"4415") -- JMS I 0015
	c.pc = oct"0200"
	cpu.step(c)
	check(cpu.read_mem(c, oct"0015") == oct"0751", "0015 incremented by JMS I")
	check(cpu.read_mem(c, oct"0751") == oct"0201", "return address saved at 0751")
	check(c.pc == oct"0752", "JMS subroutine execution starts at 0752")
end

-- ============================================================================
-- 2. CIF Delayed Branching
-- ============================================================================
local function test_cif_delayed_branching()
	local c = cpu.new(32768)

	-- CIF 10 (6212 octal): sets IB to Field 1, inhibits interrupts
	cpu.reset(c)
	cpu.write_mem(c, oct"0200", oct"6212") -- CIF 10
	cpu.write_mem(c, oct"0201", oct"1205") -- TAD 0205 (in Field 0)
	cpu.write_mem(c, oct"0202", oct"5210") -- JMP 0210
	cpu.write_mem(c, oct"0205", oct"0042") -- Field 0 data
	cpu.write_mem(c, oct"10205", oct"0077") -- Field 1 data (should NOT be used)
	cpu.write_mem(c, oct"10210", oct"7000") -- Field 1 target: NOP

	c.pc = oct"0200"

	-- Step 1: Execute CIF 10
	cpu.step(c)
	check(c.if_field == 0, "IF remains Field 0 immediately after CIF")
	check(c.ib_field == oct"10000", "IB set to Field 1")
	check(
		band(c.int_req, cpu.INT_NO_CIF_PENDING) == 0,
		"interrupts inhibited during CIF"
	)

	-- Step 2: Execute TAD 0205 between CIF and JMP
	cpu.step(c)
	check(c.if_field == 0, "IF still Field 0 for intermediate instruction")
	check(c.lac == oct"0042", "TAD fetched operand from Field 0, not Field 1")
	check(
		band(c.int_req, cpu.INT_NO_CIF_PENDING) == 0,
		"interrupts still inhibited"
	)

	-- Step 3: Execute JMP 0210
	cpu.step(c)
	check(c.if_field == oct"10000", "IF updated to Field 1 upon JMP")
	check(c.pc == oct"0210", "PC set to jump target 0210")
	check(
		band(c.int_req, cpu.INT_NO_CIF_PENDING) ~= 0,
		"CIF interrupt inhibit cleared after JMP"
	)

	-- Step 4: Next instruction fetched from Field 1
	cpu.step(c)
	check(c.pc == oct"0211", "instruction in Field 1 executed")

	-- Test CIF with JMS: return address stored in NEW field (IB)
	cpu.reset(c)
	cpu.write_mem(c, oct"0200", oct"6222") -- CIF 20 (Field 2)
	cpu.write_mem(c, oct"0201", oct"4250") -- JMS 0250
	cpu.write_mem(c, oct"20250", 0)        -- Space for return address in Field 2
	c.pc = oct"0200"

	cpu.step(c) -- CIF 20
	check(c.if_field == 0, "IF is 0 after CIF 20")
	check(c.ib_field == oct"20000", "IB is Field 2")

	cpu.step(c) -- JMS 0250
	check(c.if_field == oct"20000", "IF updated to Field 2 on JMS")
	check(cpu.read_mem(c, oct"20250") == oct"0202", "return PC saved in Field 2")
	check(c.pc == oct"0251", "subroutine PC at 0251 in Field 2")
end

-- ============================================================================
-- 3. Interrupt Delay after ION
-- ============================================================================
local function test_ion_delay()
	local c = cpu.new(32768)
	cpu.reset(c)

	-- Program:
	-- 0200: ION (6001)
	-- 0201: TAD 0205 (must execute before interrupt triggers!)
	-- 0202: NOP
	-- 0205: data 0123
	-- Interrupt vector: location 0 gets saved PC, location 1 has ISR
	cpu.write_mem(c, oct"0200", oct"6001") -- ION
	cpu.write_mem(c, oct"0201", oct"1205") -- TAD 0205
	cpu.write_mem(c, oct"0202", oct"7000") -- NOP
	cpu.write_mem(c, oct"0205", oct"0123") -- operand
	cpu.write_mem(c, 1, oct"7402")          -- ISR: HLT

	-- Pre-assert an active device interrupt (e.g. keyboard TTI)
	c.dev_done = cpu.INT_TTI
	c.int_enable = cpu.INT_TTI
	cpu.update_int(c)

	c.pc = oct"0200"

	-- Step 1: Execute ION (6001)
	cpu.step(c)
	check(band(c.int_req, cpu.INT_ION) ~= 0, "INT_ION is set in int_req")
	check(
		band(c.int_req, cpu.INT_NO_ION_PENDING) == 0,
		"INT_NO_ION_PENDING cleared (ION delay active)"
	)
	check(c.pc == oct"0201", "PC advanced to 0201")

	-- Step 2: Instruction immediately after ION must execute completely!
	cpu.step(c)
	check(c.lac == oct"0123", "TAD 0205 executed successfully during delay window")
	check(
		band(c.int_req, cpu.INT_NO_ION_PENDING) ~= 0,
		"ION delay cleared during fetch"
	)
	check(c.pc == oct"0202", "PC reached 0202 before interrupt recognition")

	-- Step 3: Now the interrupt triggers before 0202 can execute
	cpu.step(c)
	check(cpu.read_mem(c, 0) == oct"0202", "M[0] saved return PC 0202")
	check(c.halted, "ISR at location 0001 halted CPU")
	check(c.pc == 2, "PC advanced past location 0001 to 0002")
	check(band(c.int_req, cpu.INT_ION) == 0, "ION disabled upon interrupt entry")
end

-- ============================================================================
-- 4. User Mode Restriction (KM8-E)
-- ============================================================================
local function test_user_mode()
	local c = cpu.new(32768)

	-- Test 4a: SUF and JMP into user mode
	cpu.reset(c)
	cpu.write_mem(c, oct"0200", oct"6274") -- SUF (Set User Buffer)
	cpu.write_mem(c, oct"0201", oct"5210") -- JMP 0210
	cpu.write_mem(c, oct"0210", oct"7000") -- User code: NOP
	c.pc = oct"0200"

	cpu.step(c) -- SUF
	check(c.ub == 1, "SUF set UB to 1")
	check(c.uf == 0, "UF remains 0 until JMP")

	cpu.step(c) -- JMP 0210
	check(c.uf == 1, "JMP transferred UB to UF (user mode active)")
	check(c.pc == oct"0210", "PC at user start 0210")

	-- Test 4b: HALT (7402) in user mode must NOT halt; triggers trap to 0001
	cpu.reset(c)
	c.uf = 1
	c.ub = 1
	c.if_field = oct"10000" -- Field 1
	c.df_field = oct"20000" -- Field 2
	cpu.write_mem(c, oct"10200", oct"7402") -- HLT in user mode
	cpu.write_mem(c, oct"10201", oct"7000") -- NOP
	c.pc = oct"0200"

	local stat = cpu.step(c)
	check(stat == types.SCPE_OK, "HALT in user mode did not return SCPE_HALT")
	check(not c.halted, "c.halted is false")
	check(c.pc == 1, "User mode trap diverted PC to location 0001")
	check(cpu.read_mem(c, 0) == oct"0201", "return PC 0201 saved in location 0000")
	check(c.uf == 0, "UF cleared to executive mode")
	check(c.ub == 0, "UB cleared")
	check(c.if_field == 0, "IF reset to Field 0")
	check(c.df_field == 0, "DF reset to Field 0")
	-- SF format: UF<6> | IF<6:8> | DF<9:11>
	-- UF=1 -> 0100, IF=1 -> 0010, DF=2 -> 0002. Sum = 0112 octal.
	check(c.sf_field == oct"0112", "SF correctly saved UF, IF, DF")
	check(band(c.int_req, cpu.INT_UF) ~= 0, "INT_UF bit set in int_req")

	-- Test 4c: SINT (6254) skips on INT_UF; CINT (6204) clears INT_UF
	cpu.write_mem(c, 1, oct"6254") -- SINT
	cpu.write_mem(c, 2, oct"7402") -- HLT (skipped if SINT works)
	cpu.write_mem(c, 3, oct"6204") -- CINT
	cpu.write_mem(c, 4, oct"6254") -- SINT again (should not skip)
	cpu.write_mem(c, 5, oct"7000") -- NOP

	cpu.step(c) -- SINT
	check(c.pc == 3, "SINT skipped over location 2")

	cpu.step(c) -- CINT
	check(band(c.int_req, cpu.INT_UF) == 0, "CINT cleared INT_UF")
	check(c.pc == 4, "PC advanced to location 4")

	cpu.step(c) -- SINT (now cleared)
	check(c.pc == 5, "SINT did not skip when INT_UF was clear")

	-- Test 4d: IOT in user mode must trap without executing
	cpu.reset(c)
	c.uf = 1
	c.ub = 1
	local iot_called = false
	cpu.set_dev_handler(c, oct"040", function(_self, _pulse, _ir)
		iot_called = true
		return 0
	end)
	cpu.write_mem(c, oct"0200", oct"6401") -- IOT 40 pulse 1
	c.pc = oct"0200"

	cpu.step(c)
	check(not iot_called, "IOT handler was NOT called in user mode")
	check(c.pc == 1, "IOT in user mode trapped to location 0001")
	check(cpu.read_mem(c, 0) == oct"0201", "return PC saved at 0000")
	check(band(c.int_req, cpu.INT_UF) ~= 0, "INT_UF set on IOT trap")

	-- Test 4e: OSR (7404) in user mode must trap to 0001
	cpu.reset(c)
	c.uf = 1
	c.sr = oct"0777"
	c.lac = 0
	cpu.write_mem(c, oct"0200", oct"7404") -- OSR in user mode
	c.pc = oct"0200"

	cpu.step(c)
	check(c.pc == 1, "OSR in user mode trapped to 0001")
	check(c.lac == 0, "OSR did not OR switch register into AC")
	check(band(c.int_req, cpu.INT_UF) ~= 0, "INT_UF set on OSR trap")

	-- Test 4f: CUF (6264) clears UB
	cpu.reset(c)
	c.ub = 1
	cpu.write_mem(c, oct"0200", oct"6264") -- CUF
	c.pc = oct"0200"
	cpu.step(c)
	check(c.ub == 0, "CUF cleared UB to 0")

	-- Test 4g: RMF (6244) restores UB, IB, DF from SF
	cpu.reset(c)
	c.sf_field = oct"0134" -- UF=1, IF=3, DF=4
	cpu.write_mem(c, oct"0200", oct"6244") -- RMF
	c.pc = oct"0200"
	cpu.step(c)
	check(c.ub == 1, "RMF restored UB to 1")
	check(c.ib_field == oct"30000", "RMF restored IB to Field 3")
	check(c.df_field == oct"40000", "RMF restored DF to Field 4")
end

-- ============================================================================
-- 5. Group 3 OPR / EAE
-- ============================================================================
local function test_eae()
	local c = cpu.new(32768)

	-- 5a: MQA (7501) - OR MQ into AC
	cpu.reset(c)
	c.lac = oct"0120"
	c.mq = oct"0045"
	cpu.write_mem(c, oct"0200", oct"7501") -- MQA
	c.pc = oct"0200"
	cpu.step(c)
	check(c.lac == oct"0165", "MQA ORed MQ into AC")
	check(c.mq == oct"0045", "MQ preserved after MQA")

	-- 5b: MQL (7421) - Load MQ from AC, clear AC
	cpu.reset(c)
	c.lac = oct"01234"
	cpu.write_mem(c, oct"0200", oct"7421") -- MQL
	c.pc = oct"0200"
	cpu.step(c)
	check(c.mq == oct"01234", "MQL loaded AC into MQ")
	check(band(c.lac, 0xFFF) == 0, "AC cleared after MQL")

	-- 5c: SWP / CAM (7521) - Exchange AC and MQ
	cpu.reset(c)
	c.lac = oct"01111"
	c.mq = oct"02222"
	cpu.write_mem(c, oct"0200", oct"7521") -- SWP (MQA + MQL)
	c.pc = oct"0200"
	cpu.step(c)
	check(band(c.lac, 0xFFF) == oct"02222", "AC received old MQ")
	check(c.mq == oct"01111", "MQ received old AC")

	-- 5d: SCA (7441) - Step Counter to AC
	cpu.reset(c)
	c.lac = oct"0100"
	c.sc = oct"014" -- 12 decimal
	cpu.write_mem(c, oct"0200", oct"7441") -- SCA
	c.pc = oct"0200"
	cpu.step(c)
	check(c.lac == oct"0114", "SCA ORed SC into AC")

	-- 5e: MUY (7405 in Mode A) - Multiply MQ by memory operand
	-- MQ = 12, Mem = 10 -> Prod = 120 (octal 170), AC=0, MQ=170
	cpu.reset(c)
	c.emode = 0 -- Mode A
	c.lac = 0
	c.mq = 12
	cpu.write_mem(c, oct"0200", oct"7405") -- MUY
	cpu.write_mem(c, oct"0201", 10)        -- Multiplier
	c.pc = oct"0200"
	cpu.step(c)
	check(c.mq == 120, "MUY product low in MQ")
	check(c.lac == 0, "MUY product high in AC")
	check(c.sc == oct"014", "SC loaded with 12 shifts")
	check(c.pc == oct"0202", "PC advanced past operand to 0202")

	-- 5f: MUY large product: 1000 octal * 1000 octal = 1000000 octal
	-- High word in AC = 1, Low word in MQ = 0
	cpu.reset(c)
	c.emode = 0
	c.lac = 0
	c.mq = oct"1000"
	cpu.write_mem(c, oct"0200", oct"7405")
	cpu.write_mem(c, oct"0201", oct"1000")
	c.pc = oct"0200"
	cpu.step(c)
	check(c.lac == oct"0100", "MUY high word in AC is 0100")
	check(c.mq == 0, "MUY low word in MQ is 0")

	-- 5g: DVI (7407 in Mode A) - Divide AC:MQ by memory operand
	-- AC:MQ = 0:125 (125 decimal), divisor = 10 -> MQ = 12, AC = 5
	cpu.reset(c)
	c.emode = 0
	c.lac = 0
	c.mq = 125
	cpu.write_mem(c, oct"0200", oct"7407") -- DVI
	cpu.write_mem(c, oct"0201", 10)        -- Divisor
	c.pc = oct"0200"
	cpu.step(c)
	check(c.mq == 12, "DVI quotient in MQ is 12")
	check(c.lac == 5, "DVI remainder in AC is 5")
	check(c.sc == oct"015", "SC set to 13 shifts")
	check(c.pc == oct"0202", "PC advanced past operand")

	-- 5h: DVI overflow: AC >= divisor sets Link
	cpu.reset(c)
	c.emode = 0
	c.lac = 20
	c.mq = 0
	cpu.write_mem(c, oct"0200", oct"7407") -- DVI
	cpu.write_mem(c, oct"0201", 10)        -- Divisor 10 <= AC 20
	c.pc = oct"0200"
	cpu.step(c)
	check(c.lac >= oct"010000", "Link set on DVI overflow")
	check(c.sc == 0, "SC is 0 on divide overflow")

	-- 5i: NMI (7411 in Mode A) - Normalize AC:MQ
	cpu.reset(c)
	c.emode = 0
	c.lac = 1 -- AC:MQ has single bit at bit 12
	c.mq = 0
	cpu.write_mem(c, oct"0200", oct"7411") -- NMI
	c.pc = oct"0200"
	cpu.step(c)
	check(c.sc == 10, "NMI shifted 10 times to normalize bit into AC1")
	check(band(c.lac, oct"02000") ~= 0, "normalized positive MSB into AC1")
	check(band(c.lac, oct"04000") == 0, "positive sign bit AC0 remains 0")

	-- 5j: SHL (7413 in Mode A) - Shift Left
	cpu.reset(c)
	c.emode = 0
	c.lac = 0
	c.mq = oct"0001"
	cpu.write_mem(c, oct"0200", oct"7413") -- SHL
	cpu.write_mem(c, oct"0201", 3)         -- Shift count 3 (+1 for Mode A = 4)
	c.pc = oct"0200"
	cpu.step(c)
	check(c.mq == oct"0020", "SHL shifted MQ left by 4")

	-- 5k: Mode switching: SWAB (07431) sets Mode B, SWBA (07447) sets Mode A
	cpu.reset(c)
	check(c.emode == 0, "initial emode is Mode A (0)")
	cpu.write_mem(c, oct"0200", oct"7431") -- SWAB
	c.pc = oct"0200"
	cpu.step(c)
	check(c.emode == 1, "SWAB entered Mode B (1)")

	cpu.write_mem(c, oct"0201", oct"7447") -- SWBA
	cpu.step(c)
	check(c.emode == 0, "SWBA returned to Mode A (0)")
	check(c.gtf == 0, "SWBA cleared GTF")
end

local function main()
	print("==================================================")
	print("Running PDP-8 CPU Subtle Architecture Behavior Tests")
	print("==================================================")

	stdio.write("Testing Auto-Indexing (Locations 0010-0017)... ")
	test_autoindex()
	print("passed.")

	stdio.write("Testing CIF Delayed Branching... ")
	test_cif_delayed_branching()
	print("passed.")

	stdio.write("Testing Interrupt Delay after ION... ")
	test_ion_delay()
	print("passed.")

	stdio.write("Testing User Mode Restriction (KM8-E)... ")
	test_user_mode()
	print("passed.")

	stdio.write("Testing Group 3 OPR / EAE (KE8-E)... ")
	test_eae()
	print("passed.")

	print("==================================================")
	print(string.format("!! All %d PDP-8 CPU Behavior Tests Passed !!", tests_passed))
	print("==================================================")
end

main()
