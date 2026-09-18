--[=[
 * decluau: dev/rk8e.luau - RK8-E / RK05 Moving-Head Disk Controller
 *
 * Adapted from OpenSIMH pdp8_rk.c.
 * Copyright (c) 1993-2022, Robert M. Supnik and OpenSIMH contributors.
 * Copyright (c) 2026, decluau contributors.
 * Licensed under the BSD-2-Clause-Patent license.
 ]=]

--!strict

local types = require("../common/types")
local cpu_mod = require("../pdp8/cpu")

local band = bit32.band
local bor = bit32.bor
local bnot = bit32.bnot
local rshift = bit32.rshift
local lshift = bit32.lshift

-- Disk geometry constants
local RK_NUMSC = 16   -- Sectors per track
local RK_NUMSF = 2    -- Surfaces per cylinder
local RK_NUMCY = 203  -- Cylinders per drive
local RK_NUMWD = 256  -- Words per sector
local RK_WORDS = RK_NUMCY * RK_NUMSF * RK_NUMSC * RK_NUMWD -- 1,662,976 words
local RK_BYTES = RK_WORDS * 2                              -- 3,325,952 bytes
local RK_NUMDR = 4    -- Drives per controller

-- Status register flags (octal)
local RKS_DONE = 0x800 -- 04000: Transfer done
local RKS_HMOV = 0x400 -- 02000: Heads moving
local RKS_SKFL = 0x100 -- 00400: Drive seek fail
local RKS_NRDY = 0x080 -- 00200: Drive not ready
local RKS_BUSY = 0x040 -- 00100: Control busy error
local RKS_TMO  = 0x020 -- 00040: Timeout error
local RKS_WLK  = 0x010 -- 00020: Write lock error
local RKS_CRC  = 0x008 -- 00010: CRC error
local RKS_DLT  = 0x004 -- 00004: Data late error
local RKS_STAT = 0x002 -- 00002: Drive status error
local RKS_CYL  = 0x001 -- 00001: Cylinder address error
local RKS_ERR  = bor(
	RKS_BUSY, RKS_TMO, RKS_WLK, RKS_CRC, RKS_DLT, RKS_STAT, RKS_CYL
)

-- Command register flags
local RKC_READ  = 0
local RKC_RALL  = 1
local RKC_WLK   = 2
local RKC_SEEK  = 3
local RKC_WRITE = 4
local RKC_WALL  = 5

local RKC_IE   = 0x100 -- 00400: Interrupt enable
local RKC_SKDN = 0x080 -- 00200: Set done on seek done
local RKC_HALF = 0x040 -- 00100: 128-word half sector
local RKC_MEX  = 0x038 -- 00070: Memory extension field

export type rk_drive_t = {
	image: buffer?,
	write_lock: boolean,
	cyl: number,
}

export type rk8e_t = {
	sta: number,
	cmd: number,
	da: number,
	ma: number,
	busy: boolean,
	delay: number,
	pending_func: number,
	drives: { rk_drive_t },
}

local rk8e = {}

rk8e.RK_WORDS = RK_WORDS
rk8e.RK_BYTES = RK_BYTES

function rk8e.new(): rk8e_t
	local drv: { rk_drive_t } = {}
	for i = 1, RK_NUMDR do
		drv[i] = {
			image = nil,
			write_lock = false,
			cyl = 0,
		}
	end

	return {
		sta = 0,
		cmd = 0,
		da = 0,
		ma = 0,
		busy = false,
		delay = 0,
		pending_func = 0,
		drives = drv,
	}
end

function rk8e.attach_drive(
	self: rk8e_t,
	drive_num: number,
	img: buffer,
	write_lock: boolean?
)
	assert(drive_num >= 0 and drive_num < RK_NUMDR, "invalid drive index")
	local drv = self.drives[drive_num + 1]
	drv.image = img
	drv.write_lock = write_lock or false
	drv.cyl = 0
end

local function update_int(self: rk8e_t, cpu: cpu_mod.cpu_t)
	local int_wanted = band(self.cmd, RKC_IE) ~= 0
		and band(self.sta, bor(RKS_DONE, RKS_ERR)) ~= 0
	if int_wanted then
		cpu.int_req = bor(cpu.int_req, cpu_mod.INT_RK)
	else
		cpu.int_req = band(cpu.int_req, bnot(cpu_mod.INT_RK))
	end
end

local function rk_finish_transfer(self: rk8e_t, cpu: cpu_mod.cpu_t)
	local drv_idx = band(rshift(self.cmd, 1), 0x3) + 1
	local drv = self.drives[drv_idx]
	if drv.image == nil then
		self.sta = bor(self.sta, RKS_DONE, RKS_NRDY, RKS_STAT)
		self.busy = false
		update_int(self, cpu)
		return
	end

	local full_da = bor(lshift(band(self.cmd, 1), 12), self.da)
	local disk_byte_offset = full_da * RK_NUMWD * 2
	local target_field = lshift(band(self.cmd, RKC_MEX), 9)
	local pa = bor(target_field, self.ma)
	local wc = band(self.cmd, RKC_HALF) ~= 0 and (RK_NUMWD / 2) or RK_NUMWD
	local swc = wc

	-- Field wraparound within current memory field
	local wc1 = (self.ma + wc) - 0x1000
	local wc_first = (wc1 > 0) and (wc - wc1) or wc
	local img = drv.image :: buffer

	if self.pending_func == RKC_READ then
		for i = 0, wc_first - 1 do
			local val = buffer.readu16(img, disk_byte_offset + i * 2)
			cpu_mod.write_mem(cpu, pa + i, val)
		end
		if wc1 > 0 then
			local wrap_pa = target_field
			local disk_off2 = disk_byte_offset + wc_first * 2
			for i = 0, wc1 - 1 do
				local val = buffer.readu16(img, disk_off2 + i * 2)
				cpu_mod.write_mem(cpu, wrap_pa + i, val)
			end
		end
	elseif self.pending_func == RKC_WRITE then
		for i = 0, wc_first - 1 do
			local val = cpu_mod.read_mem(cpu, pa + i)
			buffer.writeu16(img, disk_byte_offset + i * 2, val)
		end
		if wc1 > 0 then
			local wrap_pa = target_field
			local disk_off2 = disk_byte_offset + wc_first * 2
			for i = 0, wc1 - 1 do
				local val = cpu_mod.read_mem(cpu, wrap_pa + i)
				buffer.writeu16(img, disk_off2 + i * 2, val)
			end
		end
	end

	self.ma = band(self.ma + swc, 0xFFF)
	self.sta = bor(self.sta, RKS_DONE)
	self.busy = false
	update_int(self, cpu)
end

function rk8e.step(self: rk8e_t, cpu: cpu_mod.cpu_t)
	if self.delay > 0 then
		self.delay -= 1
		if self.delay == 0 then
			rk_finish_transfer(self, cpu)
		end
	end
end

function rk8e.flush(self: rk8e_t, cpu: cpu_mod.cpu_t)
	if self.busy and self.delay > 0 then
		self.delay = 0
		rk_finish_transfer(self, cpu)
	end
end

local function rk_go(
	self: rk8e_t,
	cpu: cpu_mod.cpu_t,
	func: number,
	cyl: number
)
	if func == RKC_RALL then
		func = RKC_READ
	elseif func == RKC_WALL then
		func = RKC_WRITE
	end

	local drv_idx = band(rshift(self.cmd, 1), 0x3) + 1
	local drv = self.drives[drv_idx]

	if drv.image == nil then
		self.sta = bor(self.sta, RKS_DONE, RKS_NRDY, RKS_STAT)
		update_int(self, cpu)
		return
	end

	if cyl >= RK_NUMCY then
		self.sta = bor(self.sta, RKS_DONE, RKS_STAT)
		update_int(self, cpu)
		return
	end

	if func == RKC_WRITE and drv.write_lock then
		self.sta = bor(self.sta, RKS_DONE, RKS_WLK)
		update_int(self, cpu)
		return
	end

	if func == RKC_WLK then
		drv.write_lock = true
		self.sta = bor(self.sta, RKS_DONE)
		update_int(self, cpu)
		return
	end

	drv.cyl = cyl

	if func == RKC_SEEK then
		if band(self.cmd, RKC_SKDN) ~= 0 then
			self.sta = bor(self.sta, RKS_DONE)
		end
		update_int(self, cpu)
		return
	end

	-- Initiate sector transfer with transfer latency (10 instruction cycles)
	self.busy = true
	self.pending_func = func
	self.delay = 10
end

function rk8e.reset(self: rk8e_t, cpu: cpu_mod.cpu_t)
	self.sta = 0
	self.cmd = 0
	self.da = 0
	self.ma = 0
	self.busy = false
	self.delay = 0
	self.pending_func = 0
	for i = 1, RK_NUMDR do
		self.drives[i].cyl = 0
		self.drives[i].write_lock = false
	end
	update_int(self, cpu)
end

function rk8e.attach(self: rk8e_t, cpu: cpu_mod.cpu_t)
	cpu_mod.add_reset_hook(cpu, function()
		rk8e.reset(self, cpu)
	end)

	cpu_mod.add_step_hook(cpu, function(c)
		rk8e.step(self, c)
	end)

	-- Device 074: RK8-E Controller
	cpu_mod.set_dev_handler(cpu, 0x3C, function(c, pulse, ir)
		if pulse == 1 then
			-- DSKP (6741): Skip on done or error
			if band(self.sta, bor(RKS_DONE, RKS_ERR)) ~= 0 then
				return 1
			end
			return 0
		elseif pulse == 2 then
			-- DCLR (6742): Clear status/control/drive
			self.sta = 0
			local code = band(c.lac, 0x3)
			if code == 0 or code == 3 then
				-- CLS (0) / CLSA (3): Clear status
				if self.busy then
					self.sta = bor(self.sta, RKS_BUSY)
				end
			elseif code == 1 then
				-- CLC (1): Clear control
				self.cmd = 0
				self.busy = false
				self.delay = 0
				self.ma = 0
				self.da = 0
			elseif code == 2 then
				-- CLD (2): Reset drive to cylinder 0
				if self.busy then
					self.sta = bor(self.sta, RKS_BUSY)
				else
					rk_go(self, c, RKC_SEEK, 0)
				end
			end
			c.lac = band(c.lac, 0x1000) -- Clear AC
		elseif pulse == 3 then
			-- DLAG (6743): Load disk address and GO
			if self.busy then
				self.sta = bor(self.sta, RKS_BUSY)
			else
				self.da = band(c.lac, 0xFFF)
				local func = band(rshift(self.cmd, 9), 0x7)
				local cyl = bor(
					lshift(band(self.cmd, 1), 7),
					band(rshift(self.da, 5), 0x7F)
				)
				rk_go(self, c, func, cyl)
			end
			c.lac = band(c.lac, 0x1000) -- Clear AC
		elseif pulse == 4 then
			-- DLCA (6744): Load current memory address
			if self.busy then
				self.sta = bor(self.sta, RKS_BUSY)
			else
				self.ma = band(c.lac, 0xFFF)
			end
			c.lac = band(c.lac, 0x1000)
		elseif pulse == 5 then
			-- DRST (6745): Read status
			local drv_idx = band(rshift(self.cmd, 1), 0x3) + 1
			local drv = self.drives[drv_idx]
			self.sta = band(self.sta, bnot(bor(RKS_HMOV, RKS_NRDY)))
			if drv.image == nil then
				self.sta = bor(self.sta, RKS_NRDY)
			end
			c.lac = bor(band(c.lac, 0x1000), band(self.sta, 0xFFF))
		elseif pulse == 6 then
			-- DLDC (6746): Load disk command
			if self.busy then
				self.sta = bor(self.sta, RKS_BUSY)
			else
				self.cmd = band(c.lac, 0xFFF)
				self.sta = 0
			end
			c.lac = band(c.lac, 0x1000)
		end

		update_int(self, c)
		return 0
	end)
end

-- Official DEC 8-word hardware bootstrap loader routine
local BOOT_START = 0x13 -- 0023 octal
local BOOT_UNIT  = 0x1A -- 0032 octal
local boot_rom = {
	0x0C07, -- 0023: 6007 CAF
	0x0DE4, -- 0024: 6744 DLCA
	0x021A, -- 0025: 1032 TAD 32 (UNIT)
	0x0DE6, -- 0026: 6746 DLDC
	0x0DE3, -- 0027: 6743 DLAG
	0x021A, -- 0030: 1032 TAD 32 (UNIT for OS/8)
	0x0A19, -- 0031: 5031 JMP 31 (wait loop)
	0x0000, -- 0032: 0000 UNIT (bits 9:10)
}

function rk8e.install_boot(cpu: cpu_mod.cpu_t, unit_no: number?): number
	local u = unit_no or 0
	for i = 1, #boot_rom do
		cpu_mod.write_mem(cpu, BOOT_START + i - 1, boot_rom[i])
	end
	cpu_mod.write_mem(cpu, BOOT_UNIT, lshift(band(u, 0x3), 1))
	cpu.pc = BOOT_START
	return BOOT_START
end

return rk8e
