<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Shell Portability Hardening Program

**Started:** 2026-04-14
**Origin:** `sudo aidevops approve` failing on macOS with `getent: command not found`
**Parent context:** user request to "review those rules to see if we can do that systemically to avoid fails or regressions on both" (bash 3.2 on macOS + bash 4+ on Linux)
**Lead:** t2074 (GH#18784, PR #18785, merged)

## Why this program exists

Three P0 production bugs shipped through green CI in the same week (2026-04-13 → 2026-04-14), all caused by shell portability issues. None was caught by ShellCheck, SonarCloud, Codacy, CodeFactor, CodeRabbit, or the existing test suite. Each shipped to the user's machine and broke core workflow:

| Issue | Script | Failure mode | Detection |
|---|---|---|---|
| **GH#18770** | `pulse-wrapper.sh` | `_pulse_handle_self_check` return 2 killed by set -e before rc capture | launchd kept relaunching; user noticed pulse hadn't run in 27h |
| **GH#18784** | `aidevops.sh:26` | Unguarded `getent passwd` crashed on macOS (no getent binary) | User ran `sudo aidevops approve` and saw `getent: command not found` |
| **GH#18786** | `interactive-session-helper.sh:267` | `_isc_has_in_review` return 1 killed by set -e before rc capture | Silent — protocol was simply never executing, no user-visible failure; discovered during this session while trying to claim the interactive issue |
| **GH#18423** (priors, 2026-04) | `issue-sync-lib.sh` | GNU-awk-only dynamic regex silently broke on BSD awk | TODO.md ref writeback silently failed for weeks on macOS |
| **#17944** (priors, 2026-04) | 6 scripts | `stat` argument order was Linux-first across files | BSD stat quietly ignored the arguments |

Common properties of this bug class:

1. **Syntactically valid** — ShellCheck cannot catch them.
2. **Platform-asymmetric** — one OS works, the other fails.
3. **Silent on the working OS** — Ubuntu CI is always green.
4. **Silent on the broken OS too** — no test actually RUNS the script under real bash with real coreutils.
5. **Partial fixes are common** — a sibling helper gets the correct pattern while the originating file does not (GH#18784 is the canonical example).

The framework already had `.agents/reference/bash-compat.md` covering bash 3.2 vs 4+. It did NOT cover command-level portability between GNU and BSD coreutils. The rules and enforcement both had gaps.

## Program scope

This plan tracks all follow-ups from the GH#18784 investigation and the parallel GH#18770 review. Everything here is additive to what already shipped in PR #18785.

### What PR #18785 (t2074) already shipped

1. **The fix** — `aidevops.sh:26` guard mirroring `approval-helper.sh:33`. One line.
2. **Expanded `bash-compat.md`** into a dual-axis shell-portability reference:
    - Renamed H1 to "Shell Portability: bash version + command coreutils"
    - New "Cross-platform command portability (GNU ↔ BSD ↔ macOS)" section
    - GNU-only command table (13 rows): `getent`, `readlink -f`, `stat --format`, `date -d`, `timeout`, `sed -i`, `sed -r`, `grep -P`, awk dynamic regex, `xargs -r`, `find -printf`, `mktemp --suffix`, `sha256sum`, `base64 -w`
    - macOS-only command table (8 rows): `dscl`, `sw_vers`, `launchctl`, `pbcopy`, `sysctl hw.*`, `defaults`, `security`, `codesign`
    - Canonical portable wrappers table with `file:line` refs to the existing helpers
    - Pre-merge checklist (4 questions) for any shell PR touching coreutils, including a callout for the `set -e` + `local var=$(f)` gotcha
    - Production-failure examples cited in the intro
3. **Regression test** — `test-aidevops-sh-portability.sh` with three assertions: structural grep, runtime simulation (PATH stripped of getent + mocked `id -u`), sibling-guard intact.
4. **Memory lessons stored** — two high-confidence entries on `set -e` capture and coreutils portability.

### Follow-up work (this program)

| # | ID | GH | Tier | Estimate | Summary | Priority |
|---|---|---|---|---|---|---|
| 1 | t2075 | GH#18786 | simple | ~45m | **Fix `interactive-session-helper.sh` set -e kill.** Same bug class as GH#18770. Currently silently breaks the t2056 interactive ownership protocol on every claim. One-file, verbatim fix. | **P0** — silently broken today |
| 2 | t2076 | GH#18787 | standard | ~3h | **Static scanner for unguarded Linux/macOS-only commands.** Enforces the 13+8 table via CI. Without this, the bash-compat.md table is documentation theatre — the next author will still forget a guard and the next review will still miss it. | P1 — prevents recurrence |
| 3 | t2077 | GH#18788 | reasoning | ~2h | **Decision: add macOS runner to CI matrix.** Cost ~$120/mo for ~5 min per run × 10 runs/day. Catches exactly the bug class that keeps shipping. Maintainer call on whether the cost/value trade-off is worth it. | P1 — asymmetric cost of failure |
| 4 | t2079 | GH#18789 | standard | ~2h | **Investigate `StandardOutput=` quoting in `_systemd_escape`.** 3 call sites (`schedulers.sh`, `auto-update-helper.sh`, `repo-sync-helper.sh`). If the quotes aren't stripped by systemd, all three generate broken units and silently drop service output. | P2 — investigate first |
| 5 | t2080 | GH#18790 | simple | ~1.5h | **Canary test for `pulse-wrapper.sh main()` runtime.** Adds a `--canary` flag that exercises `_pulse_handle_self_check` + `acquire_instance_lock` under `set -e` and exits 0. Catches GH#18770-class regressions at CI time. | P1 — prevents recurrence |
| 6 | t2081 | GH#18791 | simple | ~45m | **Fix CodeRabbit auto-review config.** Single-exclusion label list is treated as empty inclusion list → every internal PR skipped. Repeat bug of GH#17904. We're paying for CodeRabbit Pro and getting zero review value on internal PRs. | P2 — fallback works, money wasted |

Total: ~10 hours of follow-up work across 6 tasks. Four are tier:simple or tier:standard (workers can ship them). One (t2077) is tier:reasoning because it's a maintainer cost-vs-safety decision. One (t2079) is investigation-first before implementation.

### Sequencing and dependencies

```text
t2075 (interactive-session-helper) ─┐
                                     ├─ can ship in parallel (independent)
t2081 (coderabbit config) ─────────┘

t2076 (static scanner) ──── requires: bash-compat.md already shipped ✓
                                     └─ unblocks: automated enforcement of the new rules

t2077 (macOS CI matrix) ── requires: nothing (decision task)
                                     └─ unblocks: runtime regression tests on macOS

t2080 (pulse canary) ───── requires: nothing
                                     └─ strongest signal against GH#18770 recurrence

t2079 (systemd quoting) ── requires: Linux test environment (VM or container)
                                     └─ investigation task before fix
```

P0 first (t2075 — silently broken protocol). Then P1s in any order. Then P2s.

### Success criteria for the program

1. Interactive session ownership protocol (t2056) actually works when a user claims an issue — `status:in-review` is applied, pulse sees it, worker does not race. Measured by: open a test issue, run `interactive-session-helper.sh claim`, verify label + assignment land, verify pulse does not dispatch.
2. No unguarded `getent`, `dscl`, `readlink -f`, `stat --format` calls exist in any `.sh` file in the repo. Measured by: the scanner from t2076 passes cleanly on main.
3. At least one test suite actually RUNS `pulse-wrapper.sh` and `aidevops.sh` under real `set -e` on both Linux AND macOS, and asserts they reach a known checkpoint. Measured by: the canary tests from t2080 + PR #18785 are in CI.
4. The pre-merge checklist in `bash-compat.md` has at least one enforcement mechanism beyond human review. Measured by: t2076 scanner exists, blocks PRs on unguarded usage.
5. The CI matrix catches the next GH#18784-class bug at PR time, not post-deploy. Measured by: t2077 decision is made and (if approved) implemented, and the next shell-portability bug surfaces in CI before shipping.

## Out of scope for this program

- Windows portability (no Windows runners, no Windows users of aidevops today)
- Solaris / AIX / other commercial Unices
- Rewriting core helpers in Python or Go (separate architectural conversation)
- Replacing bash with zsh (not happening — bash is the standard for Linux systemd services and macOS headless scripts)
- Self-hosted CI runners (operational overhead + external-PR security is a separate conversation that t2077 can reference if relevant)

## Related work (not this program, but adjacent)

- **Main-branch planning exception (t1990)** — the rule that lets headless sessions edit `TODO.md`, `todo/**`, `README.md` directly on main without a PR. This program uses that exception for planning-only files like this doc.
- **Dispatch dedup (t1996)** — combined signal `(active status label) AND (non-self assignee)`. t2075's fix unblocks the "active status label" half of this on interactive-session-helper-claimed issues.
- **Parent-task labelling (t1986)** — the `parent-task` label makes an issue block dispatch unconditionally. This program does NOT use it; each follow-up above is a self-contained implementation task.
- **Brief-first task dispatch** — each follow-up has its full implementation context in the issue body (as required by t1900). Worker picks up any of t2075/t2076/t2079/t2080/t2081 and has everything needed to ship; t2077 is explicitly a decision task, not a ship-it task.

## Lessons stored in memory

Two high-confidence lessons were stored by the originating session:

1. **set -e + function return code capture kill pattern** — never `f; local rc=$?` under `set -e`; use `if f; then` or `f || rc=$?`. Three production hits in one week (GH#18770, GH#18784, GH#18786).
2. **macOS BSD vs Linux GNU coreutils portability** — canonical wrappers already in-tree (`sed_inplace`, `_timeout_cmd`, `_resolve_real_home`, `detect_default_shell`); full divergence table in `bash-compat.md`; test by stripping the command off PATH and running under `set -euo pipefail`.

Both lessons are recallable via `memory-helper.sh recall --query "..."` in future sessions.
