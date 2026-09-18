--[=[
 * decluau: dev/df32.luau - DF32 / DS32 Fixed-Head Disk Controller
 *
 * Adapted from OpenSIMH pdp8_df.c.
 * Copyright (c) 1993-2021, Robert M. Supnik and OpenSIMH contributors.
 * Copyright (c) 2026, decluau contributors.
 * Licensed under the BSD-2-Clause-Patent license.
 *
 * The DF32 is a head-per-track disk system using the 3-cycle data break
 * facility (DMA). Each platter contains 16 tracks of 2048 12-bit words
 * (32,768 words = 32KW). Up to three DS32 expander platters can be attached
 * for a total of four platters (131,072 words = 128KW).
 *
 * 3-Cycle Data Break Locations (Field 0):
 *   07750 (4072): Word Count (DF_WC) - two's complement of word count
 *   07751 (4073): Current Memory Address (DF_MA)
 *
 * Device Codes:
 *   060: DCMA (clear), DMAR (read), DMAW (write)
 *   061: DCEA (clear ext), DSAC (skip addr confirm), DEAL/DEAC (ext load/read)
 *   062: DFSE (skip no err), DFSC (skip done), DMAC (read disk addr)
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

-- Device codes (octal 060, 061, 062)
local DF_DEV0 = 48 -- 060 octal
local DF_DEV1 = 49 -- 061 octal
local DF_DEV2 = 50 -- 062 octal

-- Constants
local DF_NUMWD = 2048 -- Words per track
local DF_NUMTR = 16 -- Tracks per platter
local DF_DKSIZE = DF_NUMTR * DF_NUMWD -- 32768 words per platter
local DF_NUMDK = 4 -- Maximum platters
local DF_WC = 4072 -- 07750 octal: Word count location
local DF_MA = 4073 -- 07751 octal: Memory address location
local DF_WMASK = DF_NUMWD - 1 -- 2047: Word mask within track

-- Function codes
local DF_READ = 2
local DF_WRITE = 4

-- Status Register flags (octal)
local DFS_PCA = 0x800 -- 04000: Photocell timing pulse
local DFS_DEX = 0x7C0 -- 03700: Disk address extension (bits 6..10)
local DFS_MEX = 0x038 -- 00070: Memory address extension (bits 3..5)
local DFS_DRL = 0x004 -- 00004: Data late error
local DFS_WLS = 0x002 -- 00002: Write lock error
local DFS_NXD = 0x002 -- 00002: Non-existent disk
local DFS_PER = 0x001 -- 00001: Parity error
local DFS_ERR = bor(DFS_DRL, DFS_WLS, DFS_PER)

local DFS_V_DEX = 6
local DFS_V_MEX = 3

-- OS/8 bootstrap ROM (locations 07750..07754 octal)
local OS8_BOOT = {
	0x0F80, -- 7750: CLA CLL (07600)  ; also Word Count (-128)
	0x0D83, -- 7751: DMAR    (06603)  ; also Memory Address (starts read)
	0x0D92, -- 7752: DFSC    (06622)  ; done?
	0x0AEA, -- 7753: JMP .-1 (05352)  ; no, wait
	0x0BEA, -- 7754: JMP @.-2 (05752) ; enter bootloader
}

-- Disk Monitor 4 bootstrap ROM (locations 00200..00204, 07750..07751 octal)
local DM4_ROM = {
	{ addr = 0x0080, val = 0x0F80 }, -- 0200: CLA CLL (07600)
	{ addr = 0x0081, val = 0x0D83 }, -- 0201: DMAR    (06603)
	{ addr = 0x0082, val = 0x0D92 }, -- 0202: DFSC    (06622)
	{ addr = 0x0083, val = 0x0A82 }, -- 0203: JMP .-1 (05202)
	{ addr = 0x0084, val = 0x0B80 }, -- 0204: JMP @.-4 (05600)
	{ addr = DF_WC,  val = 0x0F7E }, -- 7750: Word count (-130 words, 07576)
	{ addr = DF_MA,  val = 0x0F7E }, -- 7751: Memory address (07576)
}

export type df32_t = {
	image: buffer?,
	capac: number,
	platters: number,
	sta: number,
	da: number,
	done: boolean,
	wlk: number,
	busy: boolean,
	delay: number,
	func: number,
	step_count: number,
}

local df32 = {}

df32.DF_DEV0 = DF_DEV0
df32.DF_DEV1 = DF_DEV1
df32.DF_DEV2 = DF_DEV2
df32.DF_NUMWD = DF_NUMWD
df32.DF_NUMTR = DF_NUMTR
df32.DF_DKSIZE = DF_DKSIZE
df32.DF_NUMDK = DF_NUMDK
df32.DF_WC = DF_WC
df32.DF_MA = DF_MA
df32.DF_WMASK = DF_WMASK

df32.DF_READ = DF_READ
df32.DF_WRITE = DF_WRITE

df32.DFS_PCA = DFS_PCA
df32.DFS_DEX = DFS_DEX
df32.DFS_MEX = DFS_MEX
df32.DFS_DRL = DFS_DRL
df32.DFS_WLS = DFS_WLS
df32.DFS_NXD = DFS_NXD
df32.DFS_PER = DFS_PER
df32.DFS_ERR = DFS_ERR

function df32.create_disk(platters: number?): buffer
	local p = math.clamp(platters or 1, 1, DF_NUMDK)
	return buffer.create(p * DF_DKSIZE * 2)
end

function df32.new(platters: number?): df32_t
	local p = math.clamp(platters or 1, 1, DF_NUMDK)
	return {
		image = nil,
		capac = p * DF_DKSIZE,
		platters = p,
		sta = 0,
		da = 0,
		done = true,
		wlk = 0,
		busy = false,
		delay = 0,
		func = 0,
		step_count = 0,
	}
end

function df32.set_image(self: df32_t, image: buffer?, platters: number?)
	self.image = image
	if image ~= nil then
		local p = platters
		if p == nil then
			p = math.clamp(
				math.floor(buffer.len(image) / (DF_DKSIZE * 2)),
				1,
				DF_NUMDK
			)
		end
		self.platters = p
		self.capac = p * DF_DKSIZE
	end
end

function df32.get_pos(self: df32_t): number
	return math.floor(self.step_count / 10) % DF_NUMWD
end

function df32.update_photocell(self: df32_t)
	if df32.get_pos(self) < 6 then
		self.sta = bor(self.sta, DFS_PCA)
	else
		self.sta = band(self.sta, bnot(DFS_PCA))
	end
end

local function update_int(self: df32_t, cpu: cpu_mod.cpu_t)
	if self.done then
		cpu.dev_done = bor(cpu.dev_done, cpu_mod.INT_DF)
		cpu.int_req = bor(cpu.int_req, cpu_mod.INT_DF)
	else
		cpu.dev_done = band(cpu.dev_done, bnot(cpu_mod.INT_DF))
		cpu.int_req = band(cpu.int_req, bnot(cpu_mod.INT_DF))
	end
	cpu_mod.update_int(cpu)
end

local function execute_dma(self: df32_t, cpu: cpu_mod.cpu_t)
	local img = self.image
	if img == nil then
		self.done = true
		self.busy = false
		self.sta = bor(self.sta, DFS_NXD)
		update_int(self, cpu)
		return
	end

	-- Memory Extension (bits 3..5 of status shifted to field address)
	local mex = lshift(band(self.sta, DFS_MEX), 12 - DFS_V_MEX)
	-- Disk Address (DEX bits 6..10 shifted to high disk address)
	local da = bor(
		lshift(band(self.sta, DFS_DEX), 12 - DFS_V_DEX),
		band(self.da, 0xFFF)
	)

	local wc = 0
	while true do
		if da >= self.capac then
			self.sta = bor(self.sta, DFS_NXD)
			break
		end

		-- Cycle 1: Increment Word Count at 07750 (Field 0)
		wc = band(cpu_mod.read_mem(cpu, DF_WC) + 1, 0xFFF)
		cpu_mod.write_mem(cpu, DF_WC, wc)

		-- Cycle 2: Increment Memory Address at 07751 (Field 0)
		local ma = band(cpu_mod.read_mem(cpu, DF_MA) + 1, 0xFFF)
		cpu_mod.write_mem(cpu, DF_MA, ma)

		-- Target physical address: MEX selects field, MA wraps within field
		local pa = bor(mex, ma)

		-- Cycle 3: Data transfer
		if self.func == DF_READ then
			if pa < cpu.mem_size then
				local val = buffer.readu16(img, da * 2)
				cpu_mod.write_mem(cpu, pa, val)
			end
		else
			-- Check write lock (16KW per bit)
			local t = band(rshift(da, 14), 0x7)
			if band(rshift(self.wlk, t), 1) ~= 0 then
				self.sta = bor(self.sta, DFS_WLS)
			else
				local val = cpu_mod.read_mem(cpu, pa)
				buffer.writeu16(img, da * 2, val)
			end
		end

		da = band(da + 1, 0x1FFFF)

		if wc == 0 then
			break
		end
	end

	-- On write, hardware DA register reflects last word written (da - 1)
	if self.func ~= DF_READ then
		da = band(da - 1, 0x1FFFF)
	end

	self.done = true
	self.busy = false
	self.sta = bor(
		band(self.sta, bnot(DFS_DEX)),
		band(rshift(da, 12 - DFS_V_DEX), DFS_DEX)
	)
	self.da = band(da, 0xFFF)
	update_int(self, cpu)
end

function df32.step(self: df32_t, cpu: cpu_mod.cpu_t)
	self.step_count = (self.step_count + 1) % (DF_NUMWD * 10)
	df32.update_photocell(self)

	if self.busy then
		if self.delay > 0 then
			self.delay -= 1
			if self.delay == 0 then
				execute_dma(self, cpu)
			end
		else
			execute_dma(self, cpu)
		end
	end
end

function df32.reset(self: df32_t, cpu: cpu_mod.cpu_t)
	self.sta = 0
	self.da = 0
	self.done = true
	self.busy = false
	self.delay = 0
	self.func = 0
	cpu.dev_done = band(cpu.dev_done, bnot(cpu_mod.INT_DF))
	cpu.int_req = band(cpu.int_req, bnot(cpu_mod.INT_DF))
	cpu_mod.update_int(cpu)
end

function df32.boot(
	self: df32_t,
	cpu: cpu_mod.cpu_t,
	mode: ("os8" | "dm4")?
): types.stat_t
	local m = mode or "os8"
	if m == "dm4" then
		for i = 1, #DM4_ROM do
			local entry = DM4_ROM[i]
			cpu_mod.write_mem(cpu, entry.addr, entry.val)
		end
		cpu.pc = 0x0080 -- 00200 octal
	else
		for i = 1, #OS8_BOOT do
			cpu_mod.write_mem(cpu, DF_WC + i - 1, OS8_BOOT[i])
		end
		cpu.pc = DF_WC -- 07750 octal
	end
	return types.SCPE_OK
end

function df32.attach(self: df32_t, cpu: cpu_mod.cpu_t)
	cpu_mod.add_reset_hook(cpu, function()
		df32.reset(self, cpu)
	end)

	cpu_mod.add_step_hook(cpu, function(c)
		df32.step(self, c)
	end)

	-- Device 060: DCMA, DMAR, DMAW
	cpu_mod.set_dev_handler(cpu, DF_DEV0, function(c, pulse, ir)
		df32.update_photocell(self)

		if band(pulse, 1) ~= 0 then
			-- DCMA (6601): Clear disk address, done flag, errors, int
			self.da = 0
			self.done = false
			self.busy = false
			self.delay = 0
			self.sta = band(self.sta, bnot(DFS_ERR))
			update_int(self, c)
		end

		if band(pulse, 6) ~= 0 then
			-- DMAR (6602) / DMAW (6604)
			self.da = bor(self.da, band(c.lac, 0xFFF))
			self.func = (band(pulse, 4) ~= 0) and DF_WRITE or DF_READ
			self.busy = true
			self.delay = 10
			c.lac = band(c.lac, 0x1000) -- Clear AC
		end

		return 0
	end)

	-- Device 061: DCEA, DSAC, DEAL, DEAC
	cpu_mod.set_dev_handler(cpu, DF_DEV1, function(c, pulse, ir)
		local old_sta = self.sta
		local skip = 0

		df32.update_photocell(self)

		if band(pulse, 1) ~= 0 then
			-- DCEA (6611): Clear DEX and MEX
			self.sta = band(self.sta, bnot(bor(DFS_DEX, DFS_MEX)))
		end

		local ac = band(c.lac, 0xFFF)

		if band(pulse, 2) ~= 0 then
			-- DSAC (6612): Skip if address confirmed
			if band(self.da, DF_WMASK) == df32.get_pos(self) then
				skip = 1
			end
			ac = 0 -- Pulse 2 clears AC
		end

		if band(pulse, 4) ~= 0 then
			-- DEAL / DEAC (6614, 6615, 6616)
			self.sta = bor(self.sta, band(ac, bor(DFS_DEX, DFS_MEX)))
			ac = bor(ac, old_sta)
		end

		c.lac = bor(band(c.lac, 0x1000), ac)
		return skip
	end)

	-- Device 062: DFSE, DFSC, DMAC
	cpu_mod.set_dev_handler(cpu, DF_DEV2, function(c, pulse, ir)
		local skip = 0
		local ac = band(c.lac, 0xFFF)

		df32.update_photocell(self)

		if band(pulse, 1) ~= 0 then
			-- DFSE (6621): Skip on no error
			if band(self.sta, DFS_ERR) == 0 then
				skip = 1
			end
		end

		if band(pulse, 2) ~= 0 then
			-- DFSC (6622) / DMAC AC clear (6626)
			if band(pulse, 4) ~= 0 then
				ac = 0
			elseif self.done then
				skip = 1
			end
		end

		if band(pulse, 4) ~= 0 then
			-- DMAC (6624 / 6626): Read disk address into AC
			ac = bor(ac, self.da)
		end

		c.lac = bor(band(c.lac, 0x1000), ac)
		return skip
	end)
end

return df32
