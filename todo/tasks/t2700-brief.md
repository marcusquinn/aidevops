---
mode: subagent
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->
# t2700: redirect broken routine run: fields to aidevops CLI via bin/ wrapper shims

## Pre-flight (auto-populated by briefing workflow)

- [x] Memory recall: `routine run field wrapper bin aidevops CLI` → 0 hits — no relevant prior lessons
- [x] Discovery pass: 1 commit / 0 merged PRs / 0 open PRs touch target files in last 48h (only `b13d19301` on pre-push-hooks, unrelated)
- [x] File refs verified: 8 refs checked, all present at HEAD (core-routines.sh:20,24,28,188,392,552 + pulse-routines.sh:107-117 + test:89)
- [x] Tier: `tier:standard` — 6 files, narrative brief, no oldString/newString blocks in strict form

## Origin

- **Created:** 2026-04-21
- **Session:** Claude Code CLI interactive
- **Created by:** marcusquinn (human, via ai-interactive)
- **Parent task:** none
- **Conversation context:** robstiles filed GH#20315 reporting that routines r902, r906, r910, and r912 dispatch to non-existent scripts. Triage confirmed three of four failures share a root cause (wrapper path + arg-in-run: bug). Interactive session takes the three-wrapper fix; r912 dashboard is deferred (unrelated issue — separate decision needed).

## What

Three routines currently fail every pulse cycle because `pulse-routines.sh` tries to execute wrapper scripts that do not exist in the deployed tree. After this PR:

- `~/.aidevops/agents/bin/aidevops-auto-update` exists, invokes `aidevops auto-update check` via the shell PATH, and exits 0 on current setups.
- `~/.aidevops/agents/bin/aidevops-repo-sync` exists, invokes `aidevops repo-sync check`.
- `~/.aidevops/agents/bin/aidevops-skills-sync` exists, invokes `aidevops skill generate`.
- Routine entries in `core-routines.sh` resolve to single-token paths so the `-x` check in `pulse-routines.sh` succeeds.
- On the next pulse cycle after deploy, r902/r906/r910 run to completion without "script not found or not executable" errors in `~/.aidevops/logs/pulse-wrapper.log`.

## Why

GH#20315 observed r902/r906/r910 printing `[pulse-wrapper] routine rNNN: script not found or not executable: /Users/…/.aidevops/agents/bin/aidevops-<name> check` on every dispatch. Two compounding bugs:

1. **Wrapper path mismatch.** Entries point to `bin/aidevops-<name>` (resolved against `~/.aidevops/agents/`), but the wrappers that do exist live at `~/.aidevops/bin/` (one directory up). Only `gh_create_issue` and `gh_create_pr` shipped under `.agents/bin/`.
2. **Space-as-separator bug.** Entries for r902 and r906 append `check` after the path. `pulse-routines.sh:109` constructs `script_path="${agents_dir}/${run_script}"` and then executes `"$script_path"` as a single quoted argv — so even if the wrapper existed, the trailing ` check` would make the resolved "filename" include a literal space that no file can match.

Consequence: the three routines have never actually run on any install. Users silently miss auto-update polling, daily repo sync, and SKILL.md regeneration. The symptoms surface in pulse logs but not in user-facing flows, which is why the bug survived this long.

## Tier

### Tier checklist

- [x] 2 or fewer files to modify? **No** — 6 files (3 new wrappers + core-routines.sh + 1 test + brief + TODO.md)
- [x] Every target file under 500 lines? **No** — core-routines.sh is 814 lines
- [x] Exact `oldString`/`newString` for every edit? **Not required** (narrative description sufficient for standard tier)
- [x] No judgment or design decisions? **One judgment call** — picking `skill generate` vs `skill update` for r910 (resolved in Why section below)
- [x] No error handling or fallback logic to design? **Minimal** — PATH discovery + `command -v` check in wrappers
- [x] No cross-package or cross-module changes? Yes, all in `.agents/`
- [x] Estimate 1h or less? Yes
- [x] 4 or fewer acceptance criteria? Yes

**Selected tier:** `tier:standard`

**Tier rationale:** multi-file (6 files), one file over 500 lines (core-routines.sh), one judgment call (generate vs update for r910). Narrative brief with file references is sufficient; not a simple-tier transcription task.

## PR Conventions

GH#20315 is a leaf issue (no `parent-task` label). PR body uses `Resolves #20315`.

## How (Approach)

### Worker Quick-Start

Not needed — this task is small enough that Implementation Steps below cover it directly.

### Files to Modify

- `NEW: .agents/bin/aidevops-auto-update` — execs `aidevops auto-update check`; model on `.agents/bin/gh_create_issue` (SPDX header + `set -euo pipefail` + minimal PATH discovery)
- `NEW: .agents/bin/aidevops-repo-sync` — execs `aidevops repo-sync check`; same pattern
- `NEW: .agents/bin/aidevops-skills-sync` — execs `aidevops skill generate`; same pattern
- `EDIT: .agents/scripts/routines/core-routines.sh:20` — drop ` check` from r902 pipe entry
- `EDIT: .agents/scripts/routines/core-routines.sh:24` — drop ` check` from r906 pipe entry
- `EDIT: .agents/scripts/routines/core-routines.sh:188` — update r902 describe Schedule table
- `EDIT: .agents/scripts/routines/core-routines.sh:392` — update r906 describe Schedule table
- `EDIT: .agents/scripts/routines/core-routines.sh:552` — annotate r910 describe Schedule table
- `EDIT: .agents/scripts/tests/test-pulse-routines-cron-extraction.sh:89` — drop ` check` from r906 test fixture
- `EDIT: TODO.md` — add t2700 entry with `ref:GH#20315 #interactive`

### Implementation Steps

1. **Create the three wrapper scripts** under `.agents/bin/`. Each wrapper:
   - Starts with `#!/usr/bin/env bash` and SPDX header.
   - Uses `set -euo pipefail`.
   - Prepends `/usr/local/bin` and `${HOME}/.local/bin` to `PATH` so cron/launchd (which start children with minimal PATH — typically `/usr/bin:/bin`) can still find `aidevops` (installed by `setup-modules/config.sh::install_aidevops_cli` as a symlink to either of those two locations).
   - Hard-fails with a descriptive stderr message if `command -v aidevops` still returns nothing after the PATH prepend.
   - `exec aidevops <subcmd> <arg> "$@"` so any routine-supplied args are forwarded.
   - chmod +x on the source file so rsync deploy preserves the executable bit (setup-modules/agent-deploy.sh only chmods `scripts/*.sh`, not `bin/*`).

2. **Edit `core-routines.sh` pipe entries** to drop ` check` from r902 and r906. The wrappers now hardcode the subcommand, so the `run:` field must be a single-token path (pulse-routines.sh cannot tokenize the string — see `Why`).

3. **Edit `core-routines.sh` describe functions** (r902 at 188, r906 at 392, r910 at 552) so the user-facing Schedule tables match the new entries. Annotate with `(wraps \`aidevops <subcmd> <arg>\`)` so operators reading `aidevops routine describe r902` see exactly what the wrapper does.

4. **Edit the test fixture** at `test-pulse-routines-cron-extraction.sh:89` to drop ` check` from the `run:` field. The test itself checks `extract_repeat_expr` (not the run path), so it passes either way, but the fixture should reflect reality.

5. **Subcommand choice for r910:** `aidevops skill generate`, NOT `skill update`. Rationale documented inline in the wrapper header. The describe_r910 block says "Regenerates SKILL.md files if source agents changed" and "Lightweight — only processes changed files" — that matches `generate` exactly ("Generate SKILL.md stubs for cross-tool discovery", local-only, fast). `update` pulls from remote GitHub repos (network call, heavier, different operation). If the user intended the remote pull, the describe text is stale and should be fixed separately.

### Verification

```bash
# 1. Each wrapper runs cleanly under a cron-like minimal PATH
for w in aidevops-auto-update aidevops-repo-sync aidevops-skills-sync; do
  bash -c "PATH=/usr/bin:/bin; .agents/bin/$w 2>&1 | head -3; echo exit=\$?"
done

# 2. Core-routines entries parse correctly (single-token run: paths)
bash -c 'source .agents/scripts/routines/core-routines.sh && get_core_routine_entries | grep "^r90[26]\|^r910" | awk -F "|" "{print \$6}"'
# Expected output:
#   bin/aidevops-auto-update
#   bin/aidevops-repo-sync
#   bin/aidevops-skills-sync

# 3. Cron-extraction test still passes after fixture update
bash .agents/scripts/tests/test-pulse-routines-cron-extraction.sh

# 4. Shellcheck clean on new files and edited file
shellcheck .agents/bin/aidevops-auto-update .agents/bin/aidevops-repo-sync .agents/bin/aidevops-skills-sync .agents/scripts/routines/core-routines.sh

# 5. Post-deploy smoke test (after setup.sh --non-interactive rsyncs .agents/ to ~/.aidevops/agents/):
ls -l ~/.aidevops/agents/bin/aidevops-auto-update ~/.aidevops/agents/bin/aidevops-repo-sync ~/.aidevops/agents/bin/aidevops-skills-sync
# All three files present and executable.

# 6. Next pulse cycle post-deploy: no "script not found" errors for r902/r906/r910
tail -50 ~/.aidevops/logs/pulse-wrapper.log | grep -E "routine r(902|906|910):"
# Should show "executing script" and "script completed successfully" — NOT "script not found".
```

### Files Scope

- `.agents/bin/aidevops-auto-update`
- `.agents/bin/aidevops-repo-sync`
- `.agents/bin/aidevops-skills-sync`
- `.agents/scripts/routines/core-routines.sh`
- `.agents/scripts/tests/test-pulse-routines-cron-extraction.sh`
- `todo/tasks/t2700-brief.md`
- `TODO.md`

## Acceptance Criteria

- [ ] Three new files exist at `.agents/bin/aidevops-auto-update`, `.agents/bin/aidevops-repo-sync`, `.agents/bin/aidevops-skills-sync`, all with executable bit set.
  ```yaml
  verify:
    method: bash
    run: "test -x .agents/bin/aidevops-auto-update && test -x .agents/bin/aidevops-repo-sync && test -x .agents/bin/aidevops-skills-sync"
  ```
- [ ] All three wrappers pass `shellcheck` with zero warnings.
  ```yaml
  verify:
    method: bash
    run: "shellcheck .agents/bin/aidevops-auto-update .agents/bin/aidevops-repo-sync .agents/bin/aidevops-skills-sync"
  ```
- [ ] `core-routines.sh` r902, r906, r910 entries have single-token `run:` paths (no trailing ` check`).
  ```yaml
  verify:
    method: bash
    run: "! grep -E 'bin/aidevops-(auto-update|repo-sync) check' .agents/scripts/routines/core-routines.sh"
  ```
- [ ] `test-pulse-routines-cron-extraction.sh` passes.
  ```yaml
  verify:
    method: bash
    run: "bash .agents/scripts/tests/test-pulse-routines-cron-extraction.sh"
  ```

## Out of scope

- **r912 dashboard routine.** GH#20315 also reported r912 pointing at `server/index.ts` which does not exist. That is a separate problem (the dashboard was never finished / is disabled in this deployment) with a different decision tree — disable the routine, ship a stub dashboard, or remove the entry entirely. Belongs in its own issue.
- **Extending `pulse-routines.sh` to tokenize `run:` fields.** Making the dispatcher word-split run: would support future routines that need args, but it is a wider behavioural change with implications for custom user routines under `custom/scripts/`. The wrapper-hardcoded-arg approach fixes the immediate bug without a framework-wide dispatch change. If a future routine needs args in the entry (and a dedicated wrapper does not fit), that is when to revisit tokenization — in its own task.
