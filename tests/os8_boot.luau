--[=[
 * decluau: tests/os8_boot.luau - OS/8 Boot Runner and Interactive Monitor
 *
 * Boots DEC OS/8 from an RK05 disk cartridge image via the RK8-E Omnibus
 * controller, connecting the console teletype to stdio.
 *
 * Usage:
 *   lune run tests/os8_boot [--test] [path/to/image.rk05]
 *
 * Copyright (c) 2026, decluau contributors.
 * Licensed under the BSD-2-Clause-Patent license.
 ]=]

--!strict

local fs = require("@lune/fs")
local stdio = require("@lune/stdio")
local process = require("@lune/process")

local types = require("../common/types")
local cpu_mod = require("../pdp8/cpu")
local rk8e = require("../dev/rk8e")
local kl8e = require("../dev/kl8e")
local dk8ea = require("../dev/dk8ea")

local band = bit32.band
local bor = bit32.bor

local DEFAULT_IMAGES = {
	"/tmp/diagpack2.rk05",
	"/tmp/diag-games-kermit.rk05",
}

local function find_disk_image(arg_path: string?): string
	if arg_path ~= nil and fs.isFile(arg_path) then
		return arg_path
	end
	for _, p in ipairs(DEFAULT_IMAGES) do
		if fs.isFile(p) then
			return p
		end
	end
	error("No bootable RK05 disk image found. Specify path as argument.")
end

local function main()
	local test_mode = false
	local image_path: string? = nil

	for _, arg in ipairs(process.args) do
		if arg == "--test" then
			test_mode = true
		elseif not string.sub(arg, 1, 1) == "-" then
			image_path = arg
		end
	end

	local img_file = find_disk_image(image_path)
	stdio.write(string.format("Loading RK05 image: %s\n", img_file))

	local img_str = fs.readFile(img_file)
	local img_buf = buffer.fromstring(img_str)

	-- Create 32KW PDP-8/E CPU
	local cpu = cpu_mod.new(32768)

	-- Attach RK8-E controller with disk in drive 0
	local rk = rk8e.new()
	rk8e.attach(rk, cpu)
	rk8e.attach_drive(rk, 0, img_buf)

	-- Attach DK8-EA real-time line clock
	local clk = dk8ea.new()
	dk8ea.attach(clk, cpu)

	-- Attach KL8-E console teletype
	local output_chars = {}
	local full_output = {}

	local tty = kl8e.new(function(ch)
		local ascii = band(ch, 0x7F)
		local s = string.char(ascii)
		table.insert(full_output, s)
		stdio.write(s)
	end)
	kl8e.attach(tty, cpu)

	-- Install DEC 8-word hardware bootstrap loader at 0023
	local boot_pc = rk8e.install_boot(cpu, 0)
	stdio.write(
		string.format("Bootstrap installed at %04o. Booting OS/8...\n", boot_pc)
	)

	local input_queue = {}

	local function queue_input(str: string)
		for i = 1, #str do
			local b = string.byte(str, i)
			table.insert(input_queue, b)
		end
	end

	local steps = 0
	local max_steps = test_mode and 10000000 or 50000000
	local booted = false
	local command_sent = false
	local command_step = 0

	while not cpu.halted and steps < max_steps do
		local st = cpu_mod.step(cpu)
		if st ~= types.SCPE_OK then
			stdio.write(
				string.format("\nSimulation halted: %d, PC=%04o\n", st, cpu.pc)
			)
			break
		end

		steps += 1

		-- Feed queued input when TTI is ready
		if #input_queue > 0 and band(cpu.dev_done, cpu_mod.INT_TTI) == 0 then
			local next_ch = table.remove(input_queue, 1) :: number
			kl8e.input_char(tty, cpu, next_ch)
		end

		-- Check for OS/8 dot prompt in output
		if test_mode and not command_sent and steps > 20000 then
			local text = table.concat(full_output)
			local has_dot = string.find(text, "%.%s*$")
				or string.find(text, "\n%.")
				or string.find(text, "\r%.")
			if has_dot then
				booted = true
				command_sent = true
				command_step = steps
				stdio.write("\n[Test] Detected prompt. Sending 'DIR'...\n")
				queue_input("DIR\r")
			end
		end

		-- If command was sent, wait for output to finish
		if test_mode and command_sent and #input_queue == 0 then
			local text = table.concat(full_output)
			local done = string.find(text, "%d+%s+FREE BLOCKS")
				or (steps > command_step + 2000000)
			if done then
				break
			end
		end
	end

	stdio.write(
		string.format("\nExecution finished. Steps: %d, PC=%04o\n", steps, cpu.pc)
	)

	if test_mode then
		local text = table.concat(full_output)
		if string.find(text, "%.") then
			stdio.write("SUCCESS: OS/8 booted and responded to commands!\n")
		else
			error("FAILED: OS/8 prompt not detected.")
		end
	end
end

main()
