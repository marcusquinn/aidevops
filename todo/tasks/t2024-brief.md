<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# t2024: scope simplification gate on cited line ranges, not file size alone

## Origin

- **Created:** 2026-04-13
- **Session:** claude-code (interactive)
- **Created by:** ai-interactive (conversation about #18473 being blocked by the large-file gate when the actual fix was a 33-line targeted edit)
- **Parent task:** none
- **Conversation context:** While implementing the root-cause fix for broken sandboxed triage (#18473), we discovered that the issue was tagged `needs-simplification` by the pulse's large-file gate — because the issue body references `.agents/scripts/headless-runtime-helper.sh:1477` as the location where opencode is invoked with `--format json`. That reference is a **context pointer** for the human reader (it explains why the output is JSONL); it is NOT an edit target. The actual fix lives entirely in `pulse-ancillary-dispatch.sh` at lines 221–253 — a 33-line targeted change. The gate fired on the 3123-line context reference and blocked dispatch. This is a systemic flaw: the gate treats "file mentioned in body" as equivalent to "worker will rewrite this file", which conflates context with intent.

## What

Make the large-file simplification gate **scope-aware**:

1. **Parse line qualifiers** from file references in the issue body (`file.sh`, `file.sh:1477`, `file.sh:221-253`) instead of stripping them before the gate check.

2. **Single-line citations** (`file.sh:1477`) → treat as context references for the human reader. A worker does not "edit line 1477"; it edits a function or a range. Single-line references are excluded from gate evaluation entirely.

3. **Ranged citations** (`file.sh:221-253`) → if the range is at most `SCOPED_RANGE_THRESHOLD` lines (default 300), pass the gate regardless of the enclosing file's total size. The worker only needs to understand the cited range, so the complexity tax the gate is designed to prevent does not apply.

4. **File-only references** (`file.sh`) → fall through to the existing file-size check. This preserves the gate's original safety for whole-file rewrites.

5. **Add `SCOPED_RANGE_THRESHOLD` env var** next to `LARGE_FILE_LINE_THRESHOLD` in `pulse-wrapper.sh` so the threshold can be tuned without code changes.

6. **Log the pass/skip decisions explicitly** so future debugging is straightforward:
   - `Large-file gate: #N skipping file.sh:1477 (single-line citation — context reference, not edit target)`
   - `Large-file gate: #N scoped-range pass for file.sh:221-253 (33 lines, threshold 300)`
   - `Large-file gate: #N targets file.sh (3123 lines)` (existing message, when file-size check fires)

## Why

Concrete evidence from this session: issue #18473 was gated by the large-file check because its body cites several diagnostic file:line references that fall inside a 3123-line file. The ACTUAL fix is a 33-line targeted change to a completely different 615-line file. The gate is blocking work based on references the worker doesn't need to touch.

### The principle

The gate's purpose is to prevent a worker from paying the complexity tax of navigating a huge file when it only needs to change a small section. The cost being managed is **cognitive load on the worker during implementation**, not "file is mentioned anywhere in the issue body". The current extractor conflates the two.

### What was going wrong before

```text
Issue body (#18473) excerpt:
  - **Broken extractor:** `.agents/scripts/pulse-ancillary-dispatch.sh:221-253`
  - **opencode JSON invocation:** `.agents/scripts/headless-runtime-helper.sh:1477`
  - **Sandbox log line:** `.agents/scripts/sandbox-exec-helper.sh:1013`

Extractor output (before this fix):
  file_paths="headless-runtime-helper.sh
              pulse-ancillary-dispatch.sh
              sandbox-exec-helper.sh"
  (line qualifiers stripped via `sed 's/:.*//'`)

Gate result (before this fix):
  headless-runtime-helper.sh → 3123 lines → FAIL → apply needs-simplification label
```

The worker would never touch `headless-runtime-helper.sh` — the issue explicitly says "do NOT change headless-runtime-helper.sh, change the triage dispatch code instead" — but the gate can't read that distinction out of the prose. Line qualifiers make the distinction explicit: `:1477` signals "go look at this one line to understand the bug", `:221-253` signals "edit this range".

### Effect

- **#18473 becomes immediately dispatchable** without any change to the issue body — the three single-line context references are skipped, the 33-line ranged reference passes the scoped check, and the gate clears.
- **Future issues that cite diagnostic references no longer incorrectly gate** based on files they don't touch.
- **Safety preserved**: issues that really do need to rewrite a whole large file (file reference with no line qualifier) still hit the existing file-size check.
- **Encourages better issue formatting**: authors naturally learn to cite `file:start-end` for edit targets and `file:line` for context references, because the distinction now has operational meaning.

## Tier

### Tier checklist (verify before assigning)

- [x] **2 or fewer files to modify?** Yes — 2 files (`pulse-dispatch-core.sh` + `pulse-wrapper.sh` for the new env var)
- [x] **Complete code blocks for every edit?** Yes — verbatim diffs specified below
- [x] **No judgment or design decisions?** Borderline — the `SCOPED_RANGE_THRESHOLD=300` choice is a design judgement. Explained in Context & Decisions below.
- [x] **No error handling or fallback logic to design?** Yes — existing gate loop structure is preserved, only the per-target decision is augmented
- [x] **Estimate 1h or less?** Yes — ~30 minutes
- [x] **4 or fewer acceptance criteria?** Yes — 4

**Selected tier:** `tier:standard` (not `tier:simple` — the regex and range math need a thoughtful bash-3.2 compatible implementation, and the threshold choice is a judgement call rather than a pure copy-paste)

**Tier rationale:** Two-file change with well-defined scope, deterministic behaviour, and a standalone sanity test suite to exercise the parser. Sonnet-appropriate. Not Haiku because the bash regex (`=~`) with capture groups and the edge-case handling (zero-length ranges, malformed qualifiers) need careful attention that Haiku's strict copy-paste bar doesn't accommodate.

## How (Approach)

### Files to modify

- `EDIT: .agents/scripts/pulse-wrapper.sh:787` — add `SCOPED_RANGE_THRESHOLD` env var declaration next to existing `LARGE_FILE_LINE_THRESHOLD`, with explanatory comment block.
- `EDIT: .agents/scripts/pulse-dispatch-core.sh:732-795` — update `_issue_targets_large_files()` to preserve line qualifiers in extraction, parse them in the gate loop, and branch on single-line vs ranged vs no-qualifier cases.

### Implementation — verbatim diffs

Applied in this worktree. See the commit for full context.

**Change 1: `pulse-wrapper.sh`** — declare `SCOPED_RANGE_THRESHOLD` after `LARGE_FILE_LINE_THRESHOLD` with a comment block explaining the intent.

**Change 2: `pulse-dispatch-core.sh`** — two edits to `_issue_targets_large_files()`:

- Remove `sed 's/:.*//'` from both the `EDIT:`-marker extractor (line 735-736) and the backtick-path extractor (line 744-747). The line qualifier now flows through to the gate loop.
- Update the regex character class in the `EDIT:` extractor: change `[^`"[:space:],:]+` to `[^`"[:space:],]+` (remove the `:` exclusion) so the qualifier is included in the captured match.
- In the gate loop, parse the qualifier off the end of each target with `[[ "$raw_target" =~ ^(.+):([0-9]+(-[0-9]+)?)$ ]]` and store `fpath` + `line_spec` separately.
- Add two short-circuits before the `wc -l` check:
  1. Single-line `line_spec` → log "context reference", continue.
  2. Ranged `line_spec` with range size ≤ `SCOPED_RANGE_THRESHOLD` → log "scoped-range pass", continue.

### Verification

```bash
# 1. Shellcheck clean (info-level SC2016 warnings are pre-existing, not introduced)
shellcheck .agents/scripts/pulse-dispatch-core.sh .agents/scripts/pulse-wrapper.sh
# → exit 0

# 2. Characterization test still passes (26 tests — signature + sourcing)
bash .agents/scripts/tests/test-pulse-wrapper-characterization.sh
# → All 26 tests passed

# 3. Standalone gate-parser sanity test (four cases)
bash -c '... test harness ...'
# → T1 SKIP (single-line context ref)
# → T2 PASS (scoped range, 33 lines)
# → T3 FALL-THROUGH (range too large, 401 > 300)
# → T4 FALL-THROUGH (no qualifier)

# 4. Verify new env var is declared with comment
grep -n 'SCOPED_RANGE_THRESHOLD' .agents/scripts/pulse-wrapper.sh
# → one match with the env var assignment

# 5. Verify the sed strip-qualifier calls are GONE
grep -c "sed 's/:\.\*//'" .agents/scripts/pulse-dispatch-core.sh
# → 0 (was 2)
```

All verification steps pass in this worktree.

## Acceptance Criteria

- [ ] `SCOPED_RANGE_THRESHOLD` env var declared in `pulse-wrapper.sh` with default value and documentation comment
  ```yaml
  verify:
    method: codebase
    pattern: 'SCOPED_RANGE_THRESHOLD="\$\{SCOPED_RANGE_THRESHOLD:-300\}"'
    path: ".agents/scripts/pulse-wrapper.sh"
  ```
- [ ] `_issue_targets_large_files()` parses line qualifiers and short-circuits on single-line/scoped-range cases before running `wc -l`
  ```yaml
  verify:
    method: codebase
    pattern: "scoped-range pass"
    path: ".agents/scripts/pulse-dispatch-core.sh"
  ```
- [ ] Characterization test (`test-pulse-wrapper-characterization.sh`) passes 26/26
  ```yaml
  verify:
    method: bash
    run: "bash .agents/scripts/tests/test-pulse-wrapper-characterization.sh"
  ```
- [ ] `shellcheck` exits 0 on both modified files
  ```yaml
  verify:
    method: bash
    run: "shellcheck .agents/scripts/pulse-dispatch-core.sh .agents/scripts/pulse-wrapper.sh"
  ```

## Context & Decisions

- **Why `SCOPED_RANGE_THRESHOLD = 300`?** 300 lines is a comfortable upper bound on the "size of one function" across most aidevops code — covering everything from small helpers (20-50 lines) to large orchestration functions (150-250 lines), with headroom for multi-function edits within a single module. Small enough that the worker isn't paying a meaningful context tax; large enough that the threshold doesn't false-positive on legitimate targeted edits. Tunable via the env var without code changes if experience shows a different value works better.
- **Why not exempt `tier:simple` with explicit ranges?** Considered — the tier-aware approach would exempt only `tier:simple` briefs because those have verbatim code blocks. But that double-checks the same signal: if the issue body has a scoped range AND a tier:simple brief, we'd be making the same decision twice. The range itself is sufficient signal.
- **Why single-line = context ref, not edit target?** Workers don't produce patches against a single line — they produce function-scoped or range-scoped edits. A single-line reference in an issue body is always the human reader's "here's the specific line to look at". If someone genuinely wants to change one line, the brief should still cite the enclosing function's range.
- **What happens to issues already tagged `needs-simplification` wrongly?** They stay tagged until manually cleared or until `_reevaluate_simplification_labels` (t1998) re-runs the gate under the new logic — which happens automatically on the next pulse cycle after this lands. No manual cleanup needed.
- **Non-goals:** Changing the simplification-debt routine, adjusting thresholds for auto-simplification dispatch, or reworking how `needs-simplification` is displayed. Out of scope — this task only touches the gate's parsing and decision logic.

## Relevant Files

- `.agents/scripts/pulse-wrapper.sh:787` — threshold declarations (existing + new)
- `.agents/scripts/pulse-dispatch-core.sh:732-795` — `_issue_targets_large_files()` extractor and gate loop
- `.agents/scripts/tests/test-pulse-wrapper-characterization.sh:238` — function-presence test (no change needed, verifies function still declared)

## Dependencies

- **Blocked by:** none
- **Blocks:** #18473 (triage JSONL parsing fix) — currently gated by the mis-triggering large-file rule this task fixes. Landing this unblocks automatic dispatch of the triage fix without needing to implement it interactively. (In practice, the triage fix is being implemented interactively in parallel — see t2025 — but that's because session speed is more valuable than waiting for the pulse cycle.)
- **External:** none

## Estimate Breakdown

| Phase | Time | Notes |
|-------|------|-------|
| Design + parser logic | 10m | Bash regex with capture groups, scope decision tree |
| Implementation | 10m | Two Edit calls in the worktree |
| Verification | 5m | Sanity test + characterization test + shellcheck |
| Commit + PR | 5m | Conventional commit, PR body with evidence |
| **Total** | **~30m** | |
