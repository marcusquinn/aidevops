<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->
# t2023: harden Bash 3.2 compat scanners and burn down nameref debt

## Origin

- **Created:** 2026-04-13
- **Session:** claude-code:interactive
- **Created by:** Marcus Quinn (human, ai-interactive)
- **Parent task:** none
- **Conversation context:** Follow-up to t17993 / PR #17994 which fixed `${var^}` (single-caret case modification) violations in four helper scripts. User asked "have we caught all the bash 4 → 3.2 issues?" and "does the harness need additional guidance, I thought we already had that?". Audit found the exact pattern that caused t17993 is **not** scanned for by either the local linter or CI, plus real remnants in production code, plus drift between CI and local scanners.

## What

Close four concrete gaps in Bash 3.2 compatibility enforcement so the same class of silent breakage as t17993 cannot recur:

1. **Extend the scanner regexes** in both `.agents/scripts/linters-local.sh` and `.github/workflows/code-quality.yml` to catch the single-letter case-modification forms (`${var^}`, `${var,}`) that bypassed the previous scanner. Also eliminate the drift between the two scanners — CI currently checks a strict subset of what the local linter checks.
2. **Fix `memory-pressure-monitor.sh:464-465`** — the last remaining production-code use of `${var,,}`. The local linter already flags it; the fix converts it to the documented `tr` pattern.
3. **Decide and enforce a strategy for the nameref-heavy scripts** (`compare-models-helper.sh` 43 uses, `email-delivery-test-helper.sh` 12 uses, `document-creation-helper.sh` 11 uses, total 69 under a ratchet of 72). Add a runtime `BASH_VERSINFO` guard at the top of each so they fail fast with a readable error on Bash 3.2 instead of silently breaking mid-execution, and file burn-down subtasks. The current ratchet-and-accept posture is the worst of both worlds: they break anyway, just without explanation.
4. **Update `reference/bash-compat.md`** so both the double-letter and single-letter case-modification forms are listed explicitly. The previous doc only mentioned `${var,,}` / `${var^^}`, which is why the single-letter variants slipped through code review.

After this task: a new `${var^}` introduced in any PR will fail CI, the local linter will match the CI linter, the nameref scripts have an explicit guard and known burn-down path, and the documentation names every forbidden form explicitly.

## Why

t17993 was a runtime-only failure (`bad substitution`) in `approval-helper.sh` on macOS Bash 3.2 that shipped through code review, local testing, PR review, and CI — despite the framework having:

- A dedicated `reference/bash-compat.md` document
- A `_scan_bash32_file` function in `linters-local.sh` with eight categories of checks
- A `bash32-compat` job in `.github/workflows/code-quality.yml` gated on a ratchet

All three pieces exist, all three were supposed to catch this, none of them did. Root cause is mechanical: the scanners only match `,,}` and `^^}` (double forms), not `^}` and `,}` (single forms). A comment in `bash-compat.md` listed only the double forms, which propagated into the scanner regexes.

The supporting problems (`memory-pressure-monitor.sh` uses `,,}` in production code, CI/local drift, and the nameref ratchet with no burn-down plan) compound this: the framework has the *shape* of enforcement without the *coverage*. This task restores coverage and prevents the class of bug from recurring.

## Tier

### Tier checklist (verify before assigning)

Answer each question for `tier:simple`. If **any** answer is "no", use `tier:standard` or higher.

- [ ] **2 or fewer files to modify?** — no, 5+ files
- [x] **Complete code blocks for every edit?** — yes, see Implementation Steps
- [x] **No judgment or design decisions?** — the nameref strategy (guard vs burn-down) is decided in this brief
- [x] **No error handling or fallback logic to design?** — the `BASH_VERSINFO` guards are a fixed template
- [ ] **Estimate 1h or less?** — no, 2-3h
- [ ] **4 or fewer acceptance criteria?** — no, 7 criteria

**Selected tier:** `tier:standard`

**Tier rationale:** Five files to edit across two enforcement layers (local linter + CI workflow), plus four production files to patch, plus a documentation update, plus filing two sub-tasks. Not simple (fails the 2-file and 1h checks). No novel design required — all patterns are already established in the codebase — so not reasoning either.

## How (Approach)

### Files to Modify

- `EDIT: .agents/scripts/linters-local.sh:1235-1242` — add single-letter case-mod regexes alongside the existing double-letter checks
- `EDIT: .github/workflows/code-quality.yml:72-154` — source `check_bash32_compat` from `linters-local.sh` instead of reimplementing a narrower subset, OR add the missing patterns inline (see Implementation Steps for the decision)
- `EDIT: .agents/scripts/memory-pressure-monitor.sh:461-469` — replace `${cmd_name,,}` / `${pattern,,}` with `tr`-based lowercasing; update the comment to stop justifying Bash 4+
- `EDIT: .agents/scripts/compare-models-helper.sh:30-35` — insert a `BASH_VERSINFO` guard right after `set -euo pipefail`
- `EDIT: .agents/scripts/email-delivery-test-helper.sh` — same guard, insert after the script header (find exact line during implementation)
- `EDIT: .agents/scripts/document-creation-helper.sh` — same guard
- `EDIT: .agents/reference/bash-compat.md:14` — expand the case-conversion entry to list all four forms explicitly
- `NEW: todo/tasks/t2024-brief.md` (follow-up burn-down task for `compare-models-helper.sh` nameref refactor — separate task because it's a multi-hour rewrite that doesn't belong in this hardening pass)

### Implementation Steps

1. **Add single-letter case-mod patterns to `_scan_bash32_file`** in `.agents/scripts/linters-local.sh`. The existing function is at `linters-local.sh:1221-1268`. Insert new checks alongside the existing `,,}` / `^^}` ones:

   ```bash
   # ${var^} / ${var,} single-letter case modification (bash 4.0+)
   # This is the pattern that caused t17993 — NOT caught by ,,} / ^^} patterns.
   grep -nE '\$\{[a-zA-Z_][a-zA-Z0-9_]*\^\}' "$file" 2>/dev/null | grep -vE '^[0-9]+:[[:space:]]*#' | while IFS= read -r line; do
       printf '%s:%s [case conversion ^} single-letter — bash 4.0+]\n' "$file" "$line" >>"$tmp_file"
   done
   grep -nE '\$\{[a-zA-Z_][a-zA-Z0-9_]*,\}' "$file" 2>/dev/null | grep -vE '^[0-9]+:[[:space:]]*#' | while IFS= read -r line; do
       printf '%s:%s [case conversion ,} single-letter — bash 4.0+]\n' "$file" "$line" >>"$tmp_file"
   done
   ```

   Self-skip for `linters-local.sh` itself is already in `check_bash32_compat` at line 1288 — no change needed there.

2. **Add the same patterns to the CI workflow** at `.github/workflows/code-quality.yml:133-141`. The CI workflow inlines its own regexes rather than sourcing the shared helper. Quickest fix: add the same two grep blocks after the existing nameref check at line 141. Document (as an inline comment in the workflow) that these inlined patterns MUST stay in sync with `_scan_bash32_file`, and file t2025 to deduplicate by having the workflow source `check_bash32_compat`. Concrete insertion:

   ```yaml
   # ${var^} / ${var,} single-letter case modification (bash 4.0+)
   # Added in t2023 — this is the pattern that caused t17993.
   single_case=$(grep -nE '\$\{[a-zA-Z_][a-zA-Z0-9_]*[\^,]\}' "$file" 2>/dev/null \
     | grep -vE '^[0-9]+:[[:space:]]*#' || true)
   if [ -n "$single_case" ]; then
     while IFS= read -r line; do
       echo "FAIL $file:$line [single-letter case conversion — bash 4.0+]"
       violations=$((violations + 1))
     done <<< "$single_case"
   fi
   ```

3. **Fix `memory-pressure-monitor.sh:461-469`**. The current block:

   ```bash
   else
       # Simple pattern — match against basename only
       # Use bash 4+ ${var,,} lowercasing to avoid tr subprocess forks
       local cmd_lower="${cmd_name,,}"
       local pattern_lower="${pattern,,}"
       if [[ "$cmd_lower" == *"$pattern_lower"* ]]; then
           return 0
       fi
   fi
   ```

   Replace with:

   ```bash
   else
       # Simple pattern — match against basename only.
       # Bash 3.2 compat: no ${var,,} — use tr for lowercasing.
       # The subprocess cost is negligible here (runs once per pattern match,
       # not in a hot loop) and is the price of portability.
       local cmd_lower pattern_lower
       cmd_lower=$(printf '%s' "$cmd_name" | tr '[:upper:]' '[:lower:]')
       pattern_lower=$(printf '%s' "$pattern" | tr '[:upper:]' '[:lower:]')
       if [[ "$cmd_lower" == *"$pattern_lower"* ]]; then
           return 0
       fi
   fi
   ```

4. **Insert `BASH_VERSINFO` guards** at the top of each nameref-heavy script. Insertion point is immediately after `set -euo pipefail` (or equivalent). Template:

   ```bash
   # Bash 4.3+ required — this script uses `local -n` namerefs.
   # Listed under the Bash32Compat ratchet as accepted tech debt.
   # Burn-down tracked in t2024 / t2025 / t2026 (per-script follow-ups).
   if [[ -z "${BASH_VERSINFO[0]:-}" ]] || (( BASH_VERSINFO[0] < 4 || (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] < 3) )); then
       printf '%s: requires bash 4.3+ (namerefs). Running bash %s.\n' \
           "${BASH_SOURCE[0]##*/}" "${BASH_VERSION:-unknown}" >&2
       printf 'Install a newer bash with: brew install bash\n' >&2
       exit 1
   fi
   ```

   Apply to:
   - `.agents/scripts/compare-models-helper.sh` — insert after line 30 (`set -euo pipefail`)
   - `.agents/scripts/email-delivery-test-helper.sh` — find the equivalent line and insert immediately after
   - `.agents/scripts/document-creation-helper.sh` — same

5. **Update `reference/bash-compat.md:14`**. Current line:

   ```markdown
   - `${var,,}` / `${var^^}` (case conversion) — use `tr '[:upper:]' '[:lower:]'`
   ```

   Replace with:

   ```markdown
   - Case conversion — use `tr '[:upper:]' '[:lower:]'` (or `tr '[:lower:]' '[:upper:]'`). ALL four forms are bash 4.0+ and will not error on bash 3.2 — they will silently produce the wrong output or emit `bad substitution` at runtime:
     - `${var^^}` — uppercase all
     - `${var,,}` — lowercase all
     - `${var^}` — uppercase first letter (this is the form that caused t17993)
     - `${var,}` — lowercase first letter
   ```

6. **Decrement the ratchet** in `.agents/configs/complexity-thresholds.conf` if `memory-pressure-monitor.sh:464-465` counts against `BASH32_COMPAT_THRESHOLD`. Verify the count before/after the fix with the existing scanner and adjust the threshold downward by the exact number of violations removed (preserves the burn-down ratchet semantics).

7. **File burn-down follow-ups** as separate tasks (do NOT include in this PR):
   - `t2024 refactor(compare-models): replace local -n namerefs with positional args / temp files` — tier:reasoning, ~6h
   - `t2025 refactor(document-creation): replace local -n namerefs with positional args` — tier:reasoning, ~3h
   - `t2026 refactor(email-delivery-test): replace local -n namerefs with positional args` — tier:standard, ~2h

### Verification

```bash
# 1. Scanner catches the exact t17993 pattern going forward
echo 'x="${foo^}"' > /tmp/bash32-probe.sh
bash .agents/scripts/linters-local.sh --check=bash32 2>&1 | grep -q "single-letter" && echo "OK: scanner catches \${var^}"
rm /tmp/bash32-probe.sh

# 2. memory-pressure-monitor.sh has no remaining case-mod
grep -nE '\$\{[a-zA-Z_][a-zA-Z0-9_]*[,^][,^]?\}' .agents/scripts/memory-pressure-monitor.sh | grep -v '^[0-9]*:[[:space:]]*#' && echo FAIL || echo OK

# 3. Nameref-heavy scripts fail fast on bash 3.2
/bin/bash -c 'bash .agents/scripts/compare-models-helper.sh help 2>&1 | head -3' # should print "requires bash 4.3+" on Bash 3.2
# (or verify BASH_VERSINFO guard is present in source)
grep -c 'BASH_VERSINFO' .agents/scripts/compare-models-helper.sh .agents/scripts/email-delivery-test-helper.sh .agents/scripts/document-creation-helper.sh

# 4. Doc lists all four case-mod forms
grep -c '\${var\^}' .agents/reference/bash-compat.md
grep -c '\${var,}' .agents/reference/bash-compat.md

# 5. Full linter pass
bash .agents/scripts/linters-local.sh 2>&1 | tail -30

# 6. CI workflow locally (using act) if available, otherwise just shellcheck
shellcheck .agents/scripts/linters-local.sh .agents/scripts/memory-pressure-monitor.sh .agents/scripts/compare-models-helper.sh
```

## Acceptance Criteria

- [ ] Both `_scan_bash32_file` in `linters-local.sh` and the `bash32-compat` job in `code-quality.yml` flag `${var^}` and `${var,}` when inserted into a test file.
  ```yaml
  verify:
    method: bash
    run: "printf 'x=\"${foo^}\"\\n' > /tmp/t2023-probe.sh && bash .agents/scripts/linters-local.sh --check=bash32 2>&1 | grep -q 'single-letter' && rm /tmp/t2023-probe.sh"
  ```
- [ ] `memory-pressure-monitor.sh` contains zero `${var,,}` / `${var^^}` / `${var,}` / `${var^}` outside comments.
  ```yaml
  verify:
    method: codebase
    pattern: "\\$\\{[a-zA-Z_][a-zA-Z0-9_]*[,\\^][,\\^]?\\}"
    path: ".agents/scripts/memory-pressure-monitor.sh"
    expect: absent
  ```
- [ ] Each of `compare-models-helper.sh`, `email-delivery-test-helper.sh`, `document-creation-helper.sh` has a `BASH_VERSINFO` guard that exits with a readable error on bash 3.2.
  ```yaml
  verify:
    method: codebase
    pattern: "BASH_VERSINFO"
    path: ".agents/scripts/compare-models-helper.sh"
  ```
- [ ] `reference/bash-compat.md` explicitly lists all four case-mod forms (`${var^}`, `${var,}`, `${var^^}`, `${var,,}`).
  ```yaml
  verify:
    method: bash
    run: "grep -q '\\${var\\^}' .agents/reference/bash-compat.md && grep -q '\\${var,}' .agents/reference/bash-compat.md"
  ```
- [ ] `BASH32_COMPAT_THRESHOLD` in `complexity-thresholds.conf` is decremented by exactly the number of violations removed, OR stays at 72 if the fixed violations weren't counted (the CI scanner doesn't check `,,}`, so they weren't — document the finding in the PR description).
- [ ] Three follow-up burn-down task entries (t2024, t2025, t2026) exist in TODO.md with brief files.
  ```yaml
  verify:
    method: bash
    run: "grep -q '^- \\[ \\] t2024' TODO.md && grep -q '^- \\[ \\] t2025' TODO.md && grep -q '^- \\[ \\] t2026' TODO.md"
  ```
- [ ] `shellcheck` clean on all modified files, `bash .agents/scripts/linters-local.sh` passes, CI `bash32-compat` job passes.

## Context & Decisions

- **Why not just source `check_bash32_compat` from the CI workflow**: that would be cleaner but requires the CI workflow to source `linters-local.sh`, which pulls in the full linter machinery (cleanup scopes, temp files, other checks). Duplicating the two new regex blocks inline is a 10-line change; the consolidation is worth a separate task (filed inline as a TODO in the workflow comment).
- **Why runtime guards instead of refactoring namerefs now**: `compare-models-helper.sh` alone has 43 nameref uses across functions that are architecturally designed around output parameters. Refactoring to positional args/temp files is a multi-hour rewrite that deserves its own task and its own review. The guard is belt-and-braces: if a user on Bash 3.2 runs the script, they get a clear error in 3 lines instead of `local: -n: not a valid identifier` mid-execution.
- **Why not remove from the ratchet entirely**: the ratchet is doing its job (no *new* namerefs are being added; the count is stable). Adding guards plus burn-down tasks converts "accepted tech debt" into "accepted tech debt with a known exit path", which is the correct posture.
- **Why the single-letter patterns weren't scanned**: historical artefact. The scanner was added in GH#17371 as `"\t"`/`"\n"` detection, extended later with associative arrays and namerefs, and extended again when someone added `,,}` / `^^}` — but only the double forms because those were the documented forms. No one reviewed whether the *regex* matched what the *doc* said.
- **Non-goal**: actually refactoring `compare-models-helper.sh` etc. — that's t2024-t2026.
- **Non-goal**: extending `bash-compat.md` to enforce the other currently-unenforced items (`|&`, negative offsets, `mapfile`). Separate scope; file as follow-up if observed.

## Relevant Files

- `.agents/scripts/linters-local.sh:1221-1268` — `_scan_bash32_file`, the local-mode scanner
- `.agents/scripts/linters-local.sh:1270-1295` — `check_bash32_compat`, the local gate
- `.github/workflows/code-quality.yml:72-154` — CI `bash32-compat` job (currently a narrower subset of the local check)
- `.agents/scripts/memory-pressure-monitor.sh:461-469` — the one remaining production-code `${var,,}` block
- `.agents/scripts/compare-models-helper.sh:1017-3000` — nameref usage (43 lines, primary burn-down target)
- `.agents/scripts/document-creation-helper.sh:1509-1625` — nameref usage (11 lines)
- `.agents/scripts/email-delivery-test-helper.sh` — nameref usage (12 lines; exact locations to be determined during implementation)
- `.agents/reference/bash-compat.md:14` — case-conversion doc line that only mentions double forms
- `.agents/configs/complexity-thresholds.conf` — `BASH32_COMPAT_THRESHOLD=72`
- `.agents/scripts/oauth-pool-helper.sh:681-683` — reference implementation of the `printf + tr` pattern for case conversion
- `.agents/scripts/approval-helper.sh:365-370` — reference implementation from PR #17994 (the fix that motivated this task)

## Dependencies

- **Blocked by:** none
- **Blocks:** t2024, t2025, t2026 (nameref refactor tasks that should be filed but not dispatched until this lands — the guards added here let the three scripts keep running in the interim)
- **External:** none

## Estimate Breakdown

| Phase | Time | Notes |
|-------|------|-------|
| Research/read | 15m | Re-read `_scan_bash32_file`, verify CI workflow structure |
| Scanner regex additions | 30m | Two grep blocks × two files (local + CI); test with probe files |
| memory-pressure-monitor fix | 15m | Single block replacement, verify with grep |
| BASH_VERSINFO guards | 30m | Template × 3 files, verify exit behaviour |
| Doc update | 10m | `bash-compat.md` one-line expansion to five lines |
| Follow-up task briefs | 30m | Three stub briefs (t2024/t2025/t2026) with enough context to dispatch later |
| Ratchet decrement + PR | 20m | Run linter, update threshold, write PR body |
| **Total** | **~2.5h** | tier:standard |
