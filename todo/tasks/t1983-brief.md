<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->
# t1983: P0 — BSD awk dynamic-regex bug silently breaks `add_gh_ref_to_todo` on macOS

## Origin

- **Created:** 2026-04-12
- **Session:** claude-code:interactive (discovered while filing t1979-t1981)
- **Created by:** ai-interactive
- **Parent task:** none
- **Conversation context:** After filing three session-level finding tasks (t1979-t1981) via `issue-sync-helper.sh push`, I noticed that `ref:GH#NNN` was never stamped back into `TODO.md` for t1980 and t1981. Investigation revealed the root cause: `add_gh_ref_to_todo` in `issue-sync-lib.sh` uses `awk -v pat="..." '$0 ~ pat {...}'` with a regex containing `\[` and `\]` escape sequences. **BSD awk (macOS default at `/usr/bin/awk`) interprets those differently from gawk in the dynamic-regex path.** The result: `$0 ~ pat` never matches, the function logs "not found outside code fences" at verbose level, returns 0, and the caller thinks the writeback succeeded. Every Mac running `issue-sync-helper.sh push` locally has been silently failing writebacks.

## What

Fix the dynamic-regex pattern construction in `issue-sync-lib.sh` so the same `$0 ~ pat` match works on both BSD awk (macOS) and gawk (Linux CI runners). The simplest working fix is **double-backslash escaping**: pass `\\[` instead of `\[` in the bash-constructed pattern string, so awk receives `\\[` as two characters, compiles it to `\[`, and matches a literal `[`. Verified working in isolation (see Reproduction below).

Apply the fix to every `awk -v pat=` site in `issue-sync-lib.sh` (there are multiple — grep first to enumerate). Audit other `_lib.sh` / `_helper.sh` files for the same pattern (this bug class is likely to recur).

## Why

**P0 because:**

- Silent failure (no error, returns 0, function caller assumes success)
- Every macOS developer/operator running `issue-sync-helper.sh push` locally is affected
- Side effect: TODO.md entries lack `ref:GH#NNN` after issue creation, which breaks downstream traceability, dedup, task-complete-helper, and pulse dispatch
- Linux CI runners work correctly because gawk has different dynamic-regex semantics — so CI tests would miss this unless explicitly run with `mawk`/`busybox awk`/BSD awk
- **Evidence from this session:** I pushed three new tasks (t1979-t1981) expecting `ref:GH#` to be stamped. The server-side `Sync TODO.md → GitHub Issues` workflow created the GitHub issues correctly (it runs on Ubuntu/gawk). My local `issue-sync-helper.sh push` then detected them via dedup and called `add_gh_ref_to_todo` — which silently did nothing. I had to manually backfill three refs.

This isn't a hypothetical edge case. It's the **default path** on every Mac.

## Reproduction

Minimal isolated reproduction (runs on any macOS with BSD awk at `/usr/bin/awk`):

```bash
TMP=$(mktemp -d)
printf -- '- [ ] t1980 line\n' > "$TMP/TODO.md"

echo "--- single backslash (BROKEN on BSD awk) ---"
awk -v pat='^[[:space:]]*- \[.\] t1980 ' '$0 ~ pat {print "MATCH "NR}' "$TMP/TODO.md"
# Expected: MATCH 1
# Actual:   (empty — no match)

echo "--- double backslash (WORKS on BSD awk) ---"
awk -v pat='^[[:space:]]*- \\[.\\] t1980 ' '$0 ~ pat {print "MATCH "NR}' "$TMP/TODO.md"
# Expected: MATCH 1
# Actual:   MATCH 1

echo "--- inline regex literal (WORKS — control) ---"
awk '/^[[:space:]]*- \[.\] t1980 / {print "MATCH "NR}' "$TMP/TODO.md"
# Expected: MATCH 1
# Actual:   MATCH 1

rm -rf "$TMP"
```

The bug is visible in the contrast between lines 1 and 2: same intent, different regex escape count, only the double-backslash form works through `-v pat=`.

## Tier

### Tier checklist

- [x] **2 or fewer files to modify?** — likely 1 (`issue-sync-lib.sh`), possibly 2 if the audit finds sibling helpers with the same pattern
- [x] **Complete code blocks for every edit?** — yes, the fix is a mechanical escape-doubling
- [x] **No judgment or design decisions?** — no, the fix is empirically verified
- [x] **No error handling or fallback logic to design?** — no
- [x] **Estimate 1h or less?** — yes, ~30m including the audit
- [x] **4 or fewer acceptance criteria?** — 4

**Selected tier:** `tier:simple`

## How (Approach)

### Files to Modify

- `EDIT: .agents/scripts/issue-sync-lib.sh:1169-1170` — primary fix site
- `AUDIT:` all other `awk -v pat=` invocations in `.agents/scripts/*.sh` that use `\[` or `\]` or similar escape sequences — apply the same fix where found

### Implementation Steps

1. Find all sites that need fixing:

    ```bash
    rg -n 'awk -v pat=' .agents/scripts/ | grep -E '\\\\\[|\\\\\]|\\\\\.|\\\\\*'
    ```

2. For each match, change the bash pattern string so backslash escapes are doubled. The canonical fix for the t1983 primary site:

    ```bash
    # Before (line 1169):
    line_num=$(awk -v pat="^[[:space:]]*- \\[.\\] ${task_id_ere} " \
        '/^[[:space:]]*```/{f=!f; next} !f && $0 ~ pat {print NR; exit}' "$todo_file")
    
    # After — double the backslashes so awk's dynamic-regex compiler sees them correctly:
    line_num=$(awk -v pat="^[[:space:]]*- \\\\[.\\\\] ${task_id_ere} " \
        '/^[[:space:]]*```/{f=!f; next} !f && $0 ~ pat {print NR; exit}' "$todo_file")
    ```

   Note: inside a bash double-quoted string, `\\\\` → `\\` (two chars) → awk receives `\\[` → compiles to `\[` → matches literal `[`.

3. Also audit `add_gh_ref_to_todo`'s three earlier `grep -qE` calls at lines 1156, 1161, 1167, 1214, 1220 — these use `grep -qE` not awk, so they're likely unaffected, but verify each passes on BSD grep too.

4. Add a regression test to `test-privacy-guard.sh` style harness — see t1985 for the broader harness extension, but for this P0 fix, add at least one inline assertion to the fix PR:

    ```bash
    # In a new .agents/scripts/test-issue-sync-lib.sh, or inline in the PR verification block:
    TMP=$(mktemp -d)
    printf -- '- [ ] t9999 dummy\n' > "$TMP/TODO.md"
    source .agents/scripts/issue-sync-lib.sh
    add_gh_ref_to_todo "t9999" "12345" "$TMP/TODO.md"
    grep -q 'ref:GH#12345' "$TMP/TODO.md" || { echo "FAIL: ref not stamped"; exit 1; }
    echo "PASS"
    rm -rf "$TMP"
    ```

5. Run the test on macOS AND Linux (either via CI matrix or local `docker run`) to confirm both paths now work.

### Verification

```bash
shellcheck .agents/scripts/issue-sync-lib.sh

# Regression test — must pass on BSD awk (macOS default)
bash .agents/scripts/test-issue-sync-lib.sh   # or inline harness

# Integration: push a new task via issue-sync-helper.sh on macOS
# and verify ref:GH# is stamped in TODO.md
```

## Acceptance Criteria

- [ ] `add_gh_ref_to_todo` correctly stamps `ref:GH#NNN` into a task line on both BSD awk (macOS) and gawk (Linux). Regression test asserts this.
- [ ] All other `awk -v pat=` sites in `.agents/scripts/` that use backslash escapes are audited; any affected sites are fixed with the same double-backslash pattern.
- [ ] A new test in `.agents/scripts/test-issue-sync-lib.sh` (or equivalent) exists and runs as part of the framework's test suite. The test must fail on a pre-fix `issue-sync-lib.sh` and pass on the post-fix version.
- [ ] shellcheck clean.

## Context & Decisions

- **Why double-backslash instead of alternative fixes (e.g., char classes like `[[]` or `[.]`):** tested both; char classes (`[[]`, `[.]`, `[]]`) fail on BSD awk with the same dynamic-regex bug, while double-backslash works consistently. Empirical, not principled.
- **Why fix at the pattern construction site instead of normalising `awk` invocation:** forcing `/usr/bin/env gawk` would require installing gawk on every Mac (added setup burden, extra dep). The double-backslash fix is a no-op on gawk (still compiles to `\[`) and free on BSD awk. No dep changes.
- **Why file as separate task from t1985 (harness extension):** this is a P0 functional bug that should ship NOW. t1985 is the meta-fix (prevent this class of bug via better test coverage). Different timelines, different priorities.
- **Why not yak-shave into a full `awk` portability audit:** scope creep. Fix the known broken site, audit adjacent sites in the same file, file a follow-up if more shows up.

## Relevant Files

- `.agents/scripts/issue-sync-lib.sh:1169-1170` — primary `add_gh_ref_to_todo` fix site
- `.agents/scripts/issue-sync-lib.sh:1125-1140` — sibling `fix_gh_ref_in_todo` (same awk pattern, same bug)
- `.agents/scripts/issue-sync-lib.sh:1214-1228` — sibling `add_pr_ref_to_todo` (same awk pattern, likely same bug)
- Linux CI path: `.github/workflows/issue-sync.yml` runs on ubuntu-latest (gawk) — so CI has never seen this failure

## Dependencies

- **Blocked by:** none
- **Blocks:** t1985 (harness extension) is cleaner to write once this is fixed
- **External:** none

## Estimate Breakdown

| Phase | Time | Notes |
|-------|------|-------|
| Audit | 5m | grep for `awk -v pat=` |
| Fix | 10m | mechanical escape-doubling at identified sites |
| Test | 10m | new regression test + run on macOS |
| PR | 5m | |

**Total estimate:** ~30m
