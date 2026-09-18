--[=[
 * decluau: dev/tc08.luau - TC08 / TU56 DECtape Controller
 *
 * Adapted from OpenSIMH pdp8_dt.c.
 * Copyright (c) 1993-2021, Robert M. Supnik and OpenSIMH contributors.
 * Copyright (c) 2026, decluau contributors.
 * Licensed under the BSD-2-Clause-Patent license.
 *
 * The TC08 is a bidirectional, block-addressable magnetic tape controller
 * for the DEC PDP-8. It controls up to 8 TU56 DECtape transport drives.
 * Each tape reel contains 1474 blocks (or 576 blocks under OS/8) of 129
 * 12-bit words per block (190,146 words total capacity).
 *
 * Device Codes:
 *   076: Status Register A Controls
 *     6761: DTRA - Read Status Register A (OR into AC)
 *     6762: DTCA - Clear Status Register A
 *     6764: DTXA - Load / XOR Status Register A & Clear AC
 *     6766: DTCA!DTXA - Clear and Load Status Register A
 *   077: Status Register B Controls
 *     6771: DTSF - Skip on DECtape Flag (DTF) or Error Flag (ERF)
 *     6772: DTRB - Read Status Register B (OR into AC)
 *     6774: DTLB - Load Status Register B (Memory Extension bits) & Clear AC
 *
 * 3-Cycle Data Break Vectors in Field 0:
 *   07754: Word Count (DT_WC)
 *   07755: Current Memory Address (DT_CA)
 ]=]

--!strict

local types = require("../common/types")
local cpu_mod = require("../pdp8/cpu")

local band = bit32.band
local bor = bit32.bor
local bnot = bit32.bnot
local bxor = bit32.bxor
local rshift = bit32.rshift
local lshift = bit32.lshift

-- Device numbers (076 and 077 octal = 62 and 63 decimal)
local DT_DEV_76 = 62
local DT_DEV_77 = 63

-- 3-Cycle Data Break vectors in Field 0
local DT_WC = 0x0FE4 -- 07754 octal
local DT_CA = 0x0FE5 -- 07755 octal

-- Tape geometry constants
local DT_NUMDR = 8 -- Up to 8 drives (0..7)
local D8_BSIZE = 129 -- 12-bit words per block
local D8_TSIZE = 1474 -- Blocks per standard DECtape
local D8_CAPAC = D8_TSIZE * D8_BSIZE -- 190,146 words
local D8_BYTES = D8_CAPAC * 2 -- 2 bytes per 12-bit word

-- Status Register A bit definitions
local DTA_V_UNIT = 9
local DTA_M_UNIT = 0x7
local DTA_STSTP = 0x80 -- 0200: 0 = stop, 1 = start motion
local DTA_FWDRV = 0x100 -- 0400: 0 = forward, 1 = reverse
local DTA_MODE = 0x40 -- 0100: 0 = normal block stop, 1 = continuous
local DTA_V_FNC = 3
local DTA_M_FNC = 0x7
local DTA_ENB = 0x04 -- 0004: Interrupt enable
local DTA_CERF = 0x02 -- 0002: Clear Error Flag
local DTA_CDTF = 0x01 -- 0001: Clear DECtape Flag
local DTA_RW = 0x0FFC -- Read/write bits (bits 2..11)

-- Function codes (bits 3..5 of Status Register A)
local FNC_MOVE = 0 -- Move tape to end zone
local FNC_SRCH = 1 -- Search for block header
local FNC_READ = 2 -- Read data block
local FNC_RALL = 3 -- Read all (headers + data)
local FNC_WRIT = 4 -- Write data block
local FNC_WALL = 5 -- Write all
local FNC_WMRK = 6 -- Write mark track (not allowed)

-- Status Register B bit definitions
local DTB_DTF = 0x001 -- 0001: DECtape flag (operation done / ready)
local DTB_MEX = 0x038 -- 0070: Memory extension field (bits 3..5)
local DTB_TIM = 0x040 -- 0100: Timing error
local DTB_PAR = 0x080 -- 0200: Parity error
local DTB_SEL = 0x100 -- 0400: Select error
local DTB_END = 0x200 -- 1000: End zone error
local DTB_MRK = 0x400 -- 2000: Mark track error
local DTB_ERF = 0x800 -- 4000: Error flag (OR of all errors)
local DTB_ALLERR = bor(
	DTB_ERF,
	DTB_MRK,
	DTB_END,
	DTB_SEL,
	DTB_PAR,
	DTB_TIM
)

-- Official DEC 4K DMS / OS/8 TC08 Bootstrap ROM (address 00200 octal)
local BOOT_ROM = {
	{ addr = 0x0080, val = 0x0F80 }, -- 0200: CLA (7600)
	{ addr = 0x0081, val = 0x028E }, -- 0201: TAD MVB (1216)
	{ addr = 0x0082, val = 0x0888 }, -- 0202: JMS DO (4210)
	{ addr = 0x0083, val = 0x028F }, -- 0203: TAD K7577 (1217)
	{ addr = 0x0084, val = 0x0790 }, -- 0204: DCA I CA (3620)
	{ addr = 0x0085, val = 0x0292 }, -- 0205: TAD RDF (1222)
	{ addr = 0x0086, val = 0x0888 }, -- 0206: JMS DO (4210)
	{ addr = 0x0087, val = 0x0B80 }, -- 0207: JMP I 200 (5600)
	{ addr = 0x0088, val = 0x0000 }, -- 0210: DO (0000)
	{ addr = 0x0089, val = 0x0DF6 }, -- 0211: DTCA!DTXA (6766)
	{ addr = 0x008A, val = 0x0791 }, -- 0212: DCA I WC (3621)
	{ addr = 0x008B, val = 0x0DF9 }, -- 0213: DTSF (6771)
	{ addr = 0x008C, val = 0x0A8B }, -- 0214: JMP .-1 (5213)
	{ addr = 0x008D, val = 0x0B88 }, -- 0215: JMP I DO (5610)
	{ addr = 0x008E, val = 0x0180 }, -- 0216: MVB (0600)
	{ addr = 0x008F, val = 0x0F7F }, -- 0217: K7577 (7577)
	{ addr = 0x0090, val = 0x0FE5 }, -- 0220: CA (7755)
	{ addr = 0x0091, val = 0x0FE4 }, -- 0221: WC (7754)
	{ addr = 0x0092, val = 0x0090 }, -- 0222: RF (0220)
}

export type tc08_drive_t = {
	image: buffer?,
	block: number,
	word: number,
	write_lock: boolean,
}

export type tc08_t = {
	dtsa: number,
	dtsb: number,
	delay: number,
	active_fnc: number,
	active_dir: number,
	drives: { tc08_drive_t },
}

local tc08 = {}

tc08.DT_DEV_76 = DT_DEV_76
tc08.DT_DEV_77 = DT_DEV_77
tc08.DT_WC = DT_WC
tc08.DT_CA = DT_CA
tc08.DT_NUMDR = DT_NUMDR
tc08.D8_BSIZE = D8_BSIZE
tc08.D8_TSIZE = D8_TSIZE
tc08.D8_CAPAC = D8_CAPAC
tc08.D8_BYTES = D8_BYTES

tc08.DTA_STSTP = DTA_STSTP
tc08.DTA_FWDRV = DTA_FWDRV
tc08.DTA_MODE = DTA_MODE
tc08.DTA_ENB = DTA_ENB
tc08.DTA_CERF = DTA_CERF
tc08.DTA_CDTF = DTA_CDTF

tc08.FNC_MOVE = FNC_MOVE
tc08.FNC_SRCH = FNC_SRCH
tc08.FNC_READ = FNC_READ
tc08.FNC_RALL = FNC_RALL
tc08.FNC_WRIT = FNC_WRIT
tc08.FNC_WALL = FNC_WALL
tc08.FNC_WMRK = FNC_WMRK

tc08.DTB_DTF = DTB_DTF
tc08.DTB_MEX = DTB_MEX
tc08.DTB_TIM = DTB_TIM
tc08.DTB_PAR = DTB_PAR
tc08.DTB_SEL = DTB_SEL
tc08.DTB_END = DTB_END
tc08.DTB_MRK = DTB_MRK
tc08.DTB_ERF = DTB_ERF
tc08.BOOT_ROM = BOOT_ROM

function tc08.create_tape(): buffer
	return buffer.create(D8_BYTES)
end

function tc08.read_tape_word(tape: buffer, blk: number, wrd: number): number
	if blk < 0 or blk >= D8_TSIZE or wrd < 0 or wrd >= D8_BSIZE then
		return 0
	end
	local offset = (blk * D8_BSIZE + wrd) * 2
	return buffer.readu16(tape, offset)
end

function tc08.write_tape_word(
	tape: buffer,
	blk: number,
	wrd: number,
	val: number
)
	if blk < 0 or blk >= D8_TSIZE or wrd < 0 or wrd >= D8_BSIZE then
		return
	end
	local offset = (blk * D8_BSIZE + wrd) * 2
	buffer.writeu16(tape, offset, band(val, 0xFFF))
end

local function update_int(self: tc08_t, cpu: cpu_mod.cpu_t)
	local req = (band(self.dtsa, DTA_ENB) ~= 0)
		and (band(self.dtsb, bor(DTB_ERF, DTB_DTF)) ~= 0)
	if req then
		cpu.int_req = bor(cpu.int_req, cpu_mod.INT_DTA)
	else
		cpu.int_req = band(cpu.int_req, bnot(cpu_mod.INT_DTA))
	end
	cpu_mod.update_int(cpu)
end

local function set_error(self: tc08_t, cpu: cpu_mod.cpu_t, err_bit: number)
	self.dtsb = bor(self.dtsb, err_bit, DTB_ERF)
	update_int(self, cpu)
end

function tc08.new(): tc08_t
	local drvs: { tc08_drive_t } = {}
	for _ = 1, DT_NUMDR do
		table.insert(drvs, {
			image = nil,
			block = 0,
			word = 0,
			write_lock = false,
		})
	end

	return {
		dtsa = 0,
		dtsb = 0,
		delay = 0,
		active_fnc = 0,
		active_dir = 0,
		drives = drvs,
	}
end

function tc08.set_image(self: tc08_t, unit: number, img: buffer?)
	assert(unit >= 0 and unit < DT_NUMDR, "invalid unit")
	self.drives[unit + 1].image = img
	self.drives[unit + 1].block = 0
	self.drives[unit + 1].word = 0
end

function tc08.reset(self: tc08_t, cpu: cpu_mod.cpu_t)
	self.dtsa = 0
	self.dtsb = 0
	self.delay = 0
	self.active_fnc = 0
	self.active_dir = 0

	cpu.dev_done = band(cpu.dev_done, bnot(cpu_mod.INT_DTA))
	cpu.int_req = band(cpu.int_req, bnot(cpu_mod.INT_DTA))
	cpu_mod.update_int(cpu)
end

-- Execute tape action when delay expires
function tc08.step(self: tc08_t, cpu: cpu_mod.cpu_t)
	if self.delay > 0 then
		self.delay -= 1
		if self.delay > 0 then
			return
		end
	else
		return
	end

	local unit_idx = band(rshift(self.dtsa, DTA_V_UNIT), DTA_M_UNIT) + 1
	local drv = self.drives[unit_idx]
	if drv.image == nil then
		set_error(self, cpu, DTB_SEL)
		return
	end

	local img = drv.image :: buffer
	local fnc = self.active_fnc
	local dir = self.active_dir -- 0 = forward, 1 = reverse

	if fnc == FNC_MOVE then
		-- Move tape until end zone reached
		if dir ~= 0 then
			drv.block = 0
			drv.word = 0
		else
			drv.block = D8_TSIZE - 1
			drv.word = D8_BSIZE - 1
		end
		set_error(self, cpu, DTB_END)
		return

	elseif fnc == FNC_SRCH then
		-- Search: find next block in direction of motion
		if dir ~= 0 then
			if drv.block > 0 then
				drv.block -= 1
			else
				set_error(self, cpu, DTB_END)
				return
			end
		else
			if drv.block < (D8_TSIZE - 1) then
				drv.block += 1
			else
				set_error(self, cpu, DTB_END)
				return
			end
		end

		-- Transfer block number into memory at Current Address (CA)
		local wc = band(cpu_mod.read_mem(cpu, DT_WC) + 1, 0xFFF)
		cpu_mod.write_mem(cpu, DT_WC, wc)

		local ca = cpu_mod.read_mem(cpu, DT_CA)
		local mex = band(rshift(self.dtsb, 3), 0x7)
		local ma = bor(lshift(mex, 12), ca)
		cpu_mod.write_mem(cpu, ma, drv.block)

		self.dtsb = bor(self.dtsb, DTB_DTF)
		update_int(self, cpu)
		return

	elseif fnc == FNC_READ or fnc == FNC_RALL then
		-- Read data block via 3-cycle data break
		local mex = band(rshift(self.dtsb, 3), 0x7)
		local field_base = lshift(mex, 12)

		for w = 0, D8_BSIZE - 1 do
			local wc = band(cpu_mod.read_mem(cpu, DT_WC) + 1, 0xFFF)
			cpu_mod.write_mem(cpu, DT_WC, wc)

			local ca = band(cpu_mod.read_mem(cpu, DT_CA) + 1, 0xFFF)
			cpu_mod.write_mem(cpu, DT_CA, ca)

			local ma = bor(field_base, ca)
			local word_val = tc08.read_tape_word(img, drv.block, w)
			cpu_mod.write_mem(cpu, ma, word_val)

			if wc == 0 and band(self.dtsa, DTA_MODE) == 0 then
				break
			end
		end

		if dir ~= 0 then
			if drv.block > 0 then
				drv.block -= 1
			end
		else
			if drv.block < (D8_TSIZE - 1) then
				drv.block += 1
			end
		end

		self.dtsb = bor(self.dtsb, DTB_DTF)
		update_int(self, cpu)
		return

	elseif fnc == FNC_WRIT or fnc == FNC_WALL then
		if drv.write_lock then
			set_error(self, cpu, DTB_SEL)
			return
		end

		local mex = band(rshift(self.dtsb, 3), 0x7)
		local field_base = lshift(mex, 12)
		local wc_zero = false

		for w = 0, D8_BSIZE - 1 do
			local wc = band(cpu_mod.read_mem(cpu, DT_WC) + 1, 0xFFF)
			cpu_mod.write_mem(cpu, DT_WC, wc)

			local ca = band(cpu_mod.read_mem(cpu, DT_CA) + 1, 0xFFF)
			cpu_mod.write_mem(cpu, DT_CA, ca)

			local ma = bor(field_base, ca)
			local word_val = wc_zero and 0
				or cpu_mod.read_mem(cpu, ma)
			tc08.write_tape_word(img, drv.block, w, word_val)

			if wc == 0 then
				wc_zero = true
			end
		end

		if dir ~= 0 then
			if drv.block > 0 then
				drv.block -= 1
			end
		else
			if drv.block < (D8_TSIZE - 1) then
				drv.block += 1
			end
		end

		self.dtsb = bor(self.dtsb, DTB_DTF)
		update_int(self, cpu)
		return
	end
end

local function handle_dev76(
	self: tc08_t,
	cpu: cpu_mod.cpu_t,
	pulse: number,
	ir: number
): number
	if pulse == 1 then
		-- DTRA (6761): Read Status Register A (OR into AC)
		cpu.lac = bor(cpu.lac, self.dtsa)
		return 0

	elseif pulse == 2 then
		-- DTCA (6762): Clear Status Register A
		self.dtsa = 0
		return 0

	elseif pulse == 4 or pulse == 6 then
		-- DTXA (6764) or DTCA!DTXA (6766)
		local ac = band(cpu.lac, 0xFFF)

		if pulse == 6 then
			self.dtsa = 0
		end

		if band(ac, DTA_CERF) == 0 then
			self.dtsb = band(self.dtsb, bnot(DTB_ALLERR))
		end
		if band(ac, DTA_CDTF) == 0 then
			self.dtsb = band(self.dtsb, bnot(DTB_DTF))
		end

		self.dtsa = bxor(self.dtsa, band(ac, DTA_RW))
		cpu.lac = band(cpu.lac, 0x1000) -- Clear AC, preserve Link

		local unit_idx = band(
			rshift(self.dtsa, DTA_V_UNIT),
			DTA_M_UNIT
		) + 1
		local drv = self.drives[unit_idx]
		local fnc = band(rshift(self.dtsa, DTA_V_FNC), DTA_M_FNC)
		if fnc >= FNC_WMRK then
			set_error(self, cpu, DTB_SEL)
			return 0
		end

		if (fnc == FNC_WRIT or fnc == FNC_WALL) and drv.write_lock then
			set_error(self, cpu, DTB_SEL)
			return 0
		end

		-- Start motion if start bit is set
		if band(self.dtsa, DTA_STSTP) ~= 0 then
			if drv.image == nil then
				set_error(self, cpu, DTB_SEL)
				return 0
			end
			self.active_fnc = fnc
			self.active_dir = (band(self.dtsa, DTA_FWDRV) ~= 0)
				and 1 or 0
			self.delay = 2 -- Schedule operation
		end

		update_int(self, cpu)
		return 0
	end

	return 0
end

local function handle_dev77(
	self: tc08_t,
	cpu: cpu_mod.cpu_t,
	pulse: number,
	ir: number
): number
	if pulse == 1 then
		-- DTSF (6771): Skip on DECtape Flag or Error
		if band(self.dtsb, bor(DTB_ERF, DTB_DTF)) ~= 0 then
			return 1
		end
		return 0

	elseif pulse == 2 then
		-- DTRB (6772): Read Status Register B (OR into AC)
		cpu.lac = bor(cpu.lac, self.dtsb)
		return 0

	elseif pulse == 4 then
		-- DTLB (6774): Load Status Register B (MEX bits) & Clear AC
		local ac = band(cpu.lac, 0xFFF)
		self.dtsb = bor(
			band(self.dtsb, bnot(DTB_MEX)),
			band(ac, DTB_MEX)
		)
		cpu.lac = band(cpu.lac, 0x1000) -- Clear AC
		return 0
	end

	return 0
end

function tc08.boot(
	self: tc08_t,
	cpu: cpu_mod.cpu_t,
	unit: number?
): types.stat_t
	local u = unit or 0
	if u ~= 0 then
		return types.SCPE_ARG
	end

	for i = 1, #BOOT_ROM do
		local entry = BOOT_ROM[i]
		cpu_mod.write_mem(cpu, entry.addr, entry.val)
	end

	-- Rewind unit 0 to beginning of tape
	self.drives[1].block = 0
	self.drives[1].word = 0

	cpu.pc = 0x0080 -- 0200 octal
	return types.SCPE_OK
end

function tc08.attach(self: tc08_t, cpu: cpu_mod.cpu_t)
	cpu_mod.add_reset_hook(cpu, function()
		tc08.reset(self, cpu)
	end)

	cpu_mod.add_step_hook(cpu, function(c)
		tc08.step(self, c)
	end)

	cpu_mod.set_dev_handler(cpu, DT_DEV_76, function(c, pulse, ir)
		return handle_dev76(self, c, pulse, ir)
	end)

	cpu_mod.set_dev_handler(cpu, DT_DEV_77, function(c, pulse, ir)
		return handle_dev77(self, c, pulse, ir)
	end)
end

return tc08
