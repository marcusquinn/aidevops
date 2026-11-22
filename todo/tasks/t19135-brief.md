<!-- aidevops:brief-schema=v2 -->

## Pre-flight

- [x] Memory recall: `zsh compat _gh_with_timeout cooldown preflight stub` → 0 relevant hits.
- [x] Discovery pass: no open issue/PR mentions `_gh_timeout_cooldown_preflight` with zsh (searched 2026-11-19).
- [x] File refs verified: paths below exist at `main`.
- [x] Tier: `tier:simple` — one-line test fixture stub, exact pattern exists in another test.

## Origin

- **Created:** 2026-11-19
- **Created by:** AI DevOps interactive session (found while verifying GH#39187)
- **Conversation context:** Running the gh-wrapper test set for the gh-shim fork-reduction PR showed `test-gh-wrapper-zsh-compat.sh` scenario 2 failing identically on unmodified `main`.

## What

Make `test-gh-wrapper-zsh-compat.sh` scenario 2 pass again. It extracts `_gh_with_timeout` from `shared-gh-wrappers.sh` into a zsh script and stubs its collaborators, but `_gh_with_timeout` now also calls `_gh_timeout_cooldown_preflight` (defined at `.agents/scripts/shared-gh-wrappers.sh:537`), which the fixture neither extracts nor stubs. Under zsh the run prints `_gh_with_timeout:13: command not found: _gh_timeout_cooldown_preflight` instead of `fake-gh-called:issue edit 123`.

## Why

A permanently red regression guard hides real zsh breakage of the direct function-dispatch path (PR #22359) and costs every verifier a baseline comparison against `main`.

## Tier

`tier:simple`.

## How (Approach)

### Files to Modify

- EDIT: `.agents/scripts/tests/test-gh-wrapper-zsh-compat.sh:173-174` — add a stub line next to the existing `_gh_cooldown_context_from_args` / `_gh_record_cooldown_response_if_needed` stubs.

### Implementation Steps

1. Add `printf '%s\n' '_gh_timeout_cooldown_preflight(){ return 0; }'` beside the existing stubs (same pattern as `.agents/scripts/tests/test-full-loop-merge-cases.sh:1249`).
2. Check `_gh_with_timeout` in `shared-gh-wrappers.sh` for any other newly called helper that the fixture lacks and stub it the same way.

### Files Scope

- `.agents/scripts/tests/test-gh-wrapper-zsh-compat.sh`

## Acceptance Criteria

- [ ] `bash .agents/scripts/tests/test-gh-wrapper-zsh-compat.sh` reports `Tests run: 4, failed: 0`.
- [ ] Negative: temporarily making the fixture's `_gh_with_timeout` route through `timeout` still makes scenario 2 fail (the guard keeps its meaning).
- [ ] ShellCheck clean on the test file.
