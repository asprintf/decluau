--[=[
 * decluau: dev/ta8e.luau - TA8-E / TU60 Dual Digital Cassette Drive
 *
 * Adapted from OpenSIMH pdp8_ct.c.
 * Copyright (c) 2006-2013, Robert M. Supnik and OpenSIMH contributors.
 * Copyright (c) 2026, decluau contributors.
 * Licensed under the BSD-2-Clause-Patent license.
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

-- Device 070 (octal): TA8-E Primary Controller
local CT_DEV = 56 -- 070 octal
local CT_NUMDR = 2
local CT_SIZE = 93000 -- Characters per cassette tape

-- Status Register A flags (octal)
local SRA_ENAB = 0x80 -- 0200: Drive enabled
local SRA_UNIT = 0x40 -- 0100: Unit 1 select (0 = Unit 0)
local SRA_FNC  = 0x38 -- 0070: Function code
local SRA_2ND  = 0x08 -- 0010: Second phase
local SRA_IE   = 0x01 -- 0001: Interrupt enable

-- Function codes
local SRA_READ  = 0
local SRA_REW   = 1
local SRA_WRITE = 2
local SRA_SRF   = 3
local SRA_WFG   = 4
local SRA_SRB   = 5
local SRA_CRC   = 6
local SRA_SFF   = 7

-- Status Register B flags
local SRB_WLE  = 0x100 -- 0400: Write lock error
local SRB_CRC  = 0x080 -- 0200: CRC error
local SRB_TIM  = 0x040 -- 0100: Timing error
local SRB_BEOT = 0x020 -- 0040: BOT / EOT
local SRB_EOF  = 0x010 -- 0020: End of file (file gap)
local SRB_EMP  = 0x008 -- 0010: Drive empty (unattached)
local SRB_REW  = 0x004 -- 0004: Rewinding
local SRB_WLK  = 0x002 -- 0002: Write locked
local SRB_RDY  = 0x001 -- 0001: Drive ready

local SRB_ALLERR = bor(
	SRB_WLE, SRB_CRC, SRB_TIM, SRB_BEOT, SRB_EOF, SRB_EMP
)

export type ct_drive_t = {
	image: buffer?,
	size: number,
	pos: number,
	write_lock: boolean,
	ust_gap: boolean,
}

export type ta8e_t = {
	sra: number,
	srb: number,
	db: number,
	df: boolean,
	write_op: boolean,
	bptr: number,
	blnt: number,
	xb: buffer,
	delay: number,
	active_fnc: number,
	drives: { ct_drive_t },
}

local ta8e = {}

ta8e.CT_SIZE = CT_SIZE

function ta8e.calc_crc(buf: buffer, start_pos: number, count: number): number
	local crc = 0
	for i = 0, count - 1 do
		local b = buffer.readu8(buf, start_pos + i)
		crc = bxor(crc, lshift(b, 8))
		for _ = 1, 8 do
			if band(crc, 1) ~= 0 then
				crc = bxor(rshift(crc, 1), 0xA001)
			else
				crc = rshift(crc, 1)
			end
		end
	end
	return crc
end

function ta8e.new(): ta8e_t
	local drv: { ct_drive_t } = {}
	for i = 1, CT_NUMDR do
		drv[i] = {
			image = nil,
			size = 0,
			pos = 0,
			write_lock = false,
			ust_gap = false,
		}
	end

	return {
		sra = 0,
		srb = 0,
		db = 0,
		df = false,
		write_op = false,
		bptr = 0,
		blnt = 0,
		xb = buffer.create(CT_SIZE + 2),
		delay = 0,
		active_fnc = 0,
		drives = drv,
	}
end

function ta8e.attach_tape(
	self: ta8e_t,
	drive_num: number,
	img: buffer,
	size: number?,
	write_lock: boolean?
)
	assert(drive_num >= 0 and drive_num < CT_NUMDR, "invalid cassette drive")
	local d = self.drives[drive_num + 1]
	d.image = img
	d.size = size or buffer.len(img)
	d.pos = 0
	d.write_lock = write_lock or false
	d.ust_gap = false
end

local function update_status(self: ta8e_t, cpu: cpu_mod.cpu_t): number
	local unit = band(rshift(self.sra, 6), 1) + 1
	local drv = self.drives[unit]

	self.srb = band(self.srb, bnot(bor(SRB_WLK, SRB_EMP, SRB_RDY)))
	if drv.image == nil then
		self.srb = bor(self.srb, SRB_EMP, SRB_WLK)
	else
		if drv.write_lock or band(self.srb, SRB_REW) ~= 0 then
			self.srb = bor(self.srb, SRB_WLK)
		end
		if self.delay == 0 then
			self.srb = bor(self.srb, SRB_RDY)
		end
		if drv.pos == 0 then
			self.srb = bor(self.srb, SRB_BEOT)
		end
	end

	local visible_srb = band(self.sra, SRA_ENAB) ~= 0 and self.srb or 0
	local int_wanted = band(self.sra, SRA_IE) ~= 0 and (
		self.df or band(visible_srb, bor(SRB_ALLERR, SRB_RDY)) ~= 0
	)

	if int_wanted then
		cpu.int_req = bor(cpu.int_req, cpu_mod.INT_CT)
	else
		cpu.int_req = band(cpu.int_req, bnot(cpu_mod.INT_CT))
	end

	return visible_srb
end

local function ct_read_next_char(self: ta8e_t): boolean
	if self.bptr < self.blnt then
		self.db = buffer.readu8(self.xb, self.bptr)
		self.bptr += 1
		return true
	end
	self.db = 0
	self.srb = bor(self.srb, SRB_CRC) -- Overrun error
	return false
end

local function ct_start_read_record(self: ta8e_t, drv: ct_drive_t)
	local img = drv.image :: buffer
	if drv.pos + 4 > drv.size then
		self.srb = bor(self.srb, SRB_BEOT)
		return
	end

	local bc = buffer.readu32(img, drv.pos)
	drv.pos += 4

	if bc == 0 then
		-- File gap (tape mark)
		self.srb = bor(self.srb, SRB_EOF)
		drv.ust_gap = true
		return
	end

	drv.ust_gap = false
	if drv.pos + bc > drv.size then
		self.srb = bor(self.srb, SRB_CRC)
		return
	end

	-- Read record into transfer buffer
	buffer.copy(self.xb, 0, img, drv.pos, bc)
	drv.pos += bc
	if band(bc, 1) ~= 0 then
		drv.pos += 1 -- Skip padding byte
	end
	if drv.pos + 4 <= drv.size then
		drv.pos += 4 -- Skip trailing byte count
	end

	local crc = ta8e.calc_crc(self.xb, 0, bc)
	buffer.writeu8(self.xb, bc, band(rshift(crc, 8), 0xFF))
	buffer.writeu8(self.xb, bc + 1, band(crc, 0xFF))
	self.blnt = bc + 2
	self.bptr = 0
	self.active_fnc = bor(SRA_READ, SRA_2ND)
end

local function ct_start_op(self: ta8e_t, cpu: cpu_mod.cpu_t, ac: number): number
	local unit = band(rshift(self.sra, 6), 1) + 1
	local drv = self.drives[unit]
	local fnc = band(rshift(self.sra, 3), 0x7)

	if band(self.sra, SRA_ENAB) == 0 or drv.image == nil then
		return ac
	end

	self.srb = band(self.srb, bnot(bor(SRB_ALLERR, SRB_REW)))
	self.active_fnc = fnc

	if fnc == SRA_READ then
		self.write_op = false
		self.db = 0
		self.bptr = 0
		self.blnt = 0

		-- If reading forward at BOT, skip initial file gap if present
		local img = drv.image :: buffer
		if drv.pos == 0 and drv.pos + 4 <= drv.size then
			local bc = buffer.readu32(img, 0)
			if bc == 0 then
				drv.pos = 4
			end
		end

		ct_start_read_record(self, drv)
		if self.active_fnc == bor(SRA_READ, SRA_2ND) then
			if ct_read_next_char(self) then
				self.df = true
			end
		end
		return 0
	elseif fnc == SRA_WRITE then
		if drv.write_lock then
			self.srb = bor(self.srb, SRB_WLE)
			self.active_fnc = 0
			return ac
		end
		self.write_op = true
		self.bptr = 0
		self.blnt = 0
		self.db = band(ac, 0xFF)
		buffer.writeu8(self.xb, self.bptr, self.db)
		self.bptr += 1
		self.active_fnc = bor(SRA_WRITE, SRA_2ND)
		self.df = true
		return ac
	elseif fnc == SRA_REW then
		drv.pos = 0
		drv.ust_gap = false
		self.active_fnc = 0
		self.srb = bor(self.srb, SRB_BEOT)
	elseif fnc == SRA_SRB then
		self.active_fnc = 0
		-- Space reverse block using trailing 32-bit length
		local img = drv.image :: buffer
		if drv.pos >= 4 then
			local trailing_bc = buffer.readu32(img, drv.pos - 4)
			local pad = band(trailing_bc, 1) ~= 0 and 1 or 0
			local rec_bytes = (trailing_bc == 0) and 4 or (trailing_bc + pad + 8)
			drv.pos = (drv.pos >= rec_bytes) and (drv.pos - rec_bytes) or 0
		end
	elseif fnc == SRA_SRF then
		self.active_fnc = 0
		-- Space reverse file
		local img = drv.image :: buffer
		while drv.pos >= 4 do
			local bc = buffer.readu32(img, drv.pos - 4)
			local pad = band(bc, 1) ~= 0 and 1 or 0
			local rec_bytes = (bc == 0) and 4 or (bc + pad + 8)
			drv.pos = (drv.pos >= rec_bytes) and (drv.pos - rec_bytes) or 0
			if bc == 0 then
				self.srb = bor(self.srb, SRB_EOF)
				break
			end
		end
	elseif fnc == SRA_SFF then
		self.active_fnc = 0
		-- Space forward file
		local img = drv.image :: buffer
		while drv.pos + 4 <= drv.size do
			local bc = buffer.readu32(img, drv.pos)
			drv.pos += 4
			if bc == 0 then
				self.srb = bor(self.srb, SRB_EOF)
				break
			end
			local pad = band(bc, 1) ~= 0 and 1 or 0
			drv.pos += bc + pad + 4
		end
	elseif fnc == SRA_WFG then
		self.active_fnc = 0
		-- Write file gap (4 zero bytes)
		if drv.write_lock then
			self.srb = bor(self.srb, SRB_WLE)
		else
			local img = drv.image :: buffer
			if drv.pos + 4 <= buffer.len(img) then
				buffer.writeu32(img, drv.pos, 0)
				drv.pos += 4
				if drv.pos > drv.size then
					drv.size = drv.pos
				end
			end
		end
	else
		self.active_fnc = 0
	end

	return ac
end

local function ct_continue_op(self: ta8e_t, ac: number): number
	local fnc = band(rshift(self.sra, 3), 0x7)
	local unit = band(rshift(self.sra, 6), 1) + 1
	local drv = self.drives[unit]

	if fnc == SRA_READ then
		local ret_val = self.db
		if ct_read_next_char(self) then
			self.df = true
		end
		return ret_val
	elseif fnc == SRA_WRITE then
		buffer.writeu8(self.xb, self.bptr, band(ac, 0xFF))
		self.bptr += 1
		self.df = true
		return ac
	elseif fnc == SRA_CRC then
		if self.write_op then
			-- Finalize written block to tape
			local img = drv.image :: buffer
			local bc = self.bptr
			local pad = band(bc, 1) ~= 0 and 1 or 0
			local total = 4 + bc + pad + 4
			if drv.pos + total <= buffer.len(img) then
				buffer.writeu32(img, drv.pos, bc)
				buffer.copy(img, drv.pos + 4, self.xb, 0, bc)
				if pad == 1 then
					buffer.writeu8(img, drv.pos + 4 + bc, 0)
				end
				buffer.writeu32(img, drv.pos + 4 + bc + pad, bc)
				drv.pos += total
				if drv.pos > drv.size then
					drv.size = drv.pos
				end
			else
				self.srb = bor(self.srb, SRB_BEOT)
			end
			self.write_op = false
			self.active_fnc = 0
			return ac
		else
			-- CRC read mode
			local ret_val = self.db
			if self.bptr < self.blnt then
				self.db = buffer.readu8(self.xb, self.bptr)
				self.bptr += 1
				self.df = true
			else
				self.active_fnc = 0
			end
			return ret_val
		end
	end

	return ac
end

function ta8e.reset(self: ta8e_t, cpu: cpu_mod.cpu_t)
	self.sra = 0
	self.srb = 0
	self.db = 0
	self.df = false
	self.write_op = false
	self.bptr = 0
	self.blnt = 0
	self.delay = 0
	self.active_fnc = 0
	for i = 1, CT_NUMDR do
		self.drives[i].pos = 0
		self.drives[i].ust_gap = false
	end
	update_status(self, cpu)
end

function ta8e.attach(self: ta8e_t, cpu: cpu_mod.cpu_t)
	cpu_mod.add_reset_hook(cpu, function()
		ta8e.reset(self, cpu)
	end)

	-- Device 070 (octal): TA8-E Controller IOTs
	cpu_mod.set_dev_handler(cpu, CT_DEV, function(c, pulse, ir)
		local srb = update_status(self, c)

		if pulse == 0 then
			-- KCLR (6700): Clear controller
			ta8e.reset(self, c)
		elseif pulse == 1 then
			-- KSDR (6701): Skip on data flag
			if self.df then
				return 1
			end
		elseif pulse == 2 then
			-- KSEN (6702): Skip on any error
			if band(srb, SRB_ALLERR) ~= 0 then
				return 1
			end
		elseif pulse == 3 then
			-- KSBF (6703): Skip on ready and not empty
			if band(srb, SRB_RDY) ~= 0 and band(srb, SRB_EMP) == 0 then
				return 1
			end
		elseif pulse == 4 then
			-- KLSA (6704): Load Status Register A
			self.sra = band(c.lac, 0xFF)
			srb = update_status(self, c)
			c.lac = bor(band(c.lac, 0x1000), bxor(self.sra, 0xFF))
		elseif pulse == 5 then
			-- KSAF (6705): Skip on any flag
			if self.df or band(srb, bor(SRB_ALLERR, SRB_RDY)) ~= 0 then
				return 1
			end
		elseif pulse == 6 then
			-- KGOA (6706): Transfer byte / initiate operation
			self.df = false
			local new_ac: number
			if self.active_fnc ~= 0 then
				new_ac = ct_continue_op(self, band(c.lac, 0xFFF))
			else
				new_ac = ct_start_op(self, c, band(c.lac, 0xFFF))
			end
			c.lac = bor(band(c.lac, 0x1000), band(new_ac, 0xFFF))
			update_status(self, c)
		elseif pulse == 7 then
			-- KSRB (6707): Read Status Register B
			c.lac = bor(band(c.lac, 0x1000), band(srb, 0xFF))
		end

		return 0
	end)
end

-- DEC CAPS-8 26-word hardware cassette bootstrap sequence
local BOOT_START = 0x800 -- 04000 octal
local boot_rom = {
	0x029F, -- 4000: TAD 4037 (M50)
	0x0286, -- 4001: TAD 4006 (L260)
	0x0DE4, -- 4002: KLSA
	0x0DE6, -- 4003: KGOA
	0x0DE3, -- 4004: KSBF
	0x0A84, -- 4005: JMP 4004
	0x0EB4, -- 4006: CML STA RAL
	0x0DE2, -- 4007: KSEN
	0x0F88, -- 4010: SKP CLA
	0x0689, -- 4011: DCA 4011
	0x079E, -- 4012: DCA I 4036 (PTR)
	0x0285, -- 4013: TAD 4005
	0x0DE4, -- 4014: KLSA
	0x0DE6, -- 4015: KGOA
	0x0DE1, -- 4016: KSDR
	0x0A96, -- 4017: JMP 4016
	0x0E02, -- 4020: BSW
	0x0F18, -- 4021: SZL
	0x039E, -- 4022: TAD I 4036
	0x0E12, -- 4023: CML BSW
	0x079E, -- 4024: DCA I 4036
	0x0F10, -- 4025: SNL
	0x049E, -- 4026: ISZ 4036
	0x049D, -- 4027: ISZ 4035
	0x0A95, -- 4030: JMP 4015
	0x0EE6, -- 4031: STA CLL RTL
	0x0E02, -- 4032: BSW
	0x069D, -- 4033: DCA 4035
	0x0A81, -- 4034: JMP 4001
	0x0FDF, -- 4035: 7737 (-32 decimal / byte count)
	0x076F, -- 4036: 3557 (load address)
	0x0FD8, -- 4037: 7730 (CLA SPA SZL)
}

function ta8e.install_boot(cpu: cpu_mod.cpu_t): number
	for i = 1, #boot_rom do
		cpu_mod.write_mem(cpu, BOOT_START + i - 1, boot_rom[i])
	end
	cpu.pc = BOOT_START
	return BOOT_START
end

return ta8e
