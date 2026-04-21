<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->
# t2688 — fix `local -n` namerefs in shared-gh-wrappers.sh (GH#20300)

## Session Origin

Interactive session. Filed as follow-up to the `/review-issue-pr 20300`
review (posted to GH#20300#issuecomment-4289747061, verdict APPROVE).
The review noted the fix was trivial and pointed at the canonical
pattern in `task-brief-helper.sh:643,757`.

## Created by

@marcusquinn (interactive), bugfix/t2688-local-n-zsh-compat

## What

Replace the bash-only `local -n` nameref pattern in
`_gh_wrapper_extract_task_id_from_title_step()` with the module-level
globals pattern already proven in `task-brief-helper.sh`. Output
globals: `_GH_WRAPPER_EXTRACT_TODO`, `_GH_WRAPPER_EXTRACT_TITLE`.

Add a dedicated regression test (`test-gh-wrapper-zsh-compat.sh`)
that invokes the extracted function body under zsh and asserts
(a) no `local:N: bad option: -n` error appears, and (b) the
`--todo-task-id` extraction still works. Also add a syntactic
guard: no `local -n` in either function body.

## Why

`local -n` is bash 4.3+. Two environments cannot use it:

1. **zsh** — `local` does not accept `-n`. Under zsh, every invocation
   of `_gh_wrapper_extract_task_id_from_title_step` emits
   `local:2: bad option: -n` to stderr and the target variables stay
   unset, so the t2436 race-closing mechanism silently degrades to
   the async label-sync path.
2. **macOS /bin/bash 3.2** — no namerefs at all. The re-exec guard in
   `shared-constants.sh:47-79` normally re-execs 3.2 callers under
   Homebrew bash 4+, but the guard checks `BASH_VERSINFO` and
   `BASH_SOURCE[1]`, which are unset when zsh itself is the caller.
   Gap: zsh sourcing a `.sh` file via `.zshrc` or a zsh subshell
   invoking these functions.

Proof (run end-to-end during implementation):

```
UNPATCHED under zsh:
  output: [_gh_wrapper_extract_task_id_from_title_step:local:2: bad option: -n
           _gh_wrapper_extract_task_id_from_title_step:local:2: bad option: -n]

PATCHED under zsh:
  output: [t2430]
```

### macOS vs Linux differences

- **macOS**: `/bin/bash` 3.2, `/bin/zsh` default login shell.
  Homebrew bash re-exec guard covers shebang-invoked scripts but not
  zsh-sourced chains. This fix closes that gap.
- **Linux**: `/bin/bash` is already 4+/5+, so the namerefs "work" on
  Linux bash. But zsh users on Linux hit the same bug. This fix covers
  Linux zsh users and any legacy Linux still shipping bash 3.2 (rare —
  RHEL 5/6 era).

## How

Apply the exact pattern from `task-brief-helper.sh:643,757` (t2436's
own adjacent sibling):

- Move the two "return" values out of the step function's parameter
  list — step now takes only `(arg, prev)`.
- Initialise `_GH_WRAPPER_EXTRACT_TODO=""` and
  `_GH_WRAPPER_EXTRACT_TITLE=""` at the top of the wrapper function
  before the loop. This makes consecutive calls idempotent.
- Write to the module-level globals directly inside the step.
- Echo `${_GH_WRAPPER_EXTRACT_TODO:-$_GH_WRAPPER_EXTRACT_TITLE}` at
  the end of the wrapper (unchanged logic).

Add regression test `test-gh-wrapper-zsh-compat.sh` that:

1. Skips cleanly if zsh is not installed.
2. Extracts the two function bodies from `shared-gh-wrappers.sh`
   using `awk` (the full file can't be sourced by zsh because of
   top-level `BASH_SOURCE` references — that's a separate surface,
   outside t2688 scope).
3. Feeds them to a fresh zsh process with a `--todo-task-id t2688`
   invocation and asserts no nameref error, correct extraction.
4. Adds a syntactic guard: `local -n` must not reappear in either
   function body.

### Files Scope

- `.agents/scripts/shared-gh-wrappers.sh`
- `.agents/scripts/tests/test-gh-wrapper-zsh-compat.sh`
- `todo/tasks/t2688-brief.md`
- `TODO.md`

## Acceptance

- [ ] `_gh_wrapper_extract_task_id_from_title_step` no longer uses
      `local -n`.
- [ ] Globals `_GH_WRAPPER_EXTRACT_TODO` / `_GH_WRAPPER_EXTRACT_TITLE`
      are initialised (to `""`) at the top of each wrapper invocation
      so consecutive calls don't leak state.
- [ ] `test-parent-tag-sync.sh` still passes (scenarios 2b, 2c
      cover the bash path for this function).
- [ ] New `test-gh-wrapper-zsh-compat.sh` passes with 3/3 assertions
      on any machine where zsh is installed; skips cleanly otherwise.
- [ ] `shellcheck .agents/scripts/shared-gh-wrappers.sh` introduces
      no new findings vs base.
- [ ] `shellcheck .agents/scripts/tests/test-gh-wrapper-zsh-compat.sh`
      is clean.
- [ ] PR title uses `t2688:` prefix.

## Context

- Original bug: GH#20300.
- Review that approved the fix: `/review-issue-pr 20300` →
  GH#20300#issuecomment-4289747061. Review explicitly scoped to this
  single call site and instructed the implementer NOT to sweep the
  9 other nameref sites in `document-creation-helper.sh` or the 5
  other helpers — those go in a separate audit follow-up.
- Reference pattern: `task-brief-helper.sh:643,757`
  (`_BRIEF_SESSION_ORIGIN`, `_BRIEF_CREATED_BY`,
  `_BRIEF_CONTEXT_BLOCK`, `_BRIEF_SUP_ID`) with comment
  "bash 3.2: no `local -n` namerefs".
- Related t2436 test: `test-parent-tag-sync.sh` scenarios 2a-2c.
- No collision: `git log --since="1 week" -- shared-gh-wrappers.sh`
  returned only REST-fallback and audit-log commits; no in-flight
  PRs on this file.
