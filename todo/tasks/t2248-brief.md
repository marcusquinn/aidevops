<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# t2248 — fix(complexity-regression): switch bash32-compat metric from line-keyed to count-per-pattern

## Session origin

Surfaced during t2239/PR #19759 (opus-4.7 cascade). Adding a single `# shellcheck disable=SC1091` directive at line 28 of `compare-models-helper.sh` shifted 8 pre-existing `nameref` declarations from lines 1028-2984 → 1029-2985. The Bash 3.2 Compatibility CI job reported `base: 76  head: 76  new: 8` — zero net change, but 8 "new" violations. Resolved by removing the redundant directive (`.shellcheckrc` already globally disables SC1091), but the underlying keying bug remains and will fire again on any PR that adds a line above existing bash32 patterns.

## What

Replace the `(file, '<pattern>:<line>')` identity key used by `scan_dir_bash32_compat` in `.agents/scripts/complexity-regression-helper.sh:301-311` with a `(file, pattern)` key whose value is the count per-pattern per-file. The diff logic should flag as regression only when the per-(file,pattern) count grows in head vs base.

Example report change:

- **Before (fragile):** "New violation: `compare-models-helper.sh nameref:1029`" — identical construct reported as new because line shifted from 1028.
- **After (robust):** "Regression in `compare-models-helper.sh`: nameref 43 → 44 (+1)" — only fires when count grows.

Line numbers should still appear as context in the report body (enumerate current matches with `grep -nE` when reporting the regression) but they must NOT be part of the diff key.

## Why

Four metrics live in `complexity-regression-helper.sh`. Three use logical identity:

| Metric | Key | Robust to line shifts |
|---|---|---|
| function-complexity | `(file, function_name)` | Yes — function moves within file stay matched |
| nesting-depth | `(file, 'NEST')` singleton | Yes — one max value per file |
| file-size | `(file, 'SIZE')` singleton | Yes — one count per file |
| **bash32-compat** | **`(file, '<pattern>:<line>')`** | **No — any insertion above shifts all below** |

bash32-compat is the outlier. The line number adds no semantic value (two namerefs at lines 1028 and 1029 are not "the same violation" by any interesting definition) and makes the gate fire spuriously on unrelated edits. The keying was established in t2171 (PR #19585) and was not reconsidered.

Cost of the status quo:

- Any PR that adds a single line above a bash32 pattern block triggers the gate.
- Authors end up adding the `complexity-bump-ok` label with prose justifying a non-change, or — as happened in t2239 — removing the triggering line (which may be a legitimate improvement, merely misclassified).
- Trust in the gate erodes: when the gate fires and the author has to investigate "new 8 violations" only to find they're all line-shifted duplicates, they stop reading future reports carefully.

## How

Files to modify:

- **EDIT:** `.agents/scripts/complexity-regression-helper.sh`
  - Change `scan_dir_bash32_compat` output format at lines 347, 356 (Pattern 1), and the analogous `printf` calls for Patterns 2-4 (assoc-array, nameref, heredoc-in-subshell). New format: `<file>\t<pattern>\t<count>` with count aggregated per-(file,pattern). The function currently emits one row per match; change it to tally into an associative array keyed by `<file>\t<pattern>` and print each key once with its count.
  - Update `_diff_metrics` (or wherever the bash32 diff logic lives — grep for `bash32` and `new: ` in the same function) to compute `new_count = max(0, head_count - base_count)` per `(file, pattern)` and sum for the `REGRESSION` determination.
  - Update the report generator to enumerate line numbers for context in the regression table body, but NOT use them as the diff key. A fresh `grep -nE '<pattern>' "$file"` at report time gives current lines without polluting the key.
  - Update the docblock comment at lines 25-29 from `Key: (file, '<pattern>:<line>'); value: 1` to `Key: (file, '<pattern>'); value: count`.

- **EDIT:** `.github/workflows/code-quality.yml` — Bash 3.2 Compatibility step. Check whether the step parses or displays line numbers from the regression report — if it does, update it to read from the new format (or let the helper render and pass through the markdown).

- **EDIT:** `.agents/scripts/tests/test-complexity-regression-bash32.sh` (if it exists) or **NEW:** `.agents/scripts/tests/test-complexity-regression-bash32-line-shift.sh`. Regression test that reproduces the t2239 scenario:
  1. Create a fixture `.sh` file with 3 `declare -n` lines at lines 5, 10, 15.
  2. Create a modified version with 1 comment line inserted at line 3 — namerefs now at lines 6, 11, 16.
  3. Run the helper, assert `new: 0` (was 3 under the old key).
  4. Modify again to add a genuinely new nameref at line 20 (original 3 at lines 5, 10, 15). Assert `new: 1`.

## Acceptance criteria

1. `complexity-regression-helper.sh check --base <sha> --metric bash32-compat` reports `new: 0` when the only change is line insertions above existing violations (with no new patterns added).
2. `new: N` is reported correctly when N new bash32 patterns are genuinely added (anywhere in the repo).
3. Regression report still enumerates current line numbers of flagged violations in a "Current locations" column so authors can find them, but those line numbers are not part of the diff key.
4. All existing bash32-compat tests pass (or are updated to match the new report format).
5. New regression test `test-complexity-regression-bash32-line-shift.sh` passes.
6. Run locally against an arbitrary commit pair on this repo: `.agents/scripts/complexity-regression-helper.sh check --base origin/main --metric bash32-compat --dry-run` — confirm existing totals are unchanged (76 → 76) and `new: 0` on a no-semantic-change edit.

## Context

- Root symptom observed in t2239 session: https://github.com/marcusquinn/aidevops/actions/runs/24611818835/job/71967445593
- Related: t2171 (GH#19585) introduced the bash32-compat metric with the fragile keying. This task is the follow-up fix.
- Related: t2216 (GH#19716) tracks a different category of false positive (in `pre-commit-hook.sh:validate_positional_parameters`). Do NOT conflate.
- The other three metrics in the same helper are correct references — model the fix on the `(file, 'NEST')` / `(file, 'SIZE')` pattern, adapted to multiple patterns per file.

## Tier checklist

- [x] Brief references specific files and function names (`.agents/scripts/complexity-regression-helper.sh:scan_dir_bash32_compat`, `_diff_metrics`).
- [x] Acceptance criteria are verifiable via a local script invocation + new regression test.
- [ ] Target file >500 lines (847 lines) — disqualifies `tier:simple`.
- [x] Judgment required on where to plumb the aggregation through the existing diff machinery — `tier:standard`.
- Disqualifiers: target file >500 lines; requires cross-cutting changes to scan + diff + report; modest judgment on report format. **Tier: `tier:standard`**.

## PR Conventions

- Use `Resolves #<issue>` (leaf issue, not a parent task).
- Keep the PR focused on the bash32-compat metric; do not ratchet the other metrics.
