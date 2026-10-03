# t18567: feat(hooks): Claude Code keep-going Stop hook matching the OpenCode session-continuation guard

## Origin

- **Created:** 2026-09-30
- **Created by:** ai-interactive
- **Issue:** GH#33143
- **Conversation context:** Framework value audit (parent GH#33139); maintainer approved retiring redundant tooling while keeping the useful ideas.

## Why

OpenCode sessions have a continuation guard that stops models ending turns before the work is done. Claude Code has no equivalent, so behaviour differs between runtimes, especially for models that tend to stop early.

## What

Add a lightweight Claude Code `Stop` hook that pushes back when a session tries to stop with work still open. Parent: GH#33139.

This replaces the retired Ralph loop with the "light encourager" the maintainer asked for, for models that tend to stop early to seek reassurance.

OpenCode already has this behaviour in `.agents/plugins/opencode-aidevops/session-continuation-guard.mjs`:

- `isExplicitCompletionClaim` and `activeTodos` come from `session-continuation-utils.mjs:73` and `:87`.
- It uses a repeated-failure threshold, `DEFAULT_FAILURE_THRESHOLD = 3`.
- Checkpoints are saved through `session-checkpoint-helper.sh recovery-save`.

Claude Code has no equivalent. `.agents/hooks/` only contains PreToolUse and PostToolUse guards, and `update-claude-settings.py` registers no `Stop` hook.

## Design constraints (decide and record in the PR)

- Block the stop only on clear evidence: the transcript's latest TodoWrite state still has `pending` or `in_progress` items, and the final message is not a question to the user or an explicit blocker report.
- Cap it. Use the `stop_hook_active` input field to avoid an infinite loop, allow at most N blocks per session (suggest 2), and after that allow the stop.
- The block reason should be one short sentence: continue the next open todo, or state the blocker and the remaining todos.
- Never block headless or worker sessions that the pulse supervises (they have their own watchdog), and never block when the user explicitly asked to stop.
- Keep the logic in one small Python hook alongside `git_safety_guard.py`, using only the standard library and failing open on any parse error.

## How: reference pattern

- Registration: model on the PreToolUse registration in `.agents/scripts/update-claude-settings.py:33-60`.
- Detection semantics: model on `session-continuation-guard.mjs:120-200`.

### Files Scope

- `.agents/hooks/session_continuation_stop.py`
- `.agents/scripts/update-claude-settings.py`
- `.agents/scripts/install-hooks-helper.sh`
- `.agents/scripts/tests/test-session-continuation-stop-hook.sh`
- `.agents/reference/session.md`

## Acceptance criteria

- [ ] With open todos and no blocker or question, the hook returns a block decision with a one-sentence reason.
- [ ] With `stop_hook_active` true, or after the cap is reached, the hook allows the stop.
- [ ] With no todos, a question to the user, or a malformed transcript, the hook allows the stop (fail-open).
- [ ] `setup.sh --non-interactive` registers the hook idempotently in Claude Code settings.
- [ ] `reference/session.md` has a two-line note on the behaviour and the override.

## Verification

```bash
bash .agents/scripts/tests/test-session-continuation-stop-hook.sh
python3 -m py_compile .agents/hooks/session_continuation_stop.py
.agents/scripts/linters-local.sh
```

Parent: #33139
