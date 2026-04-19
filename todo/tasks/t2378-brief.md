# t2378: refactor markdownlint-diff-helper.sh to eliminate repeated variable expansions

## Session origin

Follow-up to t2376 (PR #19848, merged 2026-04-19). While committing the grep -c arithmetic fix, the `validate_string_literals` pre-commit check flagged 10 groups of repeated variable expansions as "repeated string literals". These are variable references, not literals — the validator is buggy. Rather than fix the validator (separate concern), the user opted to refactor the file to eliminate the repetition so the validator stops complaining. The validator bug itself is worth a separate task (see "Out of scope" below).

## What

Refactor `.agents/scripts/markdownlint-diff-helper.sh` to eliminate the highly-repeated variable expansions that currently trigger `validate_string_literals`:

| Variable | Current usage count |
|---|---|
| `"$_base"` | 12 |
| `"$_head"` | 9 |
| `"$_output_md"` | 8 |
| `"$_delta"` | 6 |
| `"$_changed_files"` | (est. 4-6) |
| `"$_line"` | (est. 3-5) |
| `"$_new_count"` | (est. 3-5) |
| `"$_ranges"` | (est. 3-5) |
| `"$_total_count"` | (est. 3-5) |
| `"$_out"` | (est. 3-5) |

Total: 60+ usages across 10 variables.

## Why

1. **Unblock pre-commit hook on future edits**: Any future edit to this file (bug fix, enhancement, refactor) will re-trigger the 10 validator warnings, forcing `--no-verify` bypasses or out-of-scope refactors. t2376 already had to bypass the hook. Every subsequent edit will face the same friction.
2. **Reduce cognitive load**: 12 copies of `"$_base"` at different sites obscure the data flow. Passing to a function or reducing scope via local intermediate vars improves readability.
3. **Validator compliance**: The repeated-string-literal check is meant to catch hard-coded strings that should be constants. Even though it's false-positive here (these are variable refs, not string literals), the refactor is directionally correct — fewer repeated expansions = clearer code regardless of validator opinion.

## How

### Target file

`.agents/scripts/markdownlint-diff-helper.sh` (full file, 500+ lines)

### Approach (refactor strategies)

For each high-repetition variable, pick the right strategy based on usage pattern:

**Strategy A — Function parameter passthrough**: If a variable is only used within a contiguous block that already has structure, lift that block into a helper function. The function receives the variable as `$1` and references it once internally. Caller has ONE reference to pass in. Good for: `"$_base"` and `"$_head"` which drive the whole scan/compare flow.

**Strategy B — Consolidate adjacent operations**: If variables are used in back-to-back commands, combine into a single expression or heredoc. Good for: `"$_output_md"` which likely drives a markdown report writer.

**Strategy C — Template string / here-doc**: If repetition is in string building (e.g., building lines of markdown), use a heredoc with variable interpolation — reduces N references to 1.

**Strategy D — Accept the repetition**: For variables used legitimately across independent branches (e.g., error reporting in multiple error paths), no refactor fixes this cleanly. Add a validator exception marker if supported, or leave alone. Low priority.

### Concrete steps

1. Read `markdownlint-diff-helper.sh` fully to understand the data flow.
2. For each of the 10 flagged variables, categorise usage into A/B/C/D strategies.
3. Apply refactors one variable at a time, running shellcheck and the script's own self-test between each.
4. After each refactor, verify the 5 test paths still work:
   - `check-files-all` (list of markdown files changed in PR)
   - `check-files-changed-only` (filter to diff-only)
   - `compare-base-head` (full compare)
   - `output-md` (markdown report mode)
   - `output-json` (json mode, if exists)
5. Final verification: run `pre-commit-hook.sh` and confirm zero `validate_string_literals` warnings for this file.

### Reference pattern

- Related lifting pattern in `pulse-dispatch-core.sh:700-800` where per-candidate state is passed through a helper function rather than referenced repeatedly at the caller site.
- Heredoc template pattern in `gh-signature-helper.sh` `footer()` function — shows clean interpolation-based string building.

## Acceptance criteria

- [ ] `pre-commit-hook.sh` reports 0 `validate_string_literals` warnings for `.agents/scripts/markdownlint-diff-helper.sh` (currently flags 10 groups).
- [ ] All 5 test paths above still produce identical output on a fixed-input reproducer (before/after diff is zero).
- [ ] `shellcheck .agents/scripts/markdownlint-diff-helper.sh` passes with zero new violations.
- [ ] File can be edited and committed without `--no-verify` bypass.
- [ ] No behaviour change — this is a pure refactor. If any behavioural difference is discovered during refactor, revert and file separately.

## Context

- t2376 (PR #19848, merged 2026-04-19) fixed the grep -c arithmetic crash in this same file. That fix used `--no-verify` with maintainer authorization due to these same false-positive warnings.
- The pre-commit hook `validate_string_literals` check considers `"$var"` expansions as repeated string literals. This is likely a regex bug — the check should exclude patterns starting with `"$` or `${`. Filing a separate framework issue to fix the validator is sensible but out of scope here.

## Out of scope

- **Fixing the `validate_string_literals` validator itself.** That's a framework-level change to `.agents/scripts/pre-commit-hook.sh`. If the user wants that fix, it should be its own task (separate PR, separate verification). This task treats the validator as a constraint and refactors to satisfy it.
- **Other unrelated cleanups in `markdownlint-diff-helper.sh`.** Keep this refactor surgical — only eliminate the 10 flagged var repetitions. Other lint suggestions should be separate tasks.

## Dispatchability

- Tier: `tier:standard` (requires reading 500+ line file, understanding data flow, applying 10 separate refactor decisions). Not simple enough for haiku — judgment required on strategy A vs B vs C vs D per variable. Not complex enough for thinking — each refactor is mechanical once the strategy is picked.
- Auto-dispatch: yes (brief is self-contained, test strategy is concrete).
- Estimated effort: 2-3h for a worker.
