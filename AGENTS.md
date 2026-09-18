# Agent Guidelines & AI Disclosure

## AI Usage Disclosure

This project uses AI agentic coding tools for development, architecture
modeling, and code generation. Tools utilized by maintainers include:

- Antigravity CLI
- OpenCode
- OpenAI Codex

All AI-generated or AI-assisted contributions must strictly comply with the
rules below and the repository style specification in `STYLE.md`.

## Critical Operational Rules

1. `workspace-dir/` is strictly private local storage:
   - NEVER stage, commit, or push any files inside `workspace-dir/`.
   - Never reference `workspace-dir/` paths in production code or tests.

2. Architecture and Portability:
   - Code in `common/`, `pdp11/`, `pdp8/`, `dev/`, and `scp/` must remain
     100% portable Luau.
   - Never introduce host-specific (`@lune/*`) or engine-specific (Roblox
     globals) dependencies into these directories.
   - All platform-specific I/O must reside under `platform/`.

3. Standards:
   - All code and commit messages must conform to `STYLE.md`.
