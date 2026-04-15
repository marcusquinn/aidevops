<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# t2105 — wire `aidevops issue` CLI subcommand

**Issue:** GH#19042
**Tier:** `tier:simple` (Haiku)
**Origin:** interactive (Marcus, 2026-04-15, post-t2053.1 session)
**Estimate:** 20 min

## What

Add an `issue)` case to the `aidevops` CLI dispatch table that forwards to `interactive-session-helper.sh`, exposing `claim`, `release`, `status`, and `scan-stale` as `aidevops issue <subcommand>`. Also add the new subcommand to the help text. Then verify with a runtime smoke test against a closed issue.

This is plumbing only. The implementation already exists in `interactive-session-helper.sh` — the helper supports `claim <issue> <slug>`, `release <issue> <slug> [--unassign]`, `status [<issue>]`, and `scan-stale`. The CLI is just a thin pass-through dispatcher (same pattern as 30+ other subcommands in `aidevops.sh`).

## Why

`prompts/build.txt` and `.agents/AGENTS.md` both document `aidevops issue release <N>` as a fallback path for releasing stale interactive claims. The documentation has shipped for at least t2056 (the introduction of the interactive-session-helper). The CLI was never wired up — calling `aidevops issue release 18768` today falls through to `Unknown command` and prints the help text. Discovered live on 2026-04-15 while releasing a stale claim on #18768 during the t2053.1 session.

The mismatch is small but actively misleading: documentation tells operators a command exists, the command silently no-ops by hitting the help fallback, and the user has to know to dig out `interactive-session-helper.sh release` from `.agents/scripts/` to actually do the thing.

## How

### File 1: `aidevops.sh` — add dispatch case

Find the existing dispatch line for `approve` (around **line 3861**, inside the `case "$command" in` block in `main()`):

```bash
	approve) _dispatch_helper "approval-helper.sh" "approval-helper.sh" "$@" ;;
```

Add the new case **immediately after it**, on its own line, using the same `_dispatch_helper` pattern that every other subcommand uses:

```bash
	issue) _dispatch_helper "interactive-session-helper.sh" "interactive-session-helper.sh" "$@" ;;
```

That's the entire dispatch wiring. `_dispatch_helper` (defined at line 3710) handles the path resolution between `$AGENTS_DIR/scripts/` (deployed) and `$INSTALL_DIR/.agents/scripts/` (repo). Pass-through `"$@"` forwards every argument, so `aidevops issue release 18768 marcusquinn/aidevops --unassign` becomes `interactive-session-helper.sh release 18768 marcusquinn/aidevops --unassign` exactly.

### File 2: `aidevops.sh` — add help line

Find the existing help line for `approve` in `cmd_help()` (around **line 3514**):

```bash
	echo "  approve <cmd>      Cryptographic issue/PR approval (setup/issue/pr/verify/status)"
```

Add the new help line **immediately after it**, matching the column alignment used by every other entry in this block (subcommand name padded to 19 characters, then description):

```bash
	echo "  issue <cmd>        Interactive issue ownership (claim/release/status/scan-stale)"
```

Do not touch `_help_detailed_sections()` or any other help function — the one-line entry in the main `cmd_help()` block is what gets printed by `aidevops` with no args and `aidevops --help`.

### Verification

Run from the worktree, in this exact order:

```bash
# 1. ShellCheck the file you edited
shellcheck aidevops.sh

# 2. Confirm the new command appears in help output
bash aidevops.sh help | grep "issue <cmd>"
# Expected: one matching line

# 3. Confirm the dispatch reaches the helper (--help is a safe read-only call)
bash aidevops.sh issue 2>&1 | grep "interactive-session-helper.sh"
# Expected: the helper's USAGE banner mentioning interactive-session-helper.sh

# 4. Smoke test against a closed issue (release is idempotent and safe on a clean state)
bash aidevops.sh issue status 18768
# Expected: the helper's status output, NOT the aidevops CLI help text

# 5. Confirm the helper's release path is reachable end-to-end
#    (no-op on an issue without status:in-review — the helper handles this gracefully)
bash aidevops.sh issue release 18768 marcusquinn/aidevops
# Expected: "[interactive-session] release: #18768 not in status:in-review — no-op"
#           or "[interactive-session] release: #18768 → status:available"
#           Either is acceptable. NEITHER should be the aidevops CLI Unknown-command fallback.
```

If any of steps 2–5 fall through to `Unknown command: issue` or print the aidevops CLI help block, the wiring is wrong — re-check that the new `issue)` line is inside the `case "$command" in` block (not outside it) and uses a single-line format with the trailing `;;`.

## Acceptance criteria

1. `aidevops issue release <N> <slug>` reaches `interactive-session-helper.sh release <N> <slug>` (verifiable via step 5 above).
2. `aidevops issue status` and `aidevops issue scan-stale` reach the helper's corresponding subcommands (same pass-through).
3. `aidevops help` shows the new `issue <cmd>` line in the main subcommand listing.
4. `shellcheck aidevops.sh` is clean (no new violations).

## Out of scope

- **Changing `interactive-session-helper.sh`** — the helper already has the implementation. Do not touch it.
- **Adding new subcommands** beyond what the helper exposes. If the helper grows new subcommands later, the pass-through inherits them automatically.
- **Updating `_help_detailed_sections()`** with a verbose `aidevops issue ...` example block. The one-line entry in `cmd_help()` is sufficient and matches the convention of `approve`, `secret`, `config`, etc.
- **Removing the `/release-issue` slash command** if it exists. Both fallbacks should coexist.
- **Documentation sync**: `prompts/build.txt` and `.agents/AGENTS.md` already reference the command — they become accurate once this PR ships, no edits needed.

## Tier checklist (tier:simple)

- [x] ≤2 files modified (just `aidevops.sh`)
- [x] Verbatim code blocks with exact line locations
- [x] No skeleton — every change is copy-pasteable
- [x] No error/fallback logic to design (`_dispatch_helper` already handles missing-helper case)
- [x] Estimate ≤1h (20 min)
- [x] ≤4 acceptance criteria
- [x] No judgment keywords (no "consider", "decide", "evaluate")

## Related

- **Discovered in:** t2053.1 / PR #19028 / interactive session 2026-04-15
- **Helper:** `.agents/scripts/interactive-session-helper.sh` (already implements all subcommands; t2056)
- **Documentation that promises this works:** `.agents/prompts/build.txt` "Interactive issue ownership" → `aidevops issue release <N>` line; `.agents/AGENTS.md` Git Workflow section
- **Same pattern for reference:** `aidevops approve` → `approval-helper.sh` (line 3861 in `aidevops.sh`)
