<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# t2025: fix sandboxed triage JSONL parsing — opencode --format json output parsed as plain text

## Origin

- **Created:** 2026-04-13
- **Session:** claude-code (interactive)
- **Created by:** ai-interactive (implementation of #18473 root cause)
- **Parent task:** none (resolves #18473)
- **Conversation context:** The session that produced #18471 (`TRIAGE_MAX_RETRIES` 3→1) and the investigation that produced #18473 identified that sandboxed triage reviews have been 100% broken since opencode adopted `--format json` as the default invocation mode. The last successful triage review in the pulse log was #17490, ~106K log lines ago. Every triage attempt since then has been suppressed by the safety filter, either as "raw sandbox output" or "no review header", because the dispatch code parses a JSONL transcript as plain text and fails to find the `## Review:` header at column 0.

## What

Fix `_dispatch_triage_review_worker()` in `pulse-ancillary-dispatch.sh` so that sandboxed triage reviews actually post instead of being silently suppressed:

1. **Separate stderr from stdout** when capturing the opencode output. Replace `>"$review_output_file" 2>&1` with `>"$review_output_file" 2>"${review_output_file}.stderr"`. This eliminates the "raw sandbox output" class of failures — sandbox INFO lines (`[INFO] Executing (timeout=…, network_blocked=…)` from `sandbox-exec-helper.sh:1013`) no longer contaminate the review capture.

2. **Parse the JSONL transcript via jq** before running the plain-text safety filter. `opencode run … --format json` emits a JSONL stream where each line is a JSON object (`user`, `tool_use`, `tool_result`, `assistant` types). The review text lives in the last `assistant` message's `.message.content` field, which may be either a string or an array of content blocks. Extract it before passing to the existing `^## .*[Rr]eview` extractor.

3. **Preserve backwards compatibility** — if the file isn't valid JSONL (e.g., opencode crashed before emitting anything structured, or the output format changes in a future release), fall through to reading the raw file as plain text — same behaviour as before this fix. No regression for non-JSONL captures.

4. **Save failed captures to a debug directory** for future regression debugging. When triage fails, copy the raw JSONL + a metadata sidecar to `~/.aidevops/.agent-workspace/tmp/triage-debug/`. Capped at 100 files (drop oldest to make room) so it can't run away. This prevents the next regression from being as invisible as this one.

## Why

### Evidence

From `~/.aidevops/logs/pulse.log` — every triage attempt in recent memory has failed:

```text
127509: SECURITY: triage review for #18383 was raw sandbox output — suppressed (51480 chars)
129401: SECURITY: triage review for #18429 was raw sandbox output — suppressed (57540 chars)
129407: Triage review for #18428 had no review header — suppressed (72233 chars)
129467: SECURITY: triage review for #18429 was raw sandbox output — suppressed (51900 chars)
129473: Triage review for #18428 had no review header — suppressed (80568 chars)
129595: Triage review for #18439 had no review header — suppressed (123252 chars)
129601: Triage review for #18429 had no review header — suppressed (78381 chars)
129675: Triage review for #18439 had no review header — suppressed  (97887 chars)
129681: SECURITY: triage review for #18428 was raw sandbox output — suppressed (62198 chars)
129792: Triage review for #18439 had no review header — suppressed (157690 chars)
```

Last successful triage: `22991: Posted sandboxed triage review for #17490` — approximately 106,000 log lines ago.

### Root cause (two collaborating bugs in one dispatch path)

1. **`headless-runtime-helper.sh:1477`** invokes `opencode run … --format json`. Every caller now gets JSONL back: one JSON object per line covering the user prompt, every tool_use event, every tool_result (which for Read tools serializes the full file contents), and assistant messages. For a triage agent with `read/glob/grep` access to the repo, a single run produces 50–160 KB of JSONL.

2. **`pulse-ancillary-dispatch.sh:221-253`** captures that output with `>"$review_output_file" 2>&1` and then runs `sed -n '/^## .*[Rr]eview/,$ p'` against it as if it were plain text. Two failure modes:

   - **"raw sandbox output"** — the `2>&1` merges sandbox stderr lines (`[INFO] Executing (timeout=…, network_blocked=…)` from `sandbox-exec-helper.sh:1013`) into the capture. These match the infrastructure-marker regex and trigger the SECURITY suppression branch.
   - **"no review header"** — even when no infra markers are present, the `## Review:` header lives inside an escaped JSON string (`{"type":"assistant","message":{"content":[{"type":"text","text":"## Review: Approved\\n..."}]}}`) and never starts a line. `^##` can't match, and `sed` returns empty.

Both failure classes in the log come from the same root cause, just different branches of the safety filter.

### Why this wasn't noticed earlier

`TRIAGE_MAX_RETRIES=3` (now cut to 1 in #18471) capped the observable symptom after 3 failures per content version, and the `triage-failed` label is easy to miss unless you're watching logs. The cap and the label together hid the complete breakage behind "retry timeout" dressing.

### Effect

- Restores sandboxed triage reviews from "100% broken" to "working"
- Eliminates the per-failing-issue waste of running opus agents that always get suppressed
- Unblocks the genuine review-gating workflow for external contributor issues
- Combined with #18471 (cuts retries 3→1) and t2024 (scope-aware gate), closes the loop on the session's original "wasted cycles on gated issues" investigation

## Tier

### Tier checklist (verify before assigning)

- [x] **2 or fewer files to modify?** Yes — 1 file (`pulse-ancillary-dispatch.sh`)
- [x] **Complete code blocks for every edit?** Yes — verbatim specified below
- [x] **No judgment or design decisions?** Borderline — the JSONL schema discovery and the debug-dir design are judgement calls. Documented in Context & Decisions.
- [x] **No error handling or fallback logic to design?** Borderline — explicit fallback path for non-JSONL captures and the debug-dir cap. Both are simple, but they exist.
- [x] **Estimate 1h or less?** Yes — ~30 minutes
- [x] **4 or fewer acceptance criteria?** Yes — 4

**Selected tier:** `tier:standard` (Sonnet). Not `tier:simple` because:
- The jq expression needs to handle both `content` as array-of-blocks and `content` as string, plus fall-through to raw-file read when jq returns empty.
- The debug-dir capping logic needs careful ordering (check count → drop oldest → save new).
- The stderr separation has a subtle interaction with the existing infra-markers check (we still check for them on the parsed `review_text`, but the common case — sandbox log leakage — is now prevented at source).

## How (Approach)

### Files to modify

- `EDIT: .agents/scripts/pulse-ancillary-dispatch.sh:290-400` — update `_dispatch_triage_review_worker()` with three insertions (stderr separation, JSONL parsing, debug-capture on failure).

### Implementation — three changes inside `_dispatch_triage_review_worker()`

**Change 1: Separate stderr from stdout capture.**

Replace:

```bash
	"$HEADLESS_RUNTIME_HELPER" run \
		--role worker \
		...
		--prompt-file "$prefetch_file" </dev/null >"$review_output_file" 2>&1
```

With:

```bash
	# t2025: Capture stderr to a separate file so sandbox INFO lines
	# (written to stderr by sandbox-exec-helper.sh's log_sandbox) don't
	# contaminate the stdout review capture.
	local review_stderr_file=""
	review_stderr_file="${review_output_file}.stderr"
	...
	"$HEADLESS_RUNTIME_HELPER" run \
		--role worker \
		...
		--prompt-file "$prefetch_file" </dev/null >"$review_output_file" 2>"$review_stderr_file"
```

**Change 2: Parse JSONL via jq before the safety filter.**

Replace:

```bash
	rm -f "$prefetch_file"

	# ── Post-process: post the review comment (deterministic) ──
	local review_text=""
	review_text=$(cat "$review_output_file")
	rm -f "$review_output_file"
```

With a jq-based parser (full text in the commit) that:

1. Reads the JSONL via `jq -rs` (slurp mode)
2. Filters to `.type == "assistant"` entries
3. Takes the last one
4. Extracts `.message.content` (or falls back to `.content`)
5. If the content is an array, joins the `type == "text"` block texts
6. If the content is a string, uses it directly
7. Falls back to raw `cat` if jq returns empty (non-JSONL edge case)
8. Keeps `$review_output_file` around (no `rm`) so the debug-capture below can copy it

**Change 3: Save raw capture on failure (new block before `unlock_issue_after_worker`).**

Add a block that:

1. Fires only when `triage_posted != "true"` and the raw file is non-empty
2. Creates `$TRIAGE_DEBUG_DIR` (default `~/.aidevops/.agent-workspace/tmp/triage-debug`)
3. Counts existing `.jsonl` files; if ≥ 100, drops the oldest to make room
4. Copies `$_triage_raw_capture` to `${slug}-${issue}-${epoch}.jsonl`
5. Writes a sidecar `.meta` file with reason, timestamp, slug, issue number, char count, stderr presence
6. Logs the save location
7. Follows with `rm -f "$review_output_file" "$review_stderr_file"` to clean up the live files

### Verification

```bash
# 1. Shellcheck clean
shellcheck .agents/scripts/pulse-ancillary-dispatch.sh
# → exit 0

# 2. Characterization test passes
bash .agents/scripts/tests/test-pulse-wrapper-characterization.sh
# → All 26 tests passed

# 3. jq extractor sanity test — four shapes
# Shape 1 (array content): jq returns "## Review: Approved\n..."
# Shape 2 (string content): jq returns the string directly
# Shape 3 (multiple assistant messages): jq returns the LAST
# Shape 4 (non-JSONL garbage): jq fails, fallback fires
# Verified in session transcript

# 4. No functional test possible without a live triage dispatch;
# the real smoke test is the next pulse cycle after this lands, watching
# for "Posted sandboxed triage review" log lines on an NMR issue.
```

## Acceptance Criteria

- [ ] `_dispatch_triage_review_worker()` captures stderr to a separate file, not merged into stdout
  ```yaml
  verify:
    method: codebase
    pattern: '2>"\$review_stderr_file"'
    path: ".agents/scripts/pulse-ancillary-dispatch.sh"
  ```
- [ ] JSONL parsing via jq precedes the plain-text `## Review:` extractor
  ```yaml
  verify:
    method: codebase
    pattern: 'jq -rs'
    path: ".agents/scripts/pulse-ancillary-dispatch.sh"
  ```
- [ ] Failed triage captures are saved to `TRIAGE_DEBUG_DIR` with a `.meta` sidecar, capped at 100 files
  ```yaml
  verify:
    method: codebase
    pattern: 'Triage debug capture saved'
    path: ".agents/scripts/pulse-ancillary-dispatch.sh"
  ```
- [ ] `shellcheck` exits 0, characterization test passes 26/26
  ```yaml
  verify:
    method: bash
    run: "shellcheck .agents/scripts/pulse-ancillary-dispatch.sh && bash .agents/scripts/tests/test-pulse-wrapper-characterization.sh"
  ```

## Context & Decisions

- **Why not change `--format json` in `headless-runtime-helper.sh`?** Because `--format json` is load-bearing for other callers:
  - Session DB merge (`_merge_worker_db`) relies on structured output for SQLite schema mapping
  - `observability-helper.sh:126` parses the JSONL transcript for usage/cost/timing telemetry
  - The session-miner pulse reads JSONL for cross-session analytics
  
  Changing the flag would break all of these. The fix has to live in the triage dispatch path only — that's where the plain-text assumption came from, not from the helper.

- **Why `jq -rs` (slurp) and not line-by-line?** JSONL with streaming assistant messages means the final review text can span multiple `content` blocks or appear in any position. Slurp-then-filter is simpler and correctness-dominant for a file that's always ≤200 KB. Performance isn't a concern; the agent invocation is >100× slower than the parse.

- **Why treat `.content` as a fallback from `.message.content`?** Different opencode versions have varied between `{type, message: {content: ...}}` and `{type, content: ...}`. The `//` coalesce handles both without pinning the schema.

- **Why cap the debug directory at 100 files?** A typical failing cycle produces one debug capture per issue per content version. At 100 files the directory is ~2 MB (median 20 KB per capture). Drop-oldest semantics keep the most recent failures for debugging without unbounded growth. A separate pulse-cleanup task can be added later if we want time-based pruning instead of count-based.

- **Why keep the existing safety filter?** Belt-and-suspenders: even if the JSONL parser extracts the assistant text, a malformed or malicious `.message.content` string could still contain infra markers. The re-check at `line 384` catches this case. It also means the fallback path (raw `cat` on non-JSONL files) still benefits from the existing defence.

- **Non-goals:** Rewriting the triage agent's output contract, changing opencode invocation flags, deleting the old safety filter, implementing time-based debug-dir cleanup, or handling the `--format json` change at the headless-runtime-helper level. All out of scope.

## Relevant Files

- `.agents/scripts/pulse-ancillary-dispatch.sh:290-400` — `_dispatch_triage_review_worker()` (site of all three edits)
- `.agents/scripts/headless-runtime-helper.sh:1477` — `_build_opencode_cmd_args()` (reference: origin of `--format json`)
- `.agents/scripts/sandbox-exec-helper.sh:1013` — `log_sandbox()` (reference: origin of the stderr INFO lines)
- `.agents/scripts/observability-helper.sh:126` — existing JSONL parser reference pattern (reuses the same `.type == "assistant"` filter shape)
- `~/.aidevops/.agent-workspace/tmp/triage-debug/` — new debug directory (created on first failure)

## Dependencies

- **Blocked by:** none (t2024 scope-aware gate fix also unblocks this issue from the pulse dispatch path, but the fix itself is independent)
- **Blocks:** nothing
- **External:** `jq` (already a hard dependency across aidevops)
- **Resolves:** #18473

## Estimate Breakdown

| Phase | Time | Notes |
|-------|------|-------|
| Design + jq expression | 10m | Schema discovery + shape experimentation |
| Implementation | 10m | Three targeted Edit calls |
| Verification | 5m | Shellcheck + characterization test + jq sanity tests |
| Commit + PR | 5m | Conventional commit, PR body with evidence |
| **Total** | **~30m** | |
