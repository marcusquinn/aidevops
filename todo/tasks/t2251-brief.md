# t2251 — fix(gh-signature-helper): session type and token count misdetected

## Session origin

Interactive. While auditing whether three v3.8.72-era framework issues were
already tracked, observed that PR #19793's signature footer claimed
"spent 22m and 195 tokens on this as a headless worker" — but the session was
an interactive maintainer-driven one that had consumed well over 20k tokens.
Both the session-type classification and the token count were wrong.

## What

`gh-signature-helper.sh footer` misclassifies active interactive sessions as
"headless worker" and reports token counts that are orders of magnitude too
low. Fix both detections and add a regression test.

- **Session type**: `_detect_session_type` at `gh-signature-helper.sh:633-676`
  has two branches. For OpenCode runtimes it queries the session DB for user-
  message count (>1 → interactive). For non-OpenCode it uses env vars
  (`FULL_LOOP_HEADLESS`, `AIDEVOPS_HEADLESS`, `CLAUDE_CODE`, `CLAUDE_SESSION_ID`).
  One or both paths are returning "worker" for real interactive sessions.
- **Token count**: the formatter that emits the "spent Xm and N tokens" string
  (line 1091+ in the same file, source extraction around lines 798-840) is
  reading a field that sits at two orders of magnitude below the true value.

## Why

1. Downstream routing keys off the flag. The pulse's idle-interactive PR
   handover (t2189) and auto-close paths distinguish by origin/session type;
   a misclassified interactive session that presents as "worker" could be
   picked up by automation that shouldn't touch it.
2. Token counts at 195 vs 20000+ are useless for capacity planning, cost
   accounting, and the accumulator that sums prior-comment tokens across an
   issue thread — the sum is poisoned by every undercount.
3. These footers land on every issue body, PR description, and comment the
   helper touches. Each wrong value compounds the next.

## How (investigation + fix)

### Step 1 — Reproduce

Run `.agents/scripts/gh-signature-helper.sh footer --model claude-opus-4-7`
inside an OpenCode interactive session with ≥2 persisted user messages.
Record:

- `_is_opencode_runtime` return value (add a debug echo)
- `_find_session_id` return value
- The SQL query and its result (count of user messages)
- The token count the helper emits vs `session-introspect-helper.sh tokens`

Three top-ranked hypotheses:

1. **Session-ID resolution drifts** — `_find_session_id` (line ~656) may pick
   up a different session ID under concurrency (multiple OpenCode TUIs) or
   after a fast session swap, so the user-message-count query reads from the
   wrong session. Check: do multiple OpenCode DBs exist? Does the function
   prefer most-recent vs most-active?
2. **Query timing race** — if `footer` is invoked while the current user
   message is still in flight (OpenCode persists after the model returns, not
   on keystroke), the count may be 0 or 1 for a session with one visible
   user prompt, falling under the >1 threshold.
3. **Runtime miss** — `_is_opencode_runtime` at line 316 checks `OPENCODE_PID`.
   Some OpenCode entry paths (TUI subshells, plugin-spawned terminals) may not
   inherit that variable, so the function returns false and the code falls
   through to the env-var heuristic which finds no markers and defaults to
   "worker".

### Step 2 — Fix

For each hypothesis that validates, apply the minimum fix:

- ID drift → add a process-ancestry or PWD-correlation check to prefer the
  session whose `directory` matches `$PWD`.
- Query timing → switch from "user-message count" to a cheaper signal: if
  `TERM`/`OPENCODE_TTY`/`isatty stdin` is set, the session is interactive,
  regardless of DB state.
- Runtime miss → detect OpenCode via multiple signals: `OPENCODE_PID`,
  `OPENCODE_SESSION_ID`, presence of `~/.local/share/opencode/opencode.db`
  AND `pgrep -f opencode` returning a live PID.

### Step 3 — Token count

Locate the token source field. Two candidates:

- Session DB column (per OpenCode schema: `message.data` JSON may contain
  `usage.total_tokens` or similar)
- Runtime env (`AIDEVOPS_SESSION_TOKENS` if set by the runtime)

Verify the helper reads from the source that actually reflects the live
session budget. The current reading of "195" looks like it's picking up a
tool-call count or a single-message token count instead of the session total.

### Step 4 — Tests

`NEW: .agents/scripts/tests/test-gh-signature-helper-detection.sh` with
fixtures:

- Interactive OpenCode session w/ ≥2 user messages → type `interactive`.
- Fresh interactive session w/ 1 user message + interactive TTY → type
  `interactive` (guards against the timing race).
- `FULL_LOOP_HEADLESS=1` env → type `worker` regardless of DB state.
- Token count within ±5% of a seeded DB value.

Model the test on `tests/test-gh-signature-helper.sh` if it exists, else on
`tests/test-origin-label-exclusion.sh` (both use a sandbox + fixture DB
pattern).

## Files

- `EDIT: .agents/scripts/gh-signature-helper.sh` — primary fix target,
  specifically `_detect_session_type` (:633-676), `_is_opencode_runtime`
  (:316), `_find_session_id` (:656 area), and the token-extraction /
  formatter pair (:798-840, :1091+)
- `NEW: .agents/scripts/tests/test-gh-signature-helper-detection.sh`

## Acceptance criteria

- [ ] In an OpenCode interactive session with ≥2 persisted user messages,
      `_detect_session_type` returns `interactive`.
- [ ] In an OpenCode interactive session with 1 pending user message (timing
      race scenario), `_detect_session_type` still returns `interactive` via
      fallback TTY detection.
- [ ] With `FULL_LOOP_HEADLESS=1` set, `_detect_session_type` returns `worker`
      regardless of DB state.
- [ ] Token count in the emitted footer is within ±5% of the actual session
      total tokens (cross-check with `session-introspect-helper.sh tokens` or
      equivalent).
- [ ] `.agents/scripts/tests/test-gh-signature-helper-detection.sh` exists
      and all assertions pass.
- [ ] `shellcheck .agents/scripts/gh-signature-helper.sh` clean.
- [ ] No regression on non-OpenCode paths (Claude Code, bare shell) — verified
      by running the helper under each runtime.

## Context

- Observed in PR #19793 (t2250 tabby fix, v3.8.72 release) footer.
- Actual session state: ~1h6m elapsed, 119k+ tokens consumed by session end.
- Helper-emitted footer: 22m, 195 tokens, "headless worker" — three errors in
  one line.
- Related: t2189 (idle interactive PR handover) uses `origin:interactive` label
  which is set at issue/PR creation. The session-type signal is a separate
  runtime classification — don't conflate the two. The fix here targets
  runtime detection only; the label-based origin flow is unaffected.
- Related: t2174 / r913 (OpenCode DB maintenance) keeps the DB healthy so
  session-ID lookups stay fast. Don't let this task creep into DB hygiene —
  that's already owned.
