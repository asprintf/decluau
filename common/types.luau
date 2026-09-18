--[=[
 * decluau: common/types.luau - Shared Simulator Types and Status Codes
 *
 * Adapted from OpenSIMH sim_defs.h.
 * Copyright (c) 1993-2022, Robert M. Supnik and OpenSIMH contributors.
 * Copyright (c) 2026, decluau contributors.
 * Licensed under the BSD-2-Clause-Patent license.
 ]=]

--!strict

export type stat_t = number
export type word_t = number
export type addr_t = number

-- Simulator status / return codes
local SCPE_OK   = 0     -- Success
local SCPE_NXM  = 1     -- Non-existent memory
local SCPE_HALT = 2     -- CPU halt
local SCPE_ARG  = 3     -- Invalid argument
local SCPE_FMT  = 4     -- Invalid data format
local SCPE_CSUM = 5     -- Checksum error
local SCPE_IERR = 6     -- Internal error
local SCPE_STOP = 7     -- Simulation stop requested

export type unit_t = {
	time: number,
	flags: number,
	action: ((unit: unit_t) -> stat_t)?,
	u3: number,
	u4: number,
	u5: number,
	data: any,
}

export type dev_t = {
	name: string,
	units: { unit_t },
	reset: ((dev: dev_t) -> stat_t)?,
	boot: ((unit_no: number, dev: dev_t) -> stat_t)?,
}

return {
	SCPE_OK   = SCPE_OK,
	SCPE_NXM  = SCPE_NXM,
	SCPE_HALT = SCPE_HALT,
	SCPE_ARG  = SCPE_ARG,
	SCPE_FMT  = SCPE_FMT,
	SCPE_CSUM = SCPE_CSUM,
	SCPE_IERR = SCPE_IERR,
	SCPE_STOP = SCPE_STOP,
}
