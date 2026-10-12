<!-- aidevops:brief-schema=v2 -->

# fix(shared): make the push_cleanup/_run_cleanups stack run each scope only at its owner's return

## Pre-flight (auto-populated by briefing workflow)

- [x] Memory recall: `cleanup stack RETURN trap _run_cleanups owner scope` → 0 hits
- [x] Discovery pass: no open PR touches `.agents/scripts/shared-constants.sh` cleanup stack; t18678 (GH#34469) moved Pulse's process-lifetime cleanup off this stack and deliberately left the stack unchanged
- [x] File refs verified at origin/main b0cf41c643: stack `.agents/scripts/shared-constants.sh:1240-1356` (`push_cleanup` `:1294`, `_run_cleanups` `:1307`, `_save_cleanup_scope` `:1350`); fallback copies and helper `.agents/scripts/shared-gh-wrappers.sh:99-114`; helper callers `.agents/scripts/shared-gh-wrappers-create.sh:627`/`:1175`/`:1306`/`:1352`, `shared-gh-wrappers-safe-edit.sh:494`/`:597`/`:639`, `shared-gh-wrappers-batch.sh:35`; existing test `.agents/scripts/tests/test-shared-constants-cleanup-stack.sh`
- [x] Tier: `tier:thinking` — shared contract used by 53 scripts; the owner-tracking design must hold on bash 3.2 and 5.x
- [x] Seeded draft PR decision recorded: skipped — design choice belongs to the implementer

## Origin

- **Created:** 2026-10-12
- **Session:** opencode:interactive
- **Created by:** ai-interactive
- **Conversation context:** while fixing t18678 (Pulse lifetime cleanup ran mid-cycle), probes showed the shared cleanup stack itself runs a caller's cleanups early.

## What

`push_cleanup` commands run exactly once, when the function that owns their scope returns. A RETURN trap never runs or pops a scope that belongs to another frame, and `_gh_wrapper_enter_cleanup_scope` binds the new scope to its caller (the gh_* wrapper), not to itself.

## Why

Reproduced with the unchanged `shared-constants.sh` on bash 5.3.20 and `/bin/bash` 3.2.57 (`AIDEVOPS_BASH_REEXECED=1` to stop the re-exec), identical output on both:

1. A function using the documented pattern (`_save_cleanup_scope; trap '_run_cleanups' RETURN; push_cleanup ...`) that calls any gh write wrapper (`gh_issue_edit_safe`, `gh_pr_edit_safe`, `gh_issue_close_safe`, `gh_create_issue`, `gh_create_pr`, `gh_issue_comment`, `gh_pr_comment`, `gh_write_batch`) has its OWN pending cleanups run when the wrapper returns, before its next line. `_gh_wrapper_enter_cleanup_scope` sets the RETURN trap inside itself, so the trap fires at the helper's own return, pops straight back to the caller's scope, the wrapper then pushes into that scope, and the wrapper's return runs the merged list.
2. A documented-pattern helper called from a function that has no RETURN trap leaves its trap installed; it fires again when that trap-less caller returns and runs the next outer owner's pending scope early.

Impact: temp files, locks or state that a caller registered for cleanup are removed while the caller is still using them, and later scopes run one level out of step. t18678 hit this as Pulse losing its runtime bundle lease and per-cycle caches mid-cycle; other callers of the stack are exposed the same way.

Reproduction (save as a file and run with `bash <file> <checkout>`):

```bash
set -u
source "$1/.agents/scripts/shared-constants.sh" >/dev/null 2>&1
fake_gh_wrapper() { _gh_wrapper_enter_cleanup_scope; push_cleanup "printf 'wrapper cleanup\n'"; return 0; }
caller_with_scope() {
	_save_cleanup_scope
	trap '_run_cleanups' RETURN
	push_cleanup "printf 'CALLER cleanup\n'"
	fake_gh_wrapper
	printf 'caller continues (CALLER cleanup must not have run)\n'
	return 0
}
caller_with_scope
```

Current output prints `CALLER cleanup` before `caller continues`.

## Tier

**Selected tier:** `tier:thinking`

**Tier rationale:** the owner-tracking mechanism for RETURN traps is a consequential design decision on a contract shared by 53 scripts, with bash-version-specific trap save/restore behaviour to verify.

## How

### Files to Modify

- `EDIT: .agents/scripts/shared-constants.sh:1240-1356` — record an owner per saved scope and make `_run_cleanups` act only when the owning frame returns; update the usage comment block.
- `EDIT: .agents/scripts/shared-gh-wrappers.sh:99-114` — keep the fallback `_save_cleanup_scope`/`_run_cleanups` copies in sync; make `_gh_wrapper_enter_cleanup_scope` register the scope for its caller.
- `EDIT: .agents/scripts/tests/test-shared-constants-cleanup-stack.sh` — add the two reproduction cases plus nested owners, a command-substitution call and a background-subshell call.

### Complete Write Surface

- **Callers/readers:** 53 scripts call `_save_cleanup_scope` (`rg -l _save_cleanup_scope .agents/scripts`); the gh_* write wrappers call `_gh_wrapper_enter_cleanup_scope`.
- **Writers/mutation paths:** only `push_cleanup`, `_save_cleanup_scope`, `_run_cleanups` (and their fallbacks in `shared-gh-wrappers.sh`) mutate `_CLEANUP_CMDS`/`_CLEANUP_SAVE_STACK`.
- **Existing verification/tests:** `tests/test-shared-constants-cleanup-stack.sh`, `tests/test-shared-gh-wrappers-*.sh`, `tests/test-pulse-wrapper-canary.sh`.
- **Schemas/config:** N/A because no config is involved.
- **Generated/deployed mirrors:** `setup.sh` deploys `.agents/scripts/`; no generated copies.
- **Migrations/backfills:** N/A because the stack is per-process state.
- **Cleanup/rollback paths:** `git revert`.

### Implementation Steps

1. Decide the owner key, for example the `${#FUNCNAME[@]}` depth of the owning frame captured in `_save_cleanup_scope` (the helper's caller when called through `_gh_wrapper_enter_cleanup_scope`), stored alongside the saved scope.
2. In `_run_cleanups`, compare the returning frame (inside the handler, `${#FUNCNAME[@]} - 1`) with the current owner; run and pop only on a match, otherwise return 0 without touching the stack.
3. Ensure a fired trap does not keep firing in trap-less callers after its owner returned; verify how each bash version restores a caller's RETURN trap after a callee changed it before relying on `trap - RETURN`.
4. Add the regression cases and run the verification below on both bash versions.

### Hazards and Compatibility

- **Concurrency/atomicity:** per-process shell state only.
- **Migration/rollback:** none; revert restores current behaviour.
- **Mixed-version/backward compatibility:** keep the documented call pattern working unchanged for all 53 callers; the fallback copies in `shared-gh-wrappers.sh` must behave identically.
- **Idempotency/retry:** a scope must never run twice or be skipped; a non-matching fire must be a no-op.
- **Partial failure/recovery:** a failing cleanup command must not prevent the remaining commands of the same scope from running (current `|| true` behaviour).

### Verification Before Dispatch

```bash
shellcheck -x .agents/scripts/shared-constants.sh .agents/scripts/shared-gh-wrappers.sh .agents/scripts/tests/test-shared-constants-cleanup-stack.sh
bash .agents/scripts/tests/test-shared-constants-cleanup-stack.sh
AIDEVOPS_BASH_REEXECED=1 /bin/bash .agents/scripts/tests/test-shared-constants-cleanup-stack.sh
bash .agents/scripts/tests/test-pulse-wrapper-canary.sh
```

- **Surface mapping:** run the reproduction above on both bash versions; `caller continues` must print before `CALLER cleanup`.
- **Broad verification trigger:** shared contract change; also run every `tests/test-shared-gh-wrappers-*.sh`.

### Scope Boundaries

**Hard boundaries:** do not change Pulse's dedicated `_pulse_exit_cleanup` EXIT handler (t18678); do not migrate callers away from the stack.

**Not in scope (follow-up):** auditing individual callers for cleanup timing assumptions that depended on the early runs; the documented single-file shorthand (`trap 'rm -f "${tmp:-}"' RETURN`, `shared-constants.sh:1263-1269`) has the same persistence into trap-less callers and needs its own audit.

**AI brief owner:** interactive maintainer session that filed this task.

### Files Scope

- `.agents/scripts/shared-constants.sh`
- `.agents/scripts/shared-gh-wrappers.sh`
- `.agents/scripts/tests/test-shared-constants-cleanup-stack.sh`

## Acceptance Criteria

- [ ] The reproduction prints `caller continues` before `CALLER cleanup` on bash 5.x and bash 3.2.

  ```yaml
  verify:
    method: manual
    prompt: "Run the reproduction from the Why section with bash 5.x and with AIDEVOPS_BASH_REEXECED=1 /bin/bash"
  ```

- [ ] The cleanup stack test passes on both bash versions, including the new nested-scope cases.

  ```yaml
  verify:
    method: bash
    run: "bash .agents/scripts/tests/test-shared-constants-cleanup-stack.sh"
  ```

- [ ] ShellCheck reports no findings for the changed files.

  ```yaml
  verify:
    method: bash
    run: "shellcheck -x .agents/scripts/shared-constants.sh .agents/scripts/shared-gh-wrappers.sh .agents/scripts/tests/test-shared-constants-cleanup-stack.sh"
  ```
