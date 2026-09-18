# DEC system simulator/emulator written in Luau

decluau is a Digital Equipment Corporation (DEC) hardware simulator written in
pure Luau, adapted from the OpenSIMH framework. It runs on both standalone host
environments via Lune and inside the Roblox engine.

## Architecture

The core emulation engine is platform-agnostic and relies exclusively on
standard Luau language facilities, the `buffer` type, and `bit32`. Platform
dependencies (disk persistence, raw console terminal I/O, event clocks) are
isolated behind a hardware abstraction layer (HAL).

Source organization follows BSD Kernel Normal Form (KNF):

    common/     Shared simulator infrastructure (scheduler, buffers, memory models)
    pdp11/      PDP-11 CPU, MMU, ALU, instruction decoding
    pdp8/       PDP-8 CPU and memory
    dev/        Peripheral device controllers (dl11, rk11, kw11)
    scp/        Simulator Control Program (command shell and script parser)
    platform/   Platform drivers (lune, roblox)
    tests/      Test harnesses, diagnostic verification scripts

## Configuration and Scripts

decluau implements the SIMH SCP command grammar. Command scripts (.ini files)
are executed directly by the simulator control program:

    $ lune run main -- pdp11.ini

When invoked without script arguments, decluau looks for `decluau.ini` in the
working directory or drops into the interactive `sim>` prompt.

## Attribution

Portions of this simulator are adapted from OpenSIMH:
    https://github.com/open-simh/simh
Original software copyright (c) 1993-2022, Robert M. Supnik and contributors.
Licensed under the BSD-2-Clause-Patent license. See LICENSE for full terms.
