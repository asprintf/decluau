--[=[
 * decluau: dev/rx8e.luau - RX8-E / RX01 Floppy Disk Controller
 *
 * Adapted from OpenSIMH pdp8_rx.c.
 * Copyright (c) 1993-2013, Robert M. Supnik and OpenSIMH contributors.
 * Copyright (c) 2026, decluau contributors.
 * Licensed under the BSD-2-Clause-Patent license.
 *
 * The RX8-E / RX01 is a dual 8-inch single-density floppy disk controller
 * for the DEC PDP-8. Each diskette contains 77 tracks (0..76) of 26 sectors
 * (1..26) with 128 bytes per sector (256,256 bytes total).
 *
 * Supports both 8-bit byte streaming and 12-bit word packing modes (where
 * two 12-bit words are packed into three 8-bit bytes, 64 words per sector).
 *
 * Device Code: 075 (octal)
 *   6751: LCD  - Load Command & Clear AC
 *   6752: XDR  - Transfer Data Register
 *   6753: STR  - Skip on Transfer Request (TR)
 *   6754: SER  - Skip on Error
 *   6755: SDN  - Skip on Done
 *   6756: INTR - Set / Clear Interrupt Enable
 *   6757: INIT - Initialize Controller
 ]=]

--!strict

local types = require("../common/types")
local cpu_mod = require("../pdp8/cpu")

local band = bit32.band
local bor = bit32.bor
local bnot = bit32.bnot
local rshift = bit32.rshift
local lshift = bit32.lshift

-- Device code (075 octal = 61 decimal)
local RX_DEV = 61

-- Geometry constants
local RX_NUMTR = 77 -- Tracks per diskette (0..76)
local RX_NUMSC = 26 -- Sectors per track (1..26)
local RX_NUMBY = 128 -- Bytes per sector
local RX_NUMWD = 64 -- 12-bit words per sector
local RX_SIZE = RX_NUMTR * RX_NUMSC * RX_NUMBY -- 256,256 bytes
local RX_NUMDR = 2 -- 2 drives (0 and 1)

-- Controller states
local STATE_IDLE = 0
local STATE_RWDS = 1 -- Waiting for sector address
local STATE_RWDT = 2 -- Waiting for track address
local STATE_RWXFR = 3 -- Sector read / write transfer
local STATE_FILL = 4 -- Filling sector buffer
local STATE_EMPTY = 5 -- Emptying sector buffer
local STATE_COMPLETE = 6 -- Command completion

-- Function codes (bits 1..3 of command)
local RXCS_FILL = 0
local RXCS_EMPTY = 1
local RXCS_WRITE = 2
local RXCS_READ = 3
local RXCS_SDEN = 4
local RXCS_RXES = 5
local RXCS_WRDEL = 6
local RXCS_ECODE = 7

-- Command register flags
local RXCS_DRV = 0x10 -- 0020: Drive select (0 = Drive 0, 1 = Drive 1)
local RXCS_MODE = 0x40 -- 0100: 8-bit mode (0 = 12-bit, 1 = 8-bit)
local RXCS_MAINT = 0x80 -- 0200: Maintenance

-- Error status register flags
local RXES_CRC = 0x01 -- 0001: CRC error
local RXES_ID = 0x04 -- 0004: Init done
local RXES_DD = 0x40 -- 0100: Deleted data
local RXES_DRDY = 0x80 -- 0200: Drive ready

-- Bootstrap ROM for RX01 / RX8-E (locations 00022..00061 octal)
local BOOT_ROM = {
	{ addr = 0x0012, val = 0x0DED }, -- 022: SDN (6755)
	{ addr = 0x0013, val = 0x0A12 }, -- 023: JMP .-1 (5022)
	{ addr = 0x0014, val = 0x0E56 }, -- 024: CLL CML RTL (7126, AC = 6)
	{ addr = 0x0015, val = 0x0230 }, -- 025: TAD 60 (1060, unit offset)
	{ addr = 0x0016, val = 0x0DE9 }, -- 026: LCD (6751, load READ)
	{ addr = 0x0017, val = 0x0E81 }, -- 027: CLA IAC (7201, AC = 1)
	{ addr = 0x0018, val = 0x082B }, -- 030: JMS 53 (4053, load sector 1)
	{ addr = 0x0019, val = 0x082B }, -- 031: JMS 53 (4053, load track 1)
	{ addr = 0x001A, val = 0x0E44 }, -- 032: CLL RAL (7104, AC = 2)
	{ addr = 0x001B, val = 0x0DED }, -- 033: SDN (6755, wait read done)
	{ addr = 0x001C, val = 0x0A2C }, -- 034: JMP 54 (5054, check TR)
	{ addr = 0x001D, val = 0x0DEC }, -- 035: SER (6754, skip if error)
	{ addr = 0x001E, val = 0x0F28 }, -- 036: SNA (7450)
	{ addr = 0x001F, val = 0x0F88 }, -- 037: CLA SKP (7610)
	{ addr = 0x0020, val = 0x0A26 }, -- 040: JMP 46 (5046, go empty)
	{ addr = 0x0021, val = 0x0F02 }, -- 041: HLT (7402)
	{ addr = 0x0022, val = 0x0F02 }, -- 042: HLT (7402)
	{ addr = 0x0023, val = 0x0F02 }, -- 043: HLT (7402)
	{ addr = 0x0024, val = 0x0F02 }, -- 044: HLT (7402)
	{ addr = 0x0025, val = 0x0F02 }, -- 045: HLT (7402)
	{ addr = 0x0026, val = 0x0DE9 }, -- 046: LCD (6751, load EMPTY)
	{ addr = 0x0027, val = 0x082B }, -- 047: JMS 53 (4053, get word)
	{ addr = 0x0028, val = 0x0602 }, -- 050: DCA 2 (3002, store at 2)
	{ addr = 0x0029, val = 0x0428 }, -- 051: ISZ 50 (2050, increment dest)
	{ addr = 0x002A, val = 0x0A27 }, -- 052: JMP 47 (5047, loop)
	{ addr = 0x002B, val = 0x0000 }, -- 053: LOAD return address
	{ addr = 0x002C, val = 0x0DEB }, -- 054: STR (6753, skip on TR)
	{ addr = 0x002D, val = 0x0A1B }, -- 055: JMP 33 (5033, wait)
	{ addr = 0x002E, val = 0x0DEA }, -- 056: XDR (6752, transfer data)
	{ addr = 0x002F, val = 0x0B2B }, -- 057: JMP I 53 (5453)
	{ addr = 0x0030, val = 0x0E04 }, -- 060: UNIT (7004 drv 0, 7024 drv 1)
	{ addr = 0x0031, val = 0x0C18 }, -- 061: KCC (6030)
}

export type rx_drive_t = {
	image: buffer?,
	track: number,
	write_lock: boolean,
}

export type rx8e_t = {
	csr: number,
	dbr: number,
	esr: number,
	ecode: number,
	track: number,
	sector: number,
	state: number,
	bptr: number,
	buf: buffer,
	tr: boolean,
	err: boolean,
	done: boolean,
	int_enable: boolean,
	delay: number,
	drives: { rx_drive_t },
}

local rx8e = {}

rx8e.RX_DEV = RX_DEV
rx8e.RX_NUMTR = RX_NUMTR
rx8e.RX_NUMSC = RX_NUMSC
rx8e.RX_NUMBY = RX_NUMBY
rx8e.RX_NUMWD = RX_NUMWD
rx8e.RX_SIZE = RX_SIZE
rx8e.RX_NUMDR = RX_NUMDR

rx8e.RXCS_FILL = RXCS_FILL
rx8e.RXCS_EMPTY = RXCS_EMPTY
rx8e.RXCS_WRITE = RXCS_WRITE
rx8e.RXCS_READ = RXCS_READ
rx8e.RXCS_SDEN = RXCS_SDEN
rx8e.RXCS_RXES = RXCS_RXES
rx8e.RXCS_WRDEL = RXCS_WRDEL
rx8e.RXCS_ECODE = RXCS_ECODE

rx8e.RXCS_DRV = RXCS_DRV
rx8e.RXCS_MODE = RXCS_MODE
rx8e.RXES_DRDY = RXES_DRDY
rx8e.RXES_ID = RXES_ID
rx8e.BOOT_ROM = BOOT_ROM

function rx8e.create_disk(): buffer
	return buffer.create(RX_SIZE)
end

function rx8e.new(): rx8e_t
	local drvs: { rx_drive_t } = {}
	for i = 1, RX_NUMDR do
		drvs[i] = {
			image = nil,
			track = 0,
			write_lock = false,
		}
	end

	return {
		csr = 0,
		dbr = 0,
		esr = 0,
		ecode = 0,
		track = 0,
		sector = 0,
		state = STATE_IDLE,
		bptr = 0,
		buf = buffer.create(RX_NUMBY),
		tr = false,
		err = false,
		done = true,
		int_enable = false,
		delay = 0,
		drives = drvs,
	}
end

function rx8e.set_image(self: rx8e_t, drive: number, image: buffer?)
	local idx = drive + 1
	if idx >= 1 and idx <= RX_NUMDR then
		self.drives[idx].image = image
	end
end

local function update_int(self: rx8e_t, cpu: cpu_mod.cpu_t)
	if self.done then
		cpu.dev_done = bor(cpu.dev_done, cpu_mod.INT_RX)
		if self.int_enable then
			cpu.int_req = bor(cpu.int_req, cpu_mod.INT_RX)
		else
			cpu.int_req = band(cpu.int_req, bnot(cpu_mod.INT_RX))
		end
	else
		cpu.dev_done = band(cpu.dev_done, bnot(cpu_mod.INT_RX))
		cpu.int_req = band(cpu.int_req, bnot(cpu_mod.INT_RX))
	end
	cpu_mod.update_int(cpu)
end

local function rx_done(
	self: rx8e_t,
	cpu: cpu_mod.cpu_t,
	esr_flags: number,
	ecode: number
)
	local drv_idx = (band(self.csr, RXCS_DRV) ~= 0) and 2 or 1
	local drv = self.drives[drv_idx]

	self.state = STATE_IDLE
	self.done = true
	self.tr = false

	self.esr = bor(self.esr, esr_flags)
	if drv.image ~= nil then
		self.esr = bor(self.esr, RXES_DRDY)
	else
		self.esr = band(self.esr, bnot(RXES_DRDY))
	end

	if ecode > 0 then
		self.err = true
		self.ecode = ecode
	elseif ecode == 0 then
		self.ecode = 0
	end

	self.dbr = self.esr
	update_int(self, cpu)
end

function rx8e.reset(self: rx8e_t, cpu: cpu_mod.cpu_t)
	self.csr = 0
	self.dbr = 0
	self.esr = 0
	self.ecode = 0
	self.track = 0
	self.sector = 0
	self.state = STATE_IDLE
	self.bptr = 0
	self.tr = false
	self.err = false
	self.done = true
	self.int_enable = false
	self.delay = 0

	-- Reset initializes drive 0 to track 1, drive 1 to track 0
	self.drives[1].track = 1
	self.drives[2].track = 0

	cpu.dev_done = band(cpu.dev_done, bnot(cpu_mod.INT_RX))
	cpu.int_req = band(cpu.int_req, bnot(cpu_mod.INT_RX))
	cpu_mod.update_int(cpu)
end

-- Advances controller state when delay expires
function rx8e.step(self: rx8e_t, cpu: cpu_mod.cpu_t)
	if self.delay > 0 then
		self.delay -= 1
		if self.delay > 0 then
			return
		end
	else
		return
	end

	local drv_idx = (band(self.csr, RXCS_DRV) ~= 0) and 2 or 1
	local drv = self.drives[drv_idx]
	local fnc = band(rshift(self.csr, 1), 0x7)

	if self.state == STATE_RWXFR then
		local img = drv.image
		if img == nil then
			-- Unattached error (0110 octal)
			rx_done(self, cpu, 0, 0x48)
			return
		end

		if self.track >= RX_NUMTR then
			rx_done(self, cpu, 0, 0x20) -- Bad track (0040 octal)
			return
		end
		drv.track = self.track

		if self.sector < 1 or self.sector > RX_NUMSC then
			rx_done(self, cpu, 0, 0x38) -- Bad sector (0070 octal)
			return
		end

		local da = ((self.track * RX_NUMSC)
			+ (self.sector - 1)) * RX_NUMBY

		if fnc == RXCS_READ then
			buffer.copy(self.buf, 0, img, da, RX_NUMBY)
			rx_done(self, cpu, 0, 0)
		elseif fnc == RXCS_WRITE or fnc == RXCS_WRDEL then
			if drv.write_lock then
				-- Write protected (0100 octal)
				rx_done(self, cpu, 0, 0x40)
				return
			end
			buffer.copy(img, da, self.buf, 0, RX_NUMBY)
			if fnc == RXCS_WRDEL then
				self.esr = bor(self.esr, RXES_DD)
			end
			rx_done(self, cpu, 0, 0)
		end

	elseif self.state == STATE_COMPLETE then
		if fnc == RXCS_ECODE then
			self.dbr = self.ecode
			rx_done(self, cpu, 0, -1)
		else
			rx_done(self, cpu, 0, 0)
		end
	end
end

local function xdr_empty(self: rx8e_t, c: cpu_mod.cpu_t, is_8b: boolean)
	local ret_val = self.dbr
	if is_8b then
		if self.bptr < RX_NUMBY then
			self.dbr = buffer.readu8(self.buf, self.bptr)
			self.bptr += 1
			self.tr = true
		else
			rx_done(self, c, 0, 0)
		end
	else
		if self.bptr < RX_NUMWD then
			local byptr = math.floor((3 * self.bptr) / 2)
			if band(self.bptr, 1) ~= 0 then
				local b1 = buffer.readu8(self.buf, byptr)
				local b2 = buffer.readu8(self.buf, byptr + 1)
				local hi = lshift(band(b1, 0xF), 8)
				self.dbr = bor(hi, b2)
			else
				local b0 = buffer.readu8(self.buf, byptr)
				local b1 = buffer.readu8(self.buf, byptr + 1)
				local hi = lshift(b0, 4)
				local lo = band(rshift(b1, 4), 0xF)
				self.dbr = bor(hi, lo)
			end
			self.bptr += 1
			self.tr = true
		else
			rx_done(self, c, 0, 0)
		end
	end
	c.lac = bor(band(c.lac, 0x1000), band(ret_val, 0xFFF))
end

local function xdr_fill(self: rx8e_t, c: cpu_mod.cpu_t, is_8b: boolean)
	local ac_val = band(c.lac, 0xFFF)
	self.dbr = ac_val
	if is_8b then
		buffer.writeu8(self.buf, self.bptr, band(ac_val, 0xFF))
		self.bptr += 1
		if self.bptr < RX_NUMBY then
			self.tr = true
		else
			rx_done(self, c, 0, 0)
		end
	else
		local byptr = math.floor((3 * self.bptr) / 2)
		if band(self.bptr, 1) ~= 0 then
			local prev = buffer.readu8(self.buf, byptr)
			local hi = band(prev, 0xF0)
			local lo = band(rshift(ac_val, 8), 0xF)
			buffer.writeu8(self.buf, byptr, bor(hi, lo))
			buffer.writeu8(self.buf, byptr + 1, band(ac_val, 0xFF))
		else
			local hi = band(rshift(ac_val, 4), 0xFF)
			local lo = lshift(band(ac_val, 0xF), 4)
			buffer.writeu8(self.buf, byptr, hi)
			buffer.writeu8(self.buf, byptr + 1, lo)
		end
		self.bptr += 1
		if self.bptr < RX_NUMWD then
			self.tr = true
		else
			rx_done(self, c, 0, 0)
		end
	end
end

function rx8e.boot(
	self: rx8e_t,
	cpu: cpu_mod.cpu_t,
	unit: number?
): types.stat_t
	local u = unit or 0
	for i = 1, #BOOT_ROM do
		local entry = BOOT_ROM[i]
		cpu_mod.write_mem(cpu, entry.addr, entry.val)
	end

	-- Location 00060 octal:
	-- 7004 (CLL RAL) for unit 0, 7024 (CLL CML RAL) for unit 1
	local unit_val = (u ~= 0) and 0x0E14 or 0x0E04
	cpu_mod.write_mem(cpu, 0x0030, unit_val)

	cpu.pc = 0x0012 -- 022 octal
	return types.SCPE_OK
end

function rx8e.attach(self: rx8e_t, cpu: cpu_mod.cpu_t)
	cpu_mod.add_reset_hook(cpu, function()
		rx8e.reset(self, cpu)
	end)

	cpu_mod.add_step_hook(cpu, function(c)
		rx8e.step(self, c)
	end)

	cpu_mod.set_dev_handler(cpu, RX_DEV, function(c, pulse, ir)
		local drv_idx = (band(self.csr, RXCS_DRV) ~= 0) and 2 or 1
		local is_8b = band(self.csr, RXCS_MODE) ~= 0

		if pulse == 1 then
			-- LCD (6751): Load Command
			if self.state ~= STATE_IDLE then
				return 0 -- Ignore if busy
			end

			self.done = false
			self.tr = false
			self.err = false
			self.bptr = 0
			self.csr = band(c.lac, 0xFFF)
			self.dbr = self.csr
			c.lac = band(c.lac, 0x1000) -- Clear AC

			local fnc = band(rshift(self.csr, 1), 0x7)
			if fnc == RXCS_FILL then
				self.state = STATE_FILL
				self.tr = true
				self.esr = band(self.esr, RXES_ID)
			elseif fnc == RXCS_EMPTY then
				self.state = STATE_EMPTY
				self.tr = true
				self.esr = band(self.esr, RXES_ID)
				-- Pre-load first word/byte into DBR
				if is_8b then
					self.dbr = buffer.readu8(self.buf, 0)
				else
					local b0 = buffer.readu8(self.buf, 0)
					local b1 = buffer.readu8(self.buf, 1)
					local hi = lshift(b0, 4)
					local lo = band(rshift(b1, 4), 0xF)
					self.dbr = bor(hi, lo)
				end
				self.bptr = 1
			elseif fnc == RXCS_READ or fnc == RXCS_WRITE
				or fnc == RXCS_WRDEL then
				self.state = STATE_RWDS
				self.tr = true
				self.esr = band(self.esr, RXES_ID)
			else
				self.state = STATE_COMPLETE
				self.delay = 2
			end
			update_int(self, c)
			return 0

		elseif pulse == 2 then
			-- XDR (6752): Transfer Data Register
			if self.state == STATE_EMPTY then
				xdr_empty(self, c, is_8b)
				return 0

			elseif self.state == STATE_FILL then
				xdr_fill(self, c, is_8b)
				return 0

			elseif self.state == STATE_RWDS then
				self.sector = band(c.lac, 0x7F)
				self.dbr = self.sector
				self.state = STATE_RWDT
				self.tr = true
				return 0

			elseif self.state == STATE_RWDT then
				self.track = band(c.lac, 0xFF)
				self.dbr = self.track
				self.state = STATE_RWXFR
				self.delay = 5
				self.tr = false
				return 0

			else
				c.lac = bor(
					band(c.lac, 0x1000),
					band(self.dbr, 0xFFF)
				)
				return 0
			end

		elseif pulse == 3 then
			-- STR (6753): Skip on Transfer Request
			if self.tr then
				self.tr = false
				return 1
			end
			return 0

		elseif pulse == 4 then
			-- SER (6754): Skip on Error
			if self.err then
				self.err = false
				return 1
			end
			return 0

		elseif pulse == 5 then
			-- SDN (6755): Skip on Done
			if self.done then
				self.done = false
				update_int(self, c)
				return 1
			end
			return 0

		elseif pulse == 6 then
			-- INTR (6756): Set / Clear Interrupt Enable
			self.int_enable = band(c.lac, 1) ~= 0
			update_int(self, c)
			return 0

		elseif pulse == 7 then
			-- INIT (6757): Initialize Controller
			rx8e.reset(self, c)
			return 0
		end

		return 0
	end)
end

return rx8e
