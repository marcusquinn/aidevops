<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->
# t1985: test — extend stub-harness pattern from t1969 to issue-sync-lib.sh

## Origin

- **Created:** 2026-04-12
- **Session:** claude-code:interactive (follow-up from t1983)
- **Created by:** ai-interactive
- **Parent task:** t1969 (merged via PR #18375) — established the stub-based test harness pattern for privacy-guard. t1985 applies the same pattern to the next high-leverage file: `issue-sync-lib.sh`.
- **Conversation context:** While filing t1983 (P0 BSD awk bug in `add_gh_ref_to_todo`), I confirmed that `issue-sync-lib.sh` has zero test coverage. The BSD awk bug had been shipping silently — it would have been caught on day one if the stub-harness pattern from t1969 had been extended to this file. This task makes that extension.

## What

Create `.agents/scripts/test-issue-sync-lib.sh` as a stub-based test harness for `issue-sync-lib.sh`, following the pattern established in `test-privacy-guard.sh`. Initial test surface:

1. **`add_gh_ref_to_todo`:** stamps `ref:GH#NNN` into a fresh TODO.md, is idempotent on re-runs, handles both plain and backtick-containing task descriptions, correctly skips code-fenced example entries
2. **`fix_gh_ref_in_todo`:** updates an existing wrong ref to the correct one, is idempotent
3. **`add_pr_ref_to_todo`:** stamps `pr:#NNN` into a task line, is idempotent
4. **`strip_code_fences`:** correctly strips lines inside triple-backtick blocks, leaves non-fenced lines untouched
5. **`_escape_ere`:** escapes regex metacharacters that appear in real task IDs (e.g. `t001.1` for sub-tasks)
6. **`parse_task_line`:** extracts description, tags, assignee, and ref fields from canonical task lines
7. **`gh_find_issue_by_title` (stubbed):** can be overridden to return a pre-seeded result for dedup tests

No network calls. No `gh` CLI dependency. Stubs fill the gaps where the library reaches out to `gh`.

## Why

The t1983 investigation confirmed that the test-coverage gap on `issue-sync-lib.sh` allowed a P0 bug (BSD awk dynamic-regex) to ship silently and affect every macOS operator. The library is the second-most-critical shell module in the framework (after `pulse-wrapper.sh`) — it handles every TODO.md ↔ issue sync, every `claim-task-id.sh` issue creation, and every task-ID-to-issue-number writeback. A bug in this file doesn't get caught by end-to-end tests easily because its failures are silent (the issue gets created, but the ref doesn't get written back — a symptom that surfaces only later, in a different tool).

The t1969 harness pattern has already proven its value: it caught a latent jq null-ish gotcha in `privacy-guard-helper.sh` on the very first run. Extending the same pattern to `issue-sync-lib.sh` is the smallest intervention with the highest expected regression-prevention value.

## Tier

### Tier checklist

- [x] **2 or fewer files to modify?** — 1 new file (`.agents/scripts/test-issue-sync-lib.sh`)
- [ ] **Complete code blocks for every edit?** — test skeletons provided, but each test requires concrete assertion logic
- [ ] **No judgment or design decisions?** — minor: which functions to cover first, whether to stub `gh` calls via function overrides or environment variables
- [x] **No error handling or fallback logic to design?** — no
- [ ] **Estimate 1h or less?** — 1.5–2h including 7 function coverage
- [ ] **4 or fewer acceptance criteria?** — 7 functions covered

**Selected tier:** `tier:standard`

**Tier rationale:** Single-file new test harness following an established pattern, but the surface area is 7 functions and requires thoughtful stub design. Not simple because of scope; not reasoning-tier because the pattern is fixed.

## How (Approach)

### Files to Create

- `NEW: .agents/scripts/test-issue-sync-lib.sh` — model structurally on `.agents/scripts/test-privacy-guard.sh`

### Implementation Steps

1. Read `test-privacy-guard.sh` to re-establish the pattern:
   - Shebang + set -u (not -e — we want to run failing tests without aborting)
   - Colour helpers, `pass()`/`fail()` counters
   - Mktemp scratch dir with trap cleanup
   - Source the library under test
   - Per-function test blocks that assert observable state (not exit codes alone)
   - Summary counter at the end

2. Build the harness skeleton with test fixtures:

    ```bash
    #!/usr/bin/env bash
    set -u
    
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    LIB="${SCRIPT_DIR}/issue-sync-lib.sh"
    
    TMP=$(mktemp -d)
    trap 'rm -rf "$TMP"' EXIT
    
    # Stub out functions that call gh before sourcing the lib
    gh() { echo "STUB gh called with: $*" >&2; return 0; }
    export -f gh
    
    # shellcheck source=issue-sync-lib.sh
    source "$LIB"
    ```

3. Write tests for each target function. Example for `add_gh_ref_to_todo`:

    ```bash
    # Test: stamps ref into plain task line
    cat > "$TMP/todo1.md" <<'EOF'
    ## Ready
    - [ ] t9001 plain description tier:simple
    EOF
    add_gh_ref_to_todo "t9001" "1001" "$TMP/todo1.md"
    grep -q '^\- \[ \] t9001.*ref:GH#1001' "$TMP/todo1.md" \
        && pass "add_gh_ref_to_todo: plain line stamped" \
        || fail "add_gh_ref_to_todo: plain line NOT stamped"
    
    # Test: stamps ref into line with inline backticks (regression for t1983)
    cat > "$TMP/todo2.md" <<'EOF'
    ## Ready
    - [ ] t9002 desc with `inline code` and `more backticks` tier:simple
    EOF
    add_gh_ref_to_todo "t9002" "1002" "$TMP/todo2.md"
    grep -q 'ref:GH#1002' "$TMP/todo2.md" \
        && pass "add_gh_ref_to_todo: backticks line stamped" \
        || fail "add_gh_ref_to_todo: backticks line NOT stamped"
    
    # Test: idempotent — second call is a no-op
    add_gh_ref_to_todo "t9001" "1001" "$TMP/todo1.md"
    count=$(grep -c 'ref:GH#1001' "$TMP/todo1.md")
    [[ "$count" -eq 1 ]] \
        && pass "add_gh_ref_to_todo: idempotent on re-run" \
        || fail "add_gh_ref_to_todo: duplicated ref on re-run (count=$count)"
    
    # Test: skips code-fenced example entries
    cat > "$TMP/todo3.md" <<'EOF'
    ## Format
    ```markdown
    - [ ] t9003 example in code fence
    ```
    ## Ready
    - [ ] t9003 real task outside fence
    EOF
    add_gh_ref_to_todo "t9003" "1003" "$TMP/todo3.md"
    # Assert: the code-fenced example line is UNCHANGED, real line got the ref
    awk '/^```/{f=!f; next} !f && /t9003.*ref:GH#1003/ {found=1} END{exit !found}' "$TMP/todo3.md" \
        && pass "add_gh_ref_to_todo: stamps real line, skips fenced example" \
        || fail "add_gh_ref_to_todo: fenced-line handling broken"
    ```

4. Add tests for the other six functions following the same pattern.

5. Run the harness and ensure all assertions pass:

    ```bash
    shellcheck .agents/scripts/test-issue-sync-lib.sh
    bash .agents/scripts/test-issue-sync-lib.sh
    ```

6. Wire the harness into CI if there's an existing test-runner pattern. Check `.github/workflows/` for test harness invocation.

### Verification

```bash
shellcheck .agents/scripts/test-issue-sync-lib.sh
bash .agents/scripts/test-issue-sync-lib.sh
# Must pass on macOS (BSD awk) AND Linux (gawk) — this is the point
```

## Acceptance Criteria

- [ ] `.agents/scripts/test-issue-sync-lib.sh` exists, is executable, and runs standalone with no network/gh dependency.
- [ ] Minimum 10 tests covering `add_gh_ref_to_todo`, `fix_gh_ref_in_todo`, `add_pr_ref_to_todo`, `strip_code_fences`, `_escape_ere`, and `parse_task_line` (at least one happy path + one edge case per function).
- [ ] At least one regression test that fails against the pre-t1983 `issue-sync-lib.sh` (the BSD awk bug) and passes against the post-t1983 version — i.e. the bug would have been caught by this harness.
- [ ] Test harness runs green on both macOS and Linux CI.
- [ ] `shellcheck` clean.

## Context & Decisions

- **Why extend t1969's pattern rather than adopt a shell testing framework (bats, shunit2):** aidevops has a strong preference for minimal deps. The t1969 pattern is ~200 lines of plain bash with clear pass/fail output and zero runtime dependencies. Bats would add a dep and a learning curve for contributors. The bar is "tests exist and run on every push", and plain bash meets it.
- **Why stub `gh` as a no-op function vs setting `PATH` to a stub dir:** function override is cleaner, lives in the test file, and doesn't affect sibling tests. The t1969 harness uses env vars (`PRIVACY_REPOS_CONFIG`, `PRIVACY_CACHE_FILE`) for stubs rather than function overrides — issue-sync-lib has more `gh` touchpoints so function override is more tractable.
- **Why not also test `_gh_create_issue` / `_push_process_task` / full `push` flow:** those require either a full `gh` stub with state or live API calls. Out of scope for the initial harness. File as t1985-followup if coverage is needed later.
- **Why tier:standard instead of tier:simple:** 7 functions × ~3 tests each = ~20 tests, plus stub infrastructure. Over the 4-criteria and 1h disqualifiers for tier:simple.

## Relevant Files

- `.agents/scripts/test-privacy-guard.sh` — the pattern to follow
- `.agents/scripts/issue-sync-lib.sh` — the file under test
- t1983's fix (once merged) — this harness should include a regression test for it

## Dependencies

- **Blocked by:** ideally t1983 merges first so the regression test can assert pre-fix-fails / post-fix-passes without hacky git checkout
- **Blocks:** none
- **External:** none

## Estimate Breakdown

| Phase | Time | Notes |
|-------|------|-------|
| Harness scaffolding | 20m | mktemp, stubs, pass/fail, source |
| Per-function tests | 60m | 7 functions, happy + edge cases each |
| CI integration | 15m | find and wire into existing test workflow |
| Regression test for t1983 | 10m | explicit BSD awk bug repro |
| PR | 15m | |

**Total estimate:** ~2h
