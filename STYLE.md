DECLUAU STYLE GUIDE
===================

This document specifies the coding and commit conventions for decluau.
The style is based on classic BSD Kernel Normal Form (KNF, style(9)),
adapted for high-performance systems programming in Luau.

All contributors—human and AI—must follow these rules.


1. DIRECTORY STRUCTURE

Modules sit directly at the root, organized by functional subsystem:

    common/     Shared simulator infrastructure (scheduler, buffers, memory models)
    pdp11/      PDP-11 CPU, MMU, ALU, instruction decoding
    pdp8/       PDP-8 CPU and memory
    dev/        Peripheral device controllers (dl11, rk11, kw11)
    scp/        Simulator Control Program (command shell and script parser)
    platform/   Platform drivers (lune, roblox)
    tests/      Test harnesses, diagnostic verification scripts


2. FILE ANATOMY

Source files must be organized in the following strict order:

    1. File header block comment with description and copyright/attribution.
    2. The strict typing directive: `--!strict`.
    3. Module dependencies (`require`), grouped and sorted:
         a. Host/standard built-in libraries.
         b. Local project modules.
    4. Local cached built-ins (hot-path performance localization).
    5. Type definitions (`export type ..._t`).
    6. Constants, register bitmasks, and opcode definitions.
    7. Private file-scope helper functions.
    8. Public exported functions and methods.
    9. Final module return.

Example header and layout:

    --[=[
     * decluau: pdp11/alu.luau - PDP-11 Arithmetic Logic Unit
     *
     * Adapted from OpenSIMH pdp11_cpu.c.
     * Copyright (c) 1993-2022, Robert M. Supnik and OpenSIMH contributors.
     * Copyright (c) 2026, decluau contributors.
     * Licensed under the BSD-2-Clause-Patent license.
     ]=]

    --!strict

    local band = bit32.band
    local bor = bit32.bor
    local bnot = bit32.bnot
    local bxor = bit32.bxor

    export type word_t = number
    export type psw_t = number

    local PSW_C = 0x0001
    local PSW_V = 0x0002
    local PSW_Z = 0x0004
    local PSW_N = 0x0008

    local alu = {}

    -- ... implementation ...

    return alu


3. WHITESPACE AND FORMATTING

    * Indentation: Real TAB characters (set to 8 or 4 column display width).
      Never use spaces for indentation. Spaces are permitted only for
      in-line column alignment after tabs.
    * Line length: Maximum 80 characters. Wrap long expressions after an
      operator and indent the continuation line.
    * Trailing whitespace: Never leave trailing spaces or tabs on any line.
    * Blank lines: One blank line between functions; two blank lines between
      major logical sections. Do not put blank lines at the beginning or
      end of a function body.


4. NAMING CONVENTIONS

    * Hardware registers and well-known DEC idioms use short lowercase names:
        pc, sp, psw, sr, ir, ea, dst, src, uptr, dptr
    * Multi-word variables, record fields, and functions use snake_case:
        inst_cnt, trap_req, cur_mode, rd_word(), wr_byte()
    * Types end with the `_t` suffix:
        cpustate_t, addr_t, dev_t, unit_t
    * Constants, opcodes, and bitmasks use UPPERCASE_SNAKE:
        OP_MOV, OP_JMP, PSW_ALLCC, UNIBUS_IO_BASE
    * Hardware addresses and DEC opcodes:
        Because Luau lacks 0o literals, write hexadecimal with octal comments:
            local DL11_RCSR = 0xFF70    -- 0177560
            local OP_MOV    = 0x1000    -- 0010000
        Or use an explicit octal conversion helper where readability requires it.


5. COMMENTS

    * Block comments must use standard BSD C-comment formatting:
        --[=[
         * Calculate condition codes for 16-bit subtraction: dst - src.
         * Sets V on 2's complement signed overflow; C on borrow.
         ]=]
    * Single-line comments use `-- ` followed by a capitalized sentence.
    * Trailing comments are permitted only for concise register/bit definitions.


6. CONTROL FLOW

    * Single space between keywords and expressions.
    * Do NOT enclose conditions in redundant parentheses:
        CORRECT:    if val == 0 then
        INCORRECT:  if (val == 0) then
    * Align the `end` statement with the keyword that opened the block.
    * Explicit error returns: functions performing bus/device transactions
      return a status code matching SIMH conventions:
        SCPE_OK = 0, SCPE_NXM = 1 (non-existent memory), SCPE_HALT = 2


7. PERFORMANCE RULES FOR EMULATION PATHS

Inside hot execution loops (`step`, instruction decoding, memory access):
    * Zero runtime allocations: never instantiate tables, closures, or strings.
    * Mutate pre-allocated `buffer` objects and fixed state tables in place.
    * Pack CPU status bits (N, Z, V, C) into a single numeric bitfield.
    * Localize frequently invoked functions (`bit32.*`, `buffer.*`) at file scope.


8. GIT COMMIT STYLE (LINUX 50/72 RULE)

Commit messages must follow the 50/72 format:
    * Subject line: `<component>: Imperative summary under 50 chars`
    * Blank line.
    * Body text wrapped strictly at 72 columns explaining the technical why
      and referencing hardware specifications where appropriate.

The prefix is the component, directory, or topic being modified
(e.g., `pdp11/mmu:`, `dev/rk11:`, `common/sched:`, `scp:`, `build:`).

Example commit:

    pdp11: implement condition code evaluation for SUB

    Evaluate condition codes according to the PDP-11 processor handbook.
    V is asserted when the signs of the operands differ and the result
    sign differs from the destination. C is asserted on borrow.
