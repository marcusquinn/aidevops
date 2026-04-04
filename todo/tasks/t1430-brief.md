<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# t1430: Research rtk-ai/rtk CLI Proxy for Token Reduction Integration

## Origin

- **Created:** 2026-03-10
- **Session:** opencode:rtk-research
- **Created by:** human (user requested research)
- **Conversation context:** User shared <https://github.com/rtk-ai/rtk> and asked to create a research task for integration assessment.

## What

Evaluate rtk (Rust Token Killer) — a CLI proxy that intercepts shell command outputs and compresses them before they reach the LLM context — for integration into aidevops framework.

## Why

Token consumption is a direct cost driver for AI-assisted development. rtk claims 60-90% reduction on common CLI operations (git, ls, grep, test runners) with <10ms overhead. If validated, this could significantly reduce per-session costs across all aidevops-managed projects.

## Research Findings

### rtk Overview

| Attribute | Value |
|-----------|-------|
| **Repo** | [rtk-ai/rtk](https://github.com/rtk-ai/rtk) |
| **Stars** | 5,842 |
| **License** | MIT |
| **Language** | Rust (single binary, zero deps) |
| **Version** | v0.28.2 (2026-03-10, actively maintained) |
| **Binary size** | ~4.1 MB |
| **Startup overhead** | <10ms |
| **Platforms** | macOS (x86/ARM), Linux (x86/ARM), Windows |

### How rtk Works

rtk sits between the LLM agent and shell commands. When an agent runs `git status`, rtk intercepts and compresses the output using command-specific filtering strategies:

1. **Stats extraction** — `git log` (500 chars) -> `"5 commits, +142/-89"` (20 chars, 96% reduction)
2. **Error-only** — test output (200 lines) -> failures only (20 lines, 90% reduction)
3. **Grouping** — 100 lint errors -> grouped by rule (`no-unused-vars: 23`, 80% reduction)
4. **Deduplication** — repeated log lines -> `[ERROR] ... (x42)` (70% reduction)
5. **Structure-only** — large JSON -> keys + types without values (80% reduction)
6. **Code filtering** — source files -> signatures only, strip bodies (60-90% reduction)

### Measured Output Compression (on aidevops repo)

| Command | Raw (bytes) | rtk (bytes) | Reduction |
|---------|-------------|-------------|-----------|
| `git status` (clean) | 100 | 24 | **76%** |
| `git log -5` | 2,556 | 352 | **86%** |
| `gh pr list` | 387 | 274 | **29%** |
| `ls .agents/scripts/` | ~3,000 | ~800 | **~73%** |

### Integration Mechanism

rtk offers two modes:

1. **Prefix mode** — manually prefix commands: `rtk git status` instead of `git status`
2. **Hook mode** — Claude Code `PreToolUse` hook transparently rewrites commands before execution (100% adoption, zero context overhead)

### Compatibility Assessment

#### What rtk WOULD compress (Bash tool calls from agents)

| Operation | Frequency in sessions | rtk savings | Impact |
|-----------|----------------------|-------------|--------|
| `git status/diff/log` | Very high | 75-92% | **High** |
| `git add/commit/push` | High | 92% | **Medium** (already small) |
| `gh pr list/view/create` | Medium | 29-87% | **Medium** |
| `shellcheck`, linters | Medium | 80-85% | **Medium** |
| Test runners | Low-Medium | 90%+ | **Medium** |

#### What rtk would NOT affect (already optimized)

| Operation | Why unaffected |
|-----------|---------------|
| MCP Read/Edit/Write/Grep/Glob tools | Bypass shell entirely |
| `git ls-files`, `fd`, `rg` file discovery | build.txt already mandates these over `ls`/`find` — rtk adds marginal value |
| Helper scripts (`*.sh`) | Run in subshell, not intercepted by hook |
| Task/subagent tool calls | MCP protocol, not bash |

#### Conflict Risk Assessment

| Concern | Risk | Reason |
|---------|------|--------|
| Helper scripts parsing git output | **None** | Scripts call `git` directly in subshells, rtk hook only intercepts LLM Bash tool calls |
| Exit code preservation | **None** | rtk preserves exit codes by design (critical for CI/CD) |
| `rtk read` replacing `cat` | **Low** | build.txt already forbids `cat` — agents use MCP Read tool |
| `rtk grep` replacing `rg` | **Low** | build.txt mandates MCP Grep tool for content search |
| Compressed git output breaking agent decisions | **Low** | Agents use MCP tools for file ops; git commands are informational |
| Telemetry (daily ping) | **Low** | Opt-out via `RTK_TELEMETRY_DISABLED=1` or config |

### Platform Compatibility

| Platform | Status |
|----------|--------|
| Linux x86_64 (our primary) | **Verified** — installed and tested |
| macOS ARM64 | **Supported** — pre-built binary available |
| macOS x86_64 | **Supported** — pre-built binary available |
| Homebrew | **Available** — `brew install rtk` |

### Cost Savings Projection

Observability metrics are empty (fresh install), so projecting from rtk's benchmarks:

**Typical 30-min aidevops session (estimated):**

| Operation | Frequency | Standard tokens | rtk tokens | Saved |
|-----------|-----------|----------------|------------|-------|
| git status/diff/log | 15x | 5,000 | 1,000 | 4,000 |
| gh pr/issue ops | 5x | 2,000 | 600 | 1,400 |
| Linter/test output | 5x | 10,000 | 1,500 | 8,500 |
| ls/find (residual bash) | 3x | 600 | 150 | 450 |
| **Subtotal bash** | | **17,600** | **3,250** | **14,350 (81%)** |

**Important context:** Most file operations in aidevops use MCP tools (Read, Grep, Glob), not bash. The 81% reduction applies only to the bash-command subset of token usage. Overall session token reduction would be lower — estimated **15-25%** of total tokens, depending on the ratio of bash vs MCP tool usage.

At scale (100+ worker sessions/week), even 15-25% reduction is material.

## Recommendation: ADAPT

**Adopt rtk as an optional optimization layer, not a mandatory dependency.**

### Rationale

1. **Genuine value for bash-heavy operations** — git, gh, test runners see 75-92% reduction. These are real costs.
2. **Zero risk to existing workflows** — rtk only affects Bash tool calls, not MCP tools or helper scripts. Fail-safe: unrecognized commands pass through unchanged.
3. **Low integration cost** — single binary install, no config required for prefix mode.
4. **Partial overlap with existing discipline** — build.txt already mandates `git ls-files`/`fd`/`rg` over `ls`/`find`/`grep`, and MCP Read over `cat`. rtk's biggest wins are in areas we already avoid via bash.
5. **Hook mechanism is platform-specific** — PreToolUse hooks are Claude Code-only. OpenCode (our primary runtime) doesn't have equivalent hooks yet. This limits adoption to manual prefix mode or prompt discipline.

### Integration Plan

**Phase 1: Install + prompt guidance (low effort, immediate)**
- Add rtk to `setup.sh` optional tooling (install via curl or brew)
- Add guidance to `build.txt`: "When using Bash for git/gh/test commands, prefer `rtk` prefix for token savings"
- Disable telemetry by default (`RTK_TELEMETRY_DISABLED=1` in dispatch env)
- Add to `upstream-watch.json` for release monitoring

**Phase 2: Measure actual savings (after Phase 1 deployed)**
- Correlate `rtk gain --format json` data with observability metrics
- Determine actual ROI from real sessions before deeper integration

**Phase 3: Hook integration (when platform supports it)**
- When OpenCode adds PreToolUse hooks (or equivalent), wire rtk-rewrite.sh for transparent adoption
- This would increase adoption from "when agents remember to prefix" to "100% automatic"

### What NOT to do

- Don't make rtk a hard dependency — it's an optimization, not a requirement
- Don't rewrite helper scripts to use rtk — they run in subshells, unaffected
- Don't replace MCP tool guidance with rtk — MCP tools are more reliable for file ops
- Don't enable telemetry in headless/worker mode

## Acceptance Criteria

- [x] rtk repo analyzed (architecture, filters, config, hook mechanism)
- [x] Compatibility with aidevops workflows assessed
- [x] Cost savings projected
- [x] rtk installed and tested on target platform
- [x] Recommendation documented with evidence
- [ ] PR with integration plan (Phase 1 scope)

## References

- [rtk-ai/rtk](https://github.com/rtk-ai/rtk) — source repo
- [ARCHITECTURE.md](https://github.com/rtk-ai/rtk/blob/master/ARCHITECTURE.md) — technical architecture
- [FEATURES.md](https://github.com/rtk-ai/rtk/blob/master/docs/FEATURES.md) — complete command reference
