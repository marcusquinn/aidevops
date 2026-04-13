---
mode: subagent
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->
# t2028: feat(gh-wrappers): auto-assign issues created from OWNER interactive sessions

## Origin

- **Created:** 2026-04-13
- **Session:** OpenCode:interactive (same session as t2015, t2018, t2027)
- **Created by:** marcusquinn (ai-interactive gap-closing pass)
- **Parent task:** none
- **Conversation context:** During the t2018 `/pr-loop` on PR #18481, I created issue #18478 via `gh_create_issue`. That call did NOT assign the issue to me, so the maintainer gate ran against an unassigned linked issue on first PR open and failed with "Issue #18478 has no assignee". I had to run `gh issue edit 18478 --add-assignee marcusquinn` manually. The existing `_auto_assign_issue` path at `claim-task-id.sh:607` (landed as t1970) already handles this correctly for issues created via `claim-task-id.sh`, but the direct `gh_create_issue` wrapper in `shared-constants.sh:823` never got the same treatment. This task brings the wrappers to parity.

## What

`gh_create_issue` in `.agents/scripts/shared-constants.sh` auto-assigns newly created issues to the caller when the session is interactive, unless the caller explicitly passes `--assignee`. Worker-origin sessions are unaffected — they don't auto-assign.

After the fix, running `gh_create_issue --title "..." --body "..."` from an interactive session produces an issue already assigned to the current GitHub user. No manual `gh issue edit --add-assignee` step needed. The maintainer-gate assignee check passes on first PR open.

## Why

Every interactive session that creates an issue and then opens a linked PR currently hits the assignee gate on first Job 1 run. I hit it in t2018 (#18478) and had to manually fix it mid-flow. The `claim-task-id.sh` path already handles this via `_auto_assign_issue` (t1970), but direct `gh_create_issue` calls — which are the normal path for out-of-band issue creation (bug reports, quick-fix issues, etc.) — don't benefit.

**Impact per hit:** ~20 seconds of diagnosis ("why is the gate blocking?") + one manual `gh` call. Compounds over N interactive issue creations.

**Why this is safe to always do:**
- `--assignee` on a non-existent user is rejected by `gh` — the wrapper falls back gracefully (all failure modes silently return empty).
- An explicit `--assignee` in the caller's args overrides the auto-assign — the wrapper detects this and skips auto-assignment.
- Worker-origin sessions (GitHub Actions, pulse, headless CI) return early and don't auto-assign. They follow their own dispatch flow.
- `AIDEVOPS_SESSION_USER` env-var override (from t1984) is honoured — the sync-todo-to-issues workflow sets this to `github.actor` when the actor is human, so issues created from human-triggered pushes get the correct assignee.

## Tier

### Tier checklist

- [x] **≤2 files to modify?** — 1 file: `.agents/scripts/shared-constants.sh`
- [x] **Complete code blocks for every edit?** — yes, full function bodies below
- [x] **No judgment or design decisions?** — pattern is established at `claim-task-id.sh:607`, just mirroring
- [x] **No error handling or fallback logic to design?** — "fall back to no assignee" is the only error path, one line
- [x] **≤1h estimate?** — ~20 minutes
- [x] **≤4 acceptance criteria?** — exactly 4

**Selected tier:** `tier:simple`

## How

### Files to Modify

- `EDIT: .agents/scripts/shared-constants.sh:823-829` — modify `gh_create_issue` to conditionally append `--assignee <user>` when appropriate. Add two small helper functions before the existing `gh_create_issue` definition.

### Implementation

**Step 1: Add the two helper functions immediately before `gh_create_issue` at line 823.**

```bash
# t2028: Internal — check if argv already contains an --assignee flag.
# Used by gh_create_issue to avoid overriding caller-supplied assignees.
_gh_wrapper_args_have_assignee() {
	while [[ $# -gt 0 ]]; do
		case "$1" in
		--assignee | --assignee=*)
			return 0
			;;
		*)
			shift
			;;
		esac
	done
	return 1
}

# t2028: Internal — determine the auto-assignee for a newly-created issue.
# Returns empty string when the session is worker-origin, when the user
# lookup fails, or when there is otherwise nothing to assign. Callers must
# treat empty as "skip assignment". Non-fatal: all failure modes echo empty.
#
# Mirrors the _auto_assign_issue logic at claim-task-id.sh:607 (t1970) so
# the direct gh_create_issue path reaches assignee-gate parity with the
# claim-task-id.sh path.
_gh_wrapper_auto_assignee() {
	local origin
	origin=$(detect_session_origin)
	if [[ "$origin" != "interactive" ]]; then
		return 0
	fi
	# t1984 override: sync-todo-to-issues workflow sets AIDEVOPS_SESSION_USER
	# to github.actor when the commit author is human. Prefer that explicit
	# signal over gh api user, which would return github-actions[bot] inside
	# a workflow run.
	if [[ -n "${AIDEVOPS_SESSION_USER:-}" ]]; then
		printf '%s' "$AIDEVOPS_SESSION_USER"
		return 0
	fi
	local current_user
	current_user=$(gh api user --jq '.login' 2>/dev/null || true)
	[[ -n "$current_user" && "$current_user" != "null" ]] || return 0
	printf '%s' "$current_user"
	return 0
}
```

**Step 2: Replace the existing `gh_create_issue` definition at line 823-829.**

Find:

```bash
gh_create_issue() {
	local origin_label
	origin_label=$(session_origin_label)
	# Ensure labels exist on the target repo (once per repo per process)
	_ensure_origin_labels_for_args "$@"
	gh issue create "$@" --label "$origin_label"
}
```

Replace with:

```bash
gh_create_issue() {
	local origin_label
	origin_label=$(session_origin_label)
	# Ensure labels exist on the target repo (once per repo per process)
	_ensure_origin_labels_for_args "$@"

	# t2028: auto-assign to the current user when the session is interactive
	# and the caller did not pass an explicit --assignee. Parity with the
	# t1970 auto-assign already applied to the claim-task-id.sh path.
	if ! _gh_wrapper_args_have_assignee "$@"; then
		local auto_assignee
		auto_assignee=$(_gh_wrapper_auto_assignee)
		if [[ -n "$auto_assignee" ]]; then
			gh issue create "$@" --label "$origin_label" --assignee "$auto_assignee"
			return $?
		fi
	fi

	gh issue create "$@" --label "$origin_label"
}
```

**Step 3: Manual smoke test.**

```bash
# In a fresh shell, from the worktree:
source .agents/scripts/shared-constants.sh
# Dry-run by inspecting the function definition rather than creating a real issue:
declare -f gh_create_issue
declare -f _gh_wrapper_args_have_assignee
declare -f _gh_wrapper_auto_assignee

# Smoke test the helpers:
_gh_wrapper_args_have_assignee --title foo --assignee bar && echo "PASS: detects --assignee"
_gh_wrapper_args_have_assignee --title foo && echo "PASS: detects absence (negated)" || true

# Session origin detection check:
detect_session_origin
# Expect: "interactive" (unless headless env vars set)

_gh_wrapper_auto_assignee
# Expect: your gh login (e.g., "marcusquinn")
```

**Step 4: Shellcheck.**

```bash
shellcheck .agents/scripts/shared-constants.sh
```

### Verification

```bash
shellcheck .agents/scripts/shared-constants.sh \
  && grep -c "_gh_wrapper_args_have_assignee" .agents/scripts/shared-constants.sh \
  && grep -c "_gh_wrapper_auto_assignee" .agents/scripts/shared-constants.sh
```

Runtime verification: the next `gh_create_issue` call from an interactive session should produce an issue with the caller pre-assigned. Observable by running `gh issue view N --json assignees` on the newly-created issue.

## Acceptance Criteria

- [ ] `.agents/scripts/shared-constants.sh` defines `_gh_wrapper_args_have_assignee` and `_gh_wrapper_auto_assignee` helper functions.
  ```yaml
  verify:
    method: codebase
    pattern: "_gh_wrapper_args_have_assignee\\b"
    path: ".agents/scripts/shared-constants.sh"
  ```
- [ ] `gh_create_issue` calls the helpers and conditionally appends `--assignee <user>`.
  ```yaml
  verify:
    method: codebase
    pattern: "auto_assignee=.*_gh_wrapper_auto_assignee"
    path: ".agents/scripts/shared-constants.sh"
  ```
- [ ] The file passes `shellcheck` with zero violations.
  ```yaml
  verify:
    method: bash
    run: "shellcheck .agents/scripts/shared-constants.sh"
  ```
- [ ] Explicit `--assignee` in caller args is respected (not overridden).
  ```yaml
  verify:
    method: manual
    prompt: "Run gh_create_issue with --assignee octocat and verify the resulting issue is assigned to octocat, not the current user."
  ```

## Context & Decisions

**Why not modify `gh issue create` itself?** Monkey-patching a system command is fragile. The wrapper is the documented indirection point; all in-framework callers already use `gh_create_issue`, so this fix reaches them automatically.

**Why also apply to `gh_create_pr`?** Considered but rejected. PRs are auto-assigned by GitHub to the PR author; there's no parallel gap. Only issues need this.

**Why `detect_session_origin` instead of a simpler check?** The framework already has a canonical origin detection path. Duplicating its logic (e.g. hand-rolling a `[[ -z "$GITHUB_ACTIONS" ]]` check) would cause drift if the set of headless signals expands.

**Why `AIDEVOPS_SESSION_USER` override?** The sync-todo-to-issues workflow (per t1984) is a case where the session is technically "interactive" (human pushed the commit) but runs inside GitHub Actions where `gh api user` would return `github-actions[bot]`. The env var is the canonical override already used by `issue-sync-helper.sh:467-483` — same pattern.

**Non-goals:**
- Adding unit tests for the helpers (bash shell functions are hard to unit-test in isolation; smoke tests on the real path are more valuable and happen through the runtime of every interactive session).
- Changing the default assignee to the maintainer when the caller is not the maintainer (too much policy; could conflict with legitimate delegation).
- Auto-assigning PRs (already handled by GitHub).

## Relevant Files

- `.agents/scripts/shared-constants.sh:823-829` — the current `gh_create_issue` definition.
- `.agents/scripts/claim-task-id.sh:604-625` — the t1970 `_auto_assign_issue` pattern being mirrored.
- `.agents/scripts/issue-sync-helper.sh:467-483` — the `AIDEVOPS_SESSION_USER` override pattern being mirrored.
- `.agents/scripts/shared-constants.sh:756-798` — `detect_session_origin` function used for origin check.

## Dependencies

- **Blocked by:** none
- **Blocks:** nothing direct; eliminates one assignee-gate hit per interactive issue creation, compounding over future flows
- **External:** none

## Estimate Breakdown

| Phase | Time |
|-------|------|
| Write brief | (done) |
| Implementation | 10m |
| Shellcheck + smoke test | 5m |
| Commit + PR + /pr-loop | ~20m incl. CI |
| **Total** | **~20m hands-on + ~20m CI** |
