---
mode: subagent
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->
# t2021: fix(pulse-dispatch-core): `_issue_targets_large_files` uses invalid `gh issue create --json` flag

## Origin

- **Created:** 2026-04-13
- **Session:** Claude:interactive
- **Created by:** marcusquinn (ai-interactive, discovered while unblocking #18420)
- **Parent task:** none (related follow-up to t2020 / #18483, which split `pulse-simplification.sh` below the gate)
- **Conversation context:** While investigating why #18420 (t1993) was stuck behind the large-file simplification gate, I read the gate's dispatch comment and noticed it said **"Simplification issues: none created"** instead of linking to a newly-created `simplification-debt` issue. Tracing `_issue_targets_large_files` in `pulse-dispatch-core.sh` revealed that the create block tries to capture the new issue number via `gh issue create ... --json number --jq '.number'` — but `gh issue create` **does not support the `--json` flag**. The create succeeds server-side (the issue IS created on GitHub), but the client-side capture returns empty, `_new_num` stays empty, the "created" branch is never recorded, and the dispatch comment posts the misleading "none created" message on every gated issue. This has likely been shipping silently since the function was extracted from `pulse-wrapper.sh` in t1977 / PR #18390 (2026-04-12), and may have been broken in the original wrapper before that. Confirmed via `gh issue create --help` on gh 2.58+ — the command accepts `--title`, `--body`, `--label`, etc. but no `--json`.

## What

Rewrite the "create simplification-debt issue" block inside `_issue_targets_large_files` to capture the new issue number by **parsing the URL returned on stdout** (the only output channel `gh issue create` provides), mirroring the pattern already used by `issue-sync-helper.sh:429-466` for the same task.

End-state: when a large-file-targeting issue is gated, `_issue_targets_large_files` actually creates (or finds existing) `simplification-debt` issues, captures their numbers, and posts a gate comment that links to them like:

```
**Simplification issues:** #NNNN (new), #MMMM (existing)
```

rather than the current misleading:

```
**Simplification issues:** none created
```

## Why

**The bug in four lines.** `.agents/scripts/pulse-dispatch-core.sh:828-844` calls:

```bash
_new_num=$(gh issue create --repo "$repo_slug" \
    --title "simplification-debt: ${_lf_path} exceeds ${LARGE_FILE_LINE_THRESHOLD} lines" \
    --label "simplification-debt,auto-dispatch,origin:worker" \
    --body "..." \
    --json number --jq '.number' 2>/dev/null) || _new_num=""
```

`gh issue create --help` lists no `--json` flag. The command writes the issue URL to stdout on success and exits 0. When unknown flags are passed, gh exits with an error and writes nothing to stdout that matches the `--jq` filter — so `_new_num` is always empty regardless of whether the issue was created.

**Why this is a silent failure.** The issue IS created on GitHub (the create request fires before the flag validation short-circuits result formatting). The comment block downstream (line 852) still posts its "Simplification gate" message, but with `_created_issues=""` it renders as "none created" — making it look like the gate decided not to create anything when actually it created something and then lost the reference. The next cycle's dedup check (line 819, `gh issue list ... --search "$_lf_basename"`) finds the orphaned issue, treats it as "existing", and appends `#NNNN (existing), ` — so eventually the comment does start showing issue numbers, but only by accident via the dedup-search path, not because the create path worked.

**Scope of impact.** Every issue the gate has ever triggered on — which is non-trivial given multiple active large files (`pulse-simplification.sh`, `headless-runtime-helper.sh`, prior `pulse-wrapper.sh`, etc.) hit the gate on every cycle until the file was simplified. The logs note many orphaned simplification-debt issues that were created but never referenced in a gate comment. The comment on #18420 is the live repro — you can re-read it to see the bug firsthand.

**Why it's low-severity but should still ship.** The gate still functionally holds dispatch (the `needs-simplification` label is applied via the separate `gh issue edit` call at line 804 and that works). The bug is a visibility/traceability failure: you can't click from the gated issue to the simplification-debt issue that's blocking it. And it means every gate event creates orphaned simplification-debt issues with no upstream link, cluttering the issue list.

**Why it's confined to this one call site.** I audited all `gh issue create` invocations in `.agents/scripts/` with `rg 'gh issue create.*--json' .agents/scripts/` — exactly one hit, the buggy one. All other callers (e.g., `issue-sync-helper.sh:441`, `claim-task-id.sh`, `framework-routing-helper.sh`) use the correct URL-parsing pattern. This is a localised fix, not a systemic one.

## Tier

### Tier checklist (verify before assigning)

- [x] **2 or fewer files to modify?** — yes, 1 file: `pulse-dispatch-core.sh`
- [x] **Complete code blocks for every edit?** — yes, exact before/after below
- [x] **No judgment or design decisions?** — the replacement pattern is copied from `issue-sync-helper.sh:441-464` verbatim
- [x] **No error handling or fallback logic to design?** — the existing `|| _new_num=""` branch + the `if [[ -n "$_new_num" ]]` guard are preserved
- [x] **Estimate 1h or less?** — ~30m including verification
- [x] **4 or fewer acceptance criteria?** — exactly 4

**Selected tier:** `tier:simple`

**Tier rationale:** Single-line bug, single-file edit, exact pattern to copy from a neighbouring helper. This is Haiku-dispatchable. The only judgment call is "should we also add a regression test", and the answer is below in the "Testing" section.

## How (Approach)

### Files to Modify

- `EDIT: .agents/scripts/pulse-dispatch-core.sh` — replace the buggy create block inside `_issue_targets_large_files()` (around lines 828–848) with a URL-parsing variant mirroring `issue-sync-helper.sh:441-464`.

### Reference pattern (copy this)

From `.agents/scripts/issue-sync-helper.sh:429-466`:

```bash
local -a args=("issue" "create" "--repo" "$repo" "--title" "$title" "--body" "$body" "--label" "$all_labels")
[[ -n "$assignee" ]] && args+=("--assignee" "$assignee")

# GH#15234 Fix 1: gh issue create may return empty stdout (e.g. when label
# application fails after issue creation) while still creating the issue
# server-side. Treat empty URL or non-zero exit as a soft failure and attempt
# a recovery lookup before declaring an error. Stderr is merged into the
# combined output for diagnostics without requiring a temp file.
local url gh_exit combined
{
    combined=$(gh "${args[@]}" 2>&1)
    gh_exit=$?
} || true
# Extract URL from combined output (stdout URL appears first on success)
url=$(echo "$combined" | grep -oE 'https://github\.com/[^ ]+/issues/[0-9]+' | head -1 || echo "")

# ... (recovery lookup on failure) ...

local num
num=$(echo "$url" | grep -oE '[0-9]+$' || echo "")
[[ -n "$num" ]] && _PUSH_CREATED_NUM="$num"
```

### Current (buggy) code

`.agents/scripts/pulse-dispatch-core.sh:826-848`:

```bash
            # Create the simplification-debt issue now
            local _new_num
            _new_num=$(gh issue create --repo "$repo_slug" \
                --title "simplification-debt: ${_lf_path} exceeds ${LARGE_FILE_LINE_THRESHOLD} lines" \
                --label "simplification-debt,auto-dispatch,origin:worker" \
                --body "## What
Simplify \`${_lf_path}\` — currently over ${LARGE_FILE_LINE_THRESHOLD} lines. Break into smaller, focused modules.

## Why
Issue #${issue_number} is blocked by the large-file gate. Workers dispatched against this file spend most of their context budget reading it, leaving insufficient capacity for implementation.

## How
- EDIT: \`${_lf_path}\`
- Extract cohesive function groups into separate files
- Keep a thin orchestrator in the original file that sources/imports the extracted modules
- Verify: \`wc -l ${_lf_path}\` should be below ${LARGE_FILE_LINE_THRESHOLD}

_Created by large-file simplification gate (pulse-wrapper.sh)_" \
                --json number --jq '.number' 2>/dev/null) || _new_num=""
            if [[ -n "$_new_num" ]]; then
                _created_issues="${_created_issues}#${_new_num} (new), "
                echo "[pulse-wrapper] Created simplification-debt issue #${_new_num} for ${_lf_path} (blocking #${issue_number})" >>"$LOGFILE"
            fi
```

**The bug** is on the line `--json number --jq '.number' 2>/dev/null` — those two flags do not exist on `gh issue create`. When gh sees them, it prints a usage error to stderr, exits non-zero, and writes NOTHING matching `--jq` to stdout. The `2>/dev/null` swallows the stderr error message so there's no log of what happened.

### Fixed code

Replace the block above with:

```bash
            # Create the simplification-debt issue now.
            # t2021: gh issue create does NOT support --json; capture the issue
            # number by parsing the URL it prints to stdout on success. The
            # `|| true` on the $() guards against gh non-zero exits (e.g. when
            # label application fails but the issue still creates server-side —
            # see issue-sync-helper.sh:441-464 for the same pattern + GH#15234
            # context).
            local _new_num _create_body _create_combined
            _create_body="## What
Simplify \`${_lf_path}\` — currently over ${LARGE_FILE_LINE_THRESHOLD} lines. Break into smaller, focused modules.

## Why
Issue #${issue_number} is blocked by the large-file gate. Workers dispatched against this file spend most of their context budget reading it, leaving insufficient capacity for implementation.

## How
- EDIT: \`${_lf_path}\`
- Extract cohesive function groups into separate files
- Keep a thin orchestrator in the original file that sources/imports the extracted modules
- Verify: \`wc -l ${_lf_path}\` should be below ${LARGE_FILE_LINE_THRESHOLD}

_Created by large-file simplification gate (pulse-dispatch-core.sh)_"
            _create_combined=$(gh issue create --repo "$repo_slug" \
                --title "simplification-debt: ${_lf_path} exceeds ${LARGE_FILE_LINE_THRESHOLD} lines" \
                --label "simplification-debt,auto-dispatch,origin:worker" \
                --body "$_create_body" 2>&1) || true
            _new_num=$(printf '%s' "$_create_combined" |
                grep -oE 'https://github\.com/[^ ]+/issues/[0-9]+' |
                head -1 |
                grep -oE '[0-9]+$' || true)
            if [[ -n "$_new_num" ]]; then
                _created_issues="${_created_issues}#${_new_num} (new), "
                echo "[pulse-wrapper] Created simplification-debt issue #${_new_num} for ${_lf_path} (blocking #${issue_number})" >>"$LOGFILE"
            else
                # Log the gh failure so the next cycle's operator can see why
                # the gate "created" nothing. 200-char truncation matches
                # issue-sync-helper.sh style.
                echo "[pulse-wrapper] WARN: failed to create simplification-debt issue for ${_lf_path} (blocking #${issue_number}): ${_create_combined:0:200}" >>"$LOGFILE"
            fi
```

### Implementation Steps

1. Open `.agents/scripts/pulse-dispatch-core.sh` in the worktree.
2. Find the block starting at `# Create the simplification-debt issue now` (currently around line 826). Use `rg -n '# Create the simplification-debt issue now' .agents/scripts/pulse-dispatch-core.sh` to locate it — line number may shift if other PRs land first.
3. Replace the block through the closing `fi` with the fixed version above. Keep surrounding context (the `while IFS= read -r _lf_path; do` loop and the `_existing` dedup check that comes before) unchanged.
4. Verify with shellcheck: `shellcheck .agents/scripts/pulse-dispatch-core.sh`
5. Verify with syntax check: `bash -n .agents/scripts/pulse-dispatch-core.sh`
6. Run the characterization test: `bash .agents/scripts/tests/test-pulse-wrapper-characterization.sh` — all 26 tests should pass.
7. Smoke-test the function in isolation using a stub-harness approach. Write a minimal test script that:
   - Stubs `gh` with a function that prints a realistic URL to stdout (`https://github.com/test/test/issues/999`) and exits 0 for the `create` subcommand, and returns an empty list for the `list` dedup check.
   - Stubs other externals (`gh label create`, `gh issue edit`) as no-ops.
   - Sources `pulse-dispatch-core.sh` and calls `_issue_targets_large_files` with a synthetic issue body containing `EDIT: .agents/scripts/some-large-file.sh` and a large file on disk.
   - Asserts that the function's log output contains `Created simplification-debt issue #999`.
   - See `.agents/scripts/tests/test-parent-task-guard.sh` for the stub-harness pattern.

### Testing

**No regression test is strictly required for a tier:simple fix**, but if time permits add one. The existing characterization test proves the function still exists after the edit — it doesn't exercise the create path. A focused stub test (per step 7 above) would give future-proofing.

**Decision**: add a minimal stub test file at `.agents/scripts/tests/test-large-file-gate-create.sh` with 2 assertions (success path parses URL correctly, failure path logs warning without crashing). Mark as optional — if the worker runs out of time budget, ship the fix without the test and file a follow-up.

### Verification

```bash
# Shellcheck
shellcheck .agents/scripts/pulse-dispatch-core.sh

# Syntax
bash -n .agents/scripts/pulse-dispatch-core.sh

# Characterization
bash .agents/scripts/tests/test-pulse-wrapper-characterization.sh

# The fix is in place (pattern check)
rg -n 'grep -oE .https://github.com.*issues/\[0-9\]' .agents/scripts/pulse-dispatch-core.sh
# Expect: at least one match in _issue_targets_large_files

# The bug is gone (negative check)
rg -n '--json number --jq' .agents/scripts/pulse-dispatch-core.sh
# Expect: NO matches

# Optional: new stub test passes
[[ -f .agents/scripts/tests/test-large-file-gate-create.sh ]] && \
  bash .agents/scripts/tests/test-large-file-gate-create.sh
```

## Acceptance Criteria

- [ ] `pulse-dispatch-core.sh` no longer contains the string `--json number --jq`.
  ```yaml
  verify:
    method: bash
    run: "! rg -q -- '--json number --jq' .agents/scripts/pulse-dispatch-core.sh"
  ```
- [ ] `pulse-dispatch-core.sh` captures the new issue number by parsing a GitHub URL from the `gh issue create` output.
  ```yaml
  verify:
    method: codebase
    pattern: "grep -oE 'https://github\\.com/\\[\\^ \\]\\+/issues/\\[0-9\\]\\+'"
    path: ".agents/scripts/pulse-dispatch-core.sh"
  ```
- [ ] Shellcheck clean on `pulse-dispatch-core.sh`.
  ```yaml
  verify:
    method: bash
    run: "shellcheck .agents/scripts/pulse-dispatch-core.sh"
  ```
- [ ] Characterization test passes (26 tests, 205 functions).
  ```yaml
  verify:
    method: bash
    run: "bash .agents/scripts/tests/test-pulse-wrapper-characterization.sh 2>&1 | grep -q 'All 26 tests passed'"
  ```

## Context & Decisions

**Why not just remove the `--json --jq` flags and let the create happen?** Because the function needs the new issue number to build the `_created_issues` list that drives the dispatch comment on the gated issue. Just removing the flags would create the issue but leave the comment saying "none created" forever — no improvement.

**Why not use `gh issue create -F -` with a format template?** `gh issue create` doesn't support output format flags at all. The URL-on-stdout behaviour is the only contract.

**Why copy from `issue-sync-helper.sh` rather than using a shared helper?** There is no shared `_gh_create_issue_capture_num` helper in the framework today. Extracting one is a reasonable follow-up (`shared-constants.sh` or a new `gh-create-helper.sh`) but out of scope for a tier:simple fix. Cite this in the PR body as a future enhancement.

**Why log on failure instead of silently continuing?** The current code silently drops the issue number. Adding a log line with 200-char truncation gives future operators a fighting chance at diagnosing gate-create failures without spamming on every success. The pattern matches `issue-sync-helper.sh:459`.

**What about the dedup search at line 819?** `gh issue list --repo ... --label simplification-debt --search "$_lf_basename" --json number` — this one is correct. `gh issue list` DOES support `--json`, unlike `gh issue create`. Do not touch the dedup search.

**What about the `gh label create --force`?** Also correct — `gh label create` supports `--force`. Not part of this bug.

**Non-goals:**

- Extracting a shared `_gh_create_issue_capture_num` helper (follow-up enhancement, not required here).
- Fixing any other `gh` command quirks (out of scope).
- Changing the body content of the simplification-debt issue (cosmetic, keep verbatim).
- Backfilling previously-created orphaned simplification-debt issues with upstream-gate comments (historical cleanup, separate task if desired).

## Relevant Files

- `.agents/scripts/pulse-dispatch-core.sh:657-879` — `_issue_targets_large_files` function body.
- `.agents/scripts/pulse-dispatch-core.sh:828-848` — the buggy `gh issue create --json` block (edit target).
- `.agents/scripts/issue-sync-helper.sh:429-466` — correct URL-parsing pattern (reference copy).
- `.agents/scripts/claim-task-id.sh` — another correct pattern (parses URL from `gh issue create` output).
- `.agents/scripts/tests/test-pulse-wrapper-characterization.sh` — existing test that must still pass.
- `.agents/scripts/tests/test-parent-task-guard.sh` — stub-harness pattern reference for the optional regression test.
- GH#18420 — live repro: the gate comment on this issue shows "Simplification issues: none created" despite the gate having fired.
- PR #18483 — related t2020 split that unblocked #18420 (do not conflict with this PR's edit target, different function).

## Dependencies

- **Blocked by:** none
- **Blocks:** nothing directly — this is a visibility/traceability fix. But shipping it improves every future large-file gate event's discoverability.
- **External:** `gh` CLI 2.x+ (already required framework-wide)

## Estimate Breakdown

| Phase | Time | Notes |
|-------|------|-------|
| Read target function + reference pattern | 5m | Both files already identified in this brief |
| Apply the edit | 10m | Mechanical replace of one block |
| Shellcheck + bash -n + characterization | 5m | Automated |
| Optional: write stub test | 15m | If time permits |
| Commit + PR | 5m | |
| **Total** | **~30-40m** | |
