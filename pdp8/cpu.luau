--[=[
 * decluau: pdp8/cpu.luau - PDP-8/E Central Processor Unit
 *
 * Adapted from OpenSIMH pdp8_cpu.c and pdp8_defs.h.
 * Copyright (c) 1993-2022, Robert M. Supnik and OpenSIMH contributors.
 * Copyright (c) 2026, decluau contributors.
 * Licensed under the BSD-2-Clause-Patent license.
 ]=]

--!strict

local types = require("../common/types")

local band = bit32.band
local bor = bit32.bor
local bnot = bit32.bnot
local bxor = bit32.bxor
local rshift = bit32.rshift
local lshift = bit32.lshift

local function oct(s: string): number
	return tonumber(s, 8) :: number
end

export type iot_handler_t = (cpu: cpu_t, pulse: number, ir: number) -> number

export type cpu_t = {
	mem: buffer,
	mem_size: number,

	-- Primary registers
	lac: number, -- 13-bit: bit 12 is Link (010000), bits 0-11 are AC (07777)
	mq: number,  -- 12-bit Multiplier-Quotient
	pc: number,  -- 12-bit Program Counter
	sr: number,  -- 12-bit Switch Register

	-- KM8-E Memory Extension registers
	if_field: number, -- 15-bit Instruction Field base (0, 010000, .. 070000)
	ib_field: number, -- 15-bit Instruction Buffer (latched CIF target)
	df_field: number, -- 15-bit Data Field base
	sf_field: number, -- Interrupt Save Field: UF<6> | IF<6:8> | DF<9:11>
	uf: number,       -- User mode flag (0 = exec, 1 = user)
	ub: number,       -- User mode buffer

	-- KE8-E EAE registers
	emode: number, -- EAE mode (0 = Mode A, 1 = Mode B)
	gtf: number,   -- Greater-than flag
	sc: number,    -- Shift counter (5-bit)

	-- Bus interrupt lines (DEC Omnibus architecture)
	dev_done: number,   -- Device done status flags
	int_enable: number, -- Device interrupt enable mask
	int_req: number,    -- Combined interrupt requests & control states

	-- Device dispatch table & reset callbacks
	dev_dispatch: { [number]: iot_handler_t },
	reset_hooks: { () -> () },
	step_hooks: { (cpu_t) -> () }?,
	halted: boolean,
}

-- Interrupt flag bit assignments (OpenSIMH pdp8_defs.h)
local INT_LPT            = 0x1       -- 1 << 0 (Line Printer)
local INT_PTP            = 0x2       -- 1 << 1 (Punch)
local INT_PTR            = 0x4       -- 1 << 2 (Reader)
local INT_TTO            = 0x8       -- 1 << 3 (Teleprinter)
local INT_TTI            = 0x10      -- 1 << 4 (Keyboard)
local INT_CLK            = 0x20      -- 1 << 5 (Clock)
local INT_RX             = 0x4000    -- 1 << 14 (RX8E)
local INT_RK             = 0x8000    -- 1 << 15 (RK8E)
local INT_RF             = 0x10000   -- 1 << 16 (RF08)
local INT_DF             = 0x20000   -- 1 << 17 (DF32)
local INT_MT             = 0x40000   -- 1 << 18 (TM8E)
local INT_DTA            = 0x80000   -- 1 << 19 (TC08)
local INT_RL             = 0x100000  -- 1 << 20 (RL8A)
local INT_CT             = 0x200000  -- 1 << 21 (TA8E)
local INT_UF             = 0x800000  -- 1 << 23 (KM8E User Mode Trap)

local INT_NO_ION_PENDING = 0x4000000 -- 1 << 26: ION delay inhibit
local INT_NO_CIF_PENDING = 0x8000000 -- 1 << 27: CIF inhibit until JMP/JMS
local INT_ION            = 0x10000000-- 1 << 28: Interrupts enabled

local INT_DEV_ENABLE     = 0x3FFF    -- Devices with individual enables
local INT_ALL            = 0x3FFFFFF -- All device interrupt lines
local INT_INIT_ENABLE    = bor(INT_TTI, INT_TTO, INT_PTR, INT_PTP, INT_LPT)
local INT_PENDING        = bor(INT_ION, INT_NO_CIF_PENDING, INT_NO_ION_PENDING)

local cpu = {}

cpu.INT_LPT = INT_LPT
cpu.INT_PTP = INT_PTP
cpu.INT_PTR = INT_PTR
cpu.INT_TTO = INT_TTO
cpu.INT_TTI = INT_TTI
cpu.INT_CLK = INT_CLK
cpu.INT_RK  = INT_RK
cpu.INT_RX  = INT_RX
cpu.INT_DF  = INT_DF
cpu.INT_CT  = INT_CT
cpu.INT_RF  = INT_RF
cpu.INT_MT  = INT_MT
cpu.INT_DTA = INT_DTA
cpu.INT_RL  = INT_RL
cpu.INT_UF  = INT_UF
cpu.INT_NO_ION_PENDING = INT_NO_ION_PENDING
cpu.INT_NO_CIF_PENDING = INT_NO_CIF_PENDING
cpu.INT_ION = INT_ION
cpu.INT_ALL = INT_ALL

function cpu.new(mem_words: number?): cpu_t
	local words = mem_words or 32768
	local buf = buffer.create(words * 2)

	return {
		mem = buf,
		mem_size = words,

		lac = 0,
		mq = 0,
		pc = 0,
		sr = 0,

		if_field = 0,
		ib_field = 0,
		df_field = 0,
		sf_field = 0,
		uf = 0,
		ub = 0,

		emode = 0,
		gtf = 0,
		sc = 0,

		dev_done = 0,
		int_enable = INT_INIT_ENABLE,
		int_req = INT_NO_CIF_PENDING,

		dev_dispatch = {},
		reset_hooks = {},
		halted = false,
	}
end

function cpu.update_int(self: cpu_t)
	self.int_req = bor(
		band(self.int_req, bnot(INT_DEV_ENABLE)),
		band(self.dev_done, self.int_enable)
	)
end

function cpu.read_mem(self: cpu_t, addr: number): number
	if addr < self.mem_size then
		return buffer.readu16(self.mem, addr * 2)
	end
	return 0
end

function cpu.write_mem(self: cpu_t, addr: number, val: number)
	if addr < self.mem_size then
		buffer.writeu16(self.mem, addr * 2, band(val, 0xFFF))
	end
end

function cpu.reset(self: cpu_t)
	self.lac = 0
	self.mq = 0
	self.if_field = 0
	self.ib_field = 0
	self.df_field = 0
	self.sf_field = 0
	self.uf = 0
	self.ub = 0
	self.emode = 0
	self.gtf = 0
	self.sc = 0
	self.dev_done = 0
	self.int_enable = INT_INIT_ENABLE
	self.int_req = INT_NO_CIF_PENDING
	self.halted = false

	for i = 1, #self.reset_hooks do
		self.reset_hooks[i]()
	end
	cpu.update_int(self)
end

function cpu.add_reset_hook(self: cpu_t, hook: () -> ())
	table.insert(self.reset_hooks, hook)
end

function cpu.add_step_hook(self: cpu_t, hook: (cpu_t) -> ())
	if self.step_hooks == nil then
		self.step_hooks = {}
	end
	table.insert(self.step_hooks :: { (cpu_t) -> () }, hook)
end

function cpu.set_dev_handler(self: cpu_t, dev: number, handler: iot_handler_t)
	self.dev_dispatch[dev] = handler
end

-- Executes one PDP-8 instruction cycle
function cpu.step(self: cpu_t): types.stat_t
	if self.halted then
		return types.SCPE_HALT
	end

	-- Interrupt recognition: all overhead conditions met and an interrupt
	-- is pending
	if self.int_req > INT_PENDING then
		self.int_req = band(self.int_req, bnot(INT_ION))
		self.sf_field = bor(
			lshift(self.uf, 6),
			rshift(self.if_field, 9),
			rshift(self.df_field, 12)
		)
		self.if_field = 0
		self.ib_field = 0
		self.df_field = 0
		self.uf = 0
		self.ub = 0
		cpu.write_mem(self, 0, self.pc)
		self.pc = 1
	end

	local pc_val = self.pc
	local fetch_addr = bor(self.if_field, pc_val)
	local ir = cpu.read_mem(self, fetch_addr)
	self.pc = band(pc_val + 1, 0xFFF)

	-- Instruction fetch clears ION delay
	self.int_req = bor(self.int_req, INT_NO_ION_PENDING)

	local op = rshift(ir, 9)

	if op < 6 then
		-- Memory Reference Instructions
		local is_indirect = band(ir, 0x100) ~= 0 -- bit 3 (0400 octal)
		local is_curr_page = band(ir, 0x80) ~= 0 -- bit 4 (0200 octal)
		local offset = band(ir, 0x7F)            -- bits 5-11 (0177 octal)

		local ma = is_curr_page and bor(band(pc_val, 0xF80), offset) or offset
		local target_addr = 0

		if is_indirect then
			local ptr_addr = bor(self.if_field, ma)
			-- Autoindex registers: locations 0010-0017 in ANY field
			if band(ptr_addr, 0xFF8) == 0x8 then
				local inc_val = band(cpu.read_mem(self, ptr_addr) + 1, 0xFFF)
				cpu.write_mem(self, ptr_addr, inc_val)
				ma = inc_val
			else
				ma = cpu.read_mem(self, ptr_addr)
			end

			if op == 4 or op == 5 then
				target_addr = bor(self.if_field, ma)
			else
				target_addr = bor(self.df_field, ma)
			end
		else
			target_addr = bor(self.if_field, ma)
		end

		if op == 0 then
			-- AND
			local data = cpu.read_mem(self, target_addr)
			self.lac = band(self.lac, bor(data, 0x1000))
		elseif op == 1 then
			-- TAD
			local data = cpu.read_mem(self, target_addr)
			self.lac = band(self.lac + data, 0x1FFF)
		elseif op == 2 then
			-- ISZ
			local data = band(cpu.read_mem(self, target_addr) + 1, 0xFFF)
			cpu.write_mem(self, target_addr, data)
			if data == 0 then
				self.pc = band(self.pc + 1, 0xFFF)
			end
		elseif op == 3 then
			-- DCA
			cpu.write_mem(self, target_addr, band(self.lac, 0xFFF))
			self.lac = band(self.lac, 0x1000)
		elseif op == 4 then
			-- JMS
			self.if_field = self.ib_field
			self.uf = self.ub
			self.int_req = bor(self.int_req, INT_NO_CIF_PENDING)
			local sub_addr = bor(self.if_field, ma)
			cpu.write_mem(self, sub_addr, self.pc)
			self.pc = band(ma + 1, 0xFFF)
		elseif op == 5 then
			-- JMP
			self.if_field = self.ib_field
			self.uf = self.ub
			self.int_req = bor(self.int_req, INT_NO_CIF_PENDING)
			self.pc = ma
		end

	elseif op == 7 then
		-- Operate Instructions (OPR)
		if band(ir, 0x100) == 0 then
			-- Group 1: CLA/CLL -> CMA/CML -> IAC -> Rotations
			local lac = self.lac
			local seq1 = band(rshift(ir, 4), 0xF)

			if seq1 == 1 then
				lac = bxor(lac, 0x1000) -- CML
			elseif seq1 == 2 then
				lac = bxor(lac, 0xFFF) -- CMA
			elseif seq1 == 3 then
				lac = bxor(lac, 0x1FFF)
			elseif seq1 == 4 then
				lac = band(lac, 0xFFF) -- CLL
			elseif seq1 == 5 then
				lac = bor(band(lac, 0xFFF), 0x1000) -- STL
			elseif seq1 == 6 then
				lac = band(bxor(lac, 0xFFF), 0xFFF)
			elseif seq1 == 7 then
				lac = bor(band(bxor(lac, 0xFFF), 0xFFF), 0x1000)
			elseif seq1 == 8 then
				lac = band(lac, 0x1000) -- CLA
			elseif seq1 == 9 then
				lac = bxor(band(lac, 0x1000), 0x1000)
			elseif seq1 == 10 then
				lac = bor(lac, 0xFFF) -- STA
			elseif seq1 == 11 then
				lac = bxor(bor(lac, 0xFFF), 0x1000)
			elseif seq1 == 12 then
				lac = 0 -- CLA CLL
			elseif seq1 == 13 then
				lac = 0x1000
			elseif seq1 == 14 then
				lac = 0xFFF
			elseif seq1 == 15 then
				lac = 0x1FFF
			end

			if band(ir, 1) ~= 0 then
				lac = band(lac + 1, 0x1FFF) -- IAC
			end

			local rot = band(rshift(ir, 1), 0x7)
			if rot == 1 then
				-- BSW
				lac = bor(
					band(lac, 0x1000),
					band(rshift(lac, 6), 0x3F),
					lshift(band(lac, 0x3F), 6)
				)
			elseif rot == 2 then
				-- RAL
				lac = band(bor(lshift(lac, 1), rshift(lac, 12)), 0x1FFF)
			elseif rot == 3 then
				-- RTL
				lac = band(bor(lshift(lac, 2), rshift(lac, 11)), 0x1FFF)
			elseif rot == 4 then
				-- RAR
				lac = band(bor(rshift(lac, 1), lshift(lac, 12)), 0x1FFF)
			elseif rot == 5 then
				-- RTR
				lac = band(bor(rshift(lac, 2), lshift(lac, 11)), 0x1FFF)
			end

			self.lac = lac

		else
			-- Group 2 or Group 3
			if band(ir, 1) == 0 then
				-- Group 2: Skips and CLA / OSR / HLT
				local lac = self.lac
				local skip_code = band(rshift(ir, 3), 0xF)
				local do_skip = false

				if skip_code == 1 then
					do_skip = true
				elseif skip_code == 2 then
					do_skip = lac >= 0x1000 -- SNL
				elseif skip_code == 3 then
					do_skip = lac < 0x1000 -- SZL
				elseif skip_code == 4 then
					do_skip = band(lac, 0xFFF) == 0 -- SZA
				elseif skip_code == 5 then
					do_skip = band(lac, 0xFFF) ~= 0 -- SNA
				elseif skip_code == 6 then
					do_skip = (band(lac, 0xFFF) == 0) or (lac >= 0x1000)
				elseif skip_code == 7 then
					do_skip = (band(lac, 0xFFF) ~= 0) and (lac < 0x1000)
				elseif skip_code == 8 then
					do_skip = band(lac, 0x800) ~= 0 -- SMA
				elseif skip_code == 9 then
					do_skip = band(lac, 0x800) == 0 -- SPA
				elseif skip_code == 10 then
					do_skip = (band(lac, 0x800) ~= 0) or (lac >= 0x1000)
				elseif skip_code == 11 then
					do_skip = (band(lac, 0x800) == 0) and (lac < 0x1000)
				elseif skip_code == 12 then
					do_skip = (band(lac, 0x800) ~= 0) or (band(lac, 0xFFF) == 0)
				elseif skip_code == 13 then
					do_skip = (band(lac, 0x800) == 0) and (band(lac, 0xFFF) ~= 0)
				elseif skip_code == 14 then
					do_skip = (band(lac, 0x800) ~= 0)
						or (band(lac, 0xFFF) == 0)
						or (lac >= 0x1000)
				elseif skip_code == 15 then
					do_skip = (band(lac, 0x800) == 0)
						and (band(lac, 0xFFF) ~= 0)
						and (lac < 0x1000)
				end

				if do_skip then
					self.pc = band(self.pc + 1, 0xFFF)
				end

				if band(ir, 0x80) ~= 0 then
					lac = band(lac, 0x1000) -- CLA
				end
				if self.uf ~= 0 or self.ub ~= 0 then
					if band(ir, 0x6) ~= 0 then
						-- HLT or OSR in user mode triggers user mode trap
						self.int_req = bor(self.int_req, INT_UF)
						self.int_req = band(self.int_req, bnot(INT_ION))
						self.sf_field = bor(
							lshift(self.uf ~= 0 and 1 or self.ub, 6),
							rshift(self.if_field, 9),
							rshift(self.df_field, 12)
						)
						self.if_field = 0
						self.ib_field = 0
						self.df_field = 0
						self.uf = 0
						self.ub = 0
						cpu.write_mem(self, 0, self.pc)
						self.pc = 1
						self.lac = lac
						return types.SCPE_OK
					end
				else
					if band(ir, 0x4) ~= 0 then
						lac = bor(lac, self.sr) -- OSR
					end
					if band(ir, 0x2) ~= 0 then
						self.halted = true -- HLT
					end
				end

				self.lac = lac

			else
				-- Group 3: KE8-E EAE
				local temp = self.mq
				if band(ir, 0x80) ~= 0 then
					self.lac = band(self.lac, 0x1000) -- CLA
				end
				if band(ir, 0x10) ~= 0 then
					-- MQL
					self.mq = band(self.lac, 0xFFF)
					self.lac = band(self.lac, 0x1000)
				end
				if band(ir, 0x40) ~= 0 then
					-- MQA
					self.lac = bor(self.lac, temp)
				end

				-- Mode switch instructions (07431 octal = SWAB, 07447 octal = SWBA)
				if ir == oct"07431" then
					self.emode = 1
				elseif ir == oct"07447" then
					self.emode = 0
					self.gtf = 0
				else
					if self.emode == 0 then
						self.gtf = 0
					end

					-- Decode IR<6,8:10>
					local sub_op = band(rshift(ir, 1), oct"027")
					if sub_op == oct"020" then
						-- SCA
						self.lac = bor(self.lac, self.sc)
					elseif sub_op == oct"021" then
						-- DAD (Mode B) or SCA + SCL (Mode A)
						if self.emode == 1 then
							local ma_op = bor(self.if_field, self.pc)
							if band(ma_op, 0xFF8) == 0x8 then
								ma_op = bor(self.df_field, band(cpu.read_mem(self, ma_op) + 1, 0xFFF))
								cpu.write_mem(self, bor(self.if_field, self.pc), band(ma_op, 0xFFF))
							else
								ma_op = bor(self.df_field, cpu.read_mem(self, ma_op))
							end
							self.mq = self.mq + cpu.read_mem(self, ma_op)
							ma_op = bor(self.df_field, band(ma_op + 1, 0xFFF))
							self.lac = band(self.lac, 0xFFF)
								+ cpu.read_mem(self, ma_op)
								+ rshift(self.mq, 12)
							self.mq = band(self.mq, 0xFFF)
							self.pc = band(self.pc + 1, 0xFFF)
						else
							self.lac = bor(self.lac, self.sc)
							local d = cpu.read_mem(self, bor(self.if_field, self.pc))
							self.sc = band(bnot(d), 0x1F)
							self.pc = band(self.pc + 1, 0xFFF)
						end
					elseif sub_op == oct"001" then
						-- Mode B: ACS, Mode A: SCL
						if self.emode == 1 then
							self.sc = band(self.lac, 0x1F)
							self.lac = band(self.lac, 0x1000)
						else
							local d = cpu.read_mem(self, bor(self.if_field, self.pc))
							self.sc = band(bnot(d), 0x1F)
							self.pc = band(self.pc + 1, 0xFFF)
						end
					elseif sub_op == oct"002" or sub_op == oct"022" then
						-- MUY / DST
						if sub_op == oct"022" and self.emode == 1 then
							-- DST (Mode B)
							local ma_op = bor(self.if_field, self.pc)
							if band(ma_op, 0xFF8) == 0x8 then
								ma_op = bor(self.df_field, band(cpu.read_mem(self, ma_op) + 1, 0xFFF))
								cpu.write_mem(self, bor(self.if_field, self.pc), band(ma_op, 0xFFF))
							else
								ma_op = bor(self.df_field, cpu.read_mem(self, ma_op))
							end
							cpu.write_mem(self, ma_op, band(self.mq, 0xFFF))
							ma_op = bor(self.df_field, band(ma_op + 1, 0xFFF))
							cpu.write_mem(self, ma_op, band(self.lac, 0xFFF))
							self.pc = band(self.pc + 1, 0xFFF)
						else
							if sub_op == oct"022" then
								self.lac = bor(self.lac, self.sc)
							end
							local ma_op = bor(self.if_field, self.pc)
							if self.emode == 1 then
								if band(ma_op, 0xFF8) == 0x8 then
									ma_op = bor(self.df_field, band(cpu.read_mem(self, ma_op) + 1, 0xFFF))
									cpu.write_mem(self, bor(self.if_field, self.pc), band(ma_op, 0xFFF))
								else
									ma_op = bor(self.df_field, cpu.read_mem(self, ma_op))
								end
							end
							local prod = (self.mq * cpu.read_mem(self, ma_op))
								+ band(self.lac, 0xFFF)
							self.lac = band(rshift(prod, 12), 0xFFF)
							self.mq = band(prod, 0xFFF)
							self.pc = band(self.pc + 1, 0xFFF)
							self.sc = 0xC
						end
					elseif sub_op == oct"003" or sub_op == oct"023" then
						-- DVI / SWBA
						if sub_op == oct"023" and self.emode == 0 then
							self.lac = bor(self.lac, self.sc)
						end
						if not (sub_op == oct"023" and self.emode == 1) then
							local ma_op = bor(self.if_field, self.pc)
							if self.emode == 1 then
								if band(ma_op, 0xFF8) == 0x8 then
									ma_op = bor(self.df_field, band(cpu.read_mem(self, ma_op) + 1, 0xFFF))
									cpu.write_mem(self, bor(self.if_field, self.pc), band(ma_op, 0xFFF))
								else
									ma_op = bor(self.df_field, cpu.read_mem(self, ma_op))
								end
							end
							local divisor = cpu.read_mem(self, ma_op)
							local dividend_hi = band(self.lac, 0xFFF)
							if dividend_hi >= divisor then
								self.lac = bor(self.lac, 0x1000)
								self.mq = band(lshift(self.mq, 1) + 1, 0xFFF)
								self.sc = 0
							else
								local dividend = bor(lshift(dividend_hi, 12), self.mq)
								self.mq = math.floor(dividend / divisor)
								self.lac = dividend % divisor
								self.sc = 0xD
							end
							self.pc = band(self.pc + 1, 0xFFF)
						end
					elseif sub_op == oct"004" or sub_op == oct"024" then
						-- NMI / DPSZ
						if sub_op == oct"024" and self.emode == 1 then
							if band(bor(self.lac, self.mq), 0xFFF) == 0 then
								self.pc = band(self.pc + 1, 0xFFF)
							end
						else
							if sub_op == oct"024" then
								self.lac = bor(self.lac, self.sc)
							end
							local t = bor(lshift(self.lac, 12), self.mq)
							self.sc = 0
							while band(t, 0x7FFFFF) ~= 0 and
								band(t, 0x800000) == band(lshift(t, 1), 0x800000) do
								t = lshift(t, 1)
								self.sc += 1
							end
							self.lac = band(rshift(t, 12), 0x1FFF)
							self.mq = band(t, 0xFFF)
							if self.emode == 1
								and band(self.lac, 0xFFF) == 0x800
								and self.mq == 0 then
								self.lac = band(self.lac, 0x1000)
							end
						end
					elseif sub_op == oct"005" or sub_op == oct"025" then
						-- SHL / DPIC
						if sub_op == oct"025" and self.emode == 1 then
							local t = band(self.lac + 1, 0xFFF)
							self.lac = self.mq + (t == 0 and 1 or 0)
							self.mq = t
						else
							if sub_op == oct"025" then
								self.lac = bor(self.lac, self.sc)
							end
							local sc_m = cpu.read_mem(self, bor(self.if_field, self.pc))
							self.sc = band(sc_m, 0x1F) + bxor(self.emode, 1)
							local t = 0
							if self.sc <= 25 then
								t = lshift(bor(lshift(self.lac, 12), self.mq), self.sc)
							end
							self.lac = band(rshift(t, 12), 0x1FFF)
							self.mq = band(t, 0xFFF)
							self.pc = band(self.pc + 1, 0xFFF)
							self.sc = (self.emode == 1) and 0x1F or 0
						end
					elseif sub_op == oct"006" or sub_op == oct"026" then
						-- ASR / DCM
						if sub_op == oct"026" and self.emode == 1 then
							local t = band(-self.lac, 0xFFF)
							self.lac = bxor(self.mq, 0xFFF) + (t == 0 and 1 or 0)
							self.mq = t
						else
							if sub_op == oct"026" then
								self.lac = bor(self.lac, self.sc)
							end
							local sc_m = cpu.read_mem(self, bor(self.if_field, self.pc))
							self.sc = band(sc_m, 0x1F) + bxor(self.emode, 1)
							local t = bor(lshift(band(self.lac, 0xFFF), 12), self.mq)
							if band(self.lac, 0x800) ~= 0 then
								t = bor(t, 0xFF000000)
							end
							if self.emode == 1 and self.sc ~= 0 then
								self.gtf = band(rshift(t, self.sc - 1), 1)
							end
							if self.sc > 25 then
								t = (band(self.lac, 0x800) ~= 0) and 0xFFFFFFFF or 0
							else
								t = rshift(t, self.sc)
							end
							self.lac = band(rshift(t, 12), 0x1FFF)
							self.mq = band(t, 0xFFF)
							self.pc = band(self.pc + 1, 0xFFF)
							self.sc = (self.emode == 1) and 0x1F or 0
						end
					elseif sub_op == oct"007" or sub_op == oct"027" then
						-- LSR / SAM
						if sub_op == oct"027" and self.emode == 1 then
							local t = band(self.lac, 0xFFF)
							self.lac = self.mq + bxor(t, 0xFFF) + 1
							self.gtf = bxor((t <= self.mq and 1 or 0), rshift(bxor(t, self.mq), 11))
						else
							if sub_op == oct"027" then
								self.lac = bor(self.lac, self.sc)
							end
							local sc_m = cpu.read_mem(self, bor(self.if_field, self.pc))
							self.sc = band(sc_m, 0x1F) + bxor(self.emode, 1)
							local t = bor(lshift(band(self.lac, 0xFFF), 12), self.mq)
							if self.emode == 1 and self.sc ~= 0 then
								self.gtf = band(rshift(t, self.sc - 1), 1)
							end
							if self.sc > 24 then
								t = 0
							else
								t = rshift(t, self.sc)
							end
							self.lac = band(rshift(t, 12), 0xFFF)
							self.mq = band(t, 0xFFF)
							self.pc = band(self.pc + 1, 0xFFF)
							self.sc = (self.emode == 1) and 0x1F or 0
						end
					end
				end
			end
		end

	elseif op == 6 then
		-- IOT (I/O Transfer)
		if self.uf ~= 0 or self.ub ~= 0 then
			-- User Mode Trap on restricted IOT
			self.int_req = bor(self.int_req, INT_UF)
			self.int_req = band(self.int_req, bnot(INT_ION))
			self.sf_field = bor(
				lshift(self.uf ~= 0 and 1 or self.ub, 6),
				rshift(self.if_field, 9),
				rshift(self.df_field, 12)
			)
			self.if_field = 0
			self.ib_field = 0
			self.df_field = 0
			self.uf = 0
			self.ub = 0
			cpu.write_mem(self, 0, self.pc)
			self.pc = 1
			return types.SCPE_OK
		end

		local dev_num = band(rshift(ir, 3), 0x3F)
		local pulse = band(ir, 0x7)

		if dev_num == 0 then
			-- CPU control IOTs
			if pulse == 0 then
				-- SKON
				if band(self.int_req, INT_ION) ~= 0 then
					self.pc = band(self.pc + 1, 0xFFF)
				end
				self.int_req = band(self.int_req, bnot(INT_ION))
			elseif pulse == 1 then
				-- ION: delayed enable
				self.int_req = band(bor(self.int_req, INT_ION), bnot(INT_NO_ION_PENDING))
			elseif pulse == 2 then
				-- IOF: immediate disable
				self.int_req = band(self.int_req, bnot(INT_ION))
			elseif pulse == 3 then
				-- SRQ: skip on interrupt request
				if band(self.int_req, INT_ALL) ~= 0 then
					self.pc = band(self.pc + 1, 0xFFF)
				end
			elseif pulse == 4 then
				-- GTF: get flags
				self.lac = bor(
					band(self.lac, 0x1000),
					rshift(band(self.lac, 0x1000), 1),
					lshift(self.gtf, 10),
					lshift(band(self.int_req, INT_ALL) ~= 0 and 1 or 0, 9),
					lshift(band(self.int_req, INT_ION) ~= 0 and 1 or 0, 7),
					self.sf_field
				)
			elseif pulse == 5 then
				-- RTF: restore flags
				self.gtf = rshift(band(self.lac, 0x400), 10)
				self.ub = rshift(band(self.lac, 0x40), 6)
				self.ib_field = lshift(band(self.lac, 0x38), 9)
				self.df_field = lshift(band(self.lac, 0x7), 12)
				self.lac = bor(lshift(band(self.lac, 0x800), 1), band(self.lac, 0xFFF))
				self.int_req = band(bor(self.int_req, INT_ION), bnot(INT_NO_CIF_PENDING))
			elseif pulse == 6 then
				-- SGT: skip on GTF
				if self.gtf ~= 0 then
					self.pc = band(self.pc + 1, 0xFFF)
				end
			elseif pulse == 7 then
				-- CAF: clear all flags and reset all devices
				self.gtf = 0
				self.emode = 0
				self.lac = 0
				self.dev_done = 0
				self.int_enable = INT_INIT_ENABLE
				self.int_req = band(self.int_req, INT_NO_CIF_PENDING)
				for i = 1, #self.reset_hooks do
					self.reset_hooks[i]()
				end
				cpu.update_int(self)
			end

		elseif dev_num >= 0x10 and dev_num <= 0x17 then
			-- KM8-E Memory Extension
			if pulse == 1 then
				-- CDF
				self.df_field = lshift(band(ir, 0x38), 9)
			elseif pulse == 2 then
				-- CIF
				self.ib_field = lshift(band(ir, 0x38), 9)
				self.int_req = band(self.int_req, bnot(INT_NO_CIF_PENDING))
			elseif pulse == 3 then
				-- CDF CIF
				self.df_field = lshift(band(ir, 0x38), 9)
				self.ib_field = self.df_field
				self.int_req = band(self.int_req, bnot(INT_NO_CIF_PENDING))
			elseif pulse == 4 then
				local sub_dev = band(dev_num, 0x7)
				if sub_dev == 0 then
					-- CINT: clear user interrupt
					self.int_req = band(self.int_req, bnot(INT_UF))
				elseif sub_dev == 1 then
					-- RDF
					self.lac = bor(self.lac, rshift(self.df_field, 9))
				elseif sub_dev == 2 then
					-- RIF
					self.lac = bor(self.lac, rshift(self.if_field, 9))
				elseif sub_dev == 3 then
					-- RIB
					self.lac = bor(self.lac, self.sf_field)
				elseif sub_dev == 4 then
					-- RMF
					self.ub = rshift(band(self.sf_field, 0x40), 6)
					self.ib_field = lshift(band(self.sf_field, 0x38), 9)
					self.df_field = lshift(band(self.sf_field, 0x7), 12)
					self.int_req = band(self.int_req, bnot(INT_NO_CIF_PENDING))
				elseif sub_dev == 5 then
					-- SINT: skip on user interrupt
					if band(self.int_req, INT_UF) ~= 0 then
						self.pc = band(self.pc + 1, 0xFFF)
					end
				elseif sub_dev == 6 then
					-- CUF: clear user buffer
					self.ub = 0
					self.int_req = band(self.int_req, bnot(INT_NO_CIF_PENDING))
				elseif sub_dev == 7 then
					-- SUF: set user buffer
					self.ub = 1
					self.int_req = band(self.int_req, bnot(INT_NO_CIF_PENDING))
				end
			end

		else
			-- External peripheral devices
			local handler = self.dev_dispatch[dev_num]
			if handler ~= nil then
				local skip = handler(self, pulse, ir)
				if skip ~= 0 then
					self.pc = band(self.pc + 1, 0xFFF)
				end
			end
		end
	end

	local hooks = self.step_hooks
	if hooks ~= nil then
		for i = 1, #hooks do
			hooks[i](self)
		end
	end

	return types.SCPE_OK
end

return cpu
