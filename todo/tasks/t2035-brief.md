<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# t2035: auto-assign interactive issues in gh_create_issue wrapper

## Origin

- **Created:** 2026-04-13
- **Session:** claude-code (interactive)
- **Created by:** ai-interactive (session that produced t2014/t2017/t2024 + #18507/#18508)
- **Parent task:** none
- **Conversation context:** While investigating why seven `origin:interactive` PRs were stuck in `BLOCKED/REVIEW_REQUIRED`, traced the cascade to `maintainer-gate.yml`'s "no assignee" check at line 275-289. Filed #18507 to fix the framework gate, but discovered the upstream cause: every issue I created in the session was unassigned because manual `gh issue create` calls (which I was making instead of using the wrapper) never set `--assignee @me`. Even the wrapper `gh_create_issue` in `shared-constants.sh` doesn't auto-assign — only the bare `claim-task-id.sh` fallback path has self-assignment, and only after delegated success. Fixing the wrapper closes the upstream hole and reduces #18507's blast radius.

## What

Make `gh_create_issue` in `.agents/scripts/shared-constants.sh` automatically assign newly-created issues to the current GitHub user when the session origin is `interactive`. Mirror the existing `_auto_assign_issue` pattern from `claim-task-id.sh:607-625`. Worker-origin issues are intentionally NOT auto-assigned — the dispatcher handles their assignment downstream.

The wrapper currently:

```bash
gh_create_issue() {
    local origin_label
    origin_label=$(session_origin_label)
    _ensure_origin_labels_for_args "$@"
    gh issue create "$@" --label "$origin_label"
}
```

Will become:

```bash
gh_create_issue() {
    local origin_label
    origin_label=$(session_origin_label)
    _ensure_origin_labels_for_args "$@"

    # Capture the URL so we can self-assign post-creation
    local issue_url
    if ! issue_url=$(gh issue create "$@" --label "$origin_label" 2>&1); then
        printf '%s\n' "$issue_url" >&2
        return 1
    fi
    # Echo URL to stdout for callers that capture output (matches raw gh behaviour)
    printf '%s\n' "$issue_url"

    # Auto-assign interactive issues. Workers skip this — the dispatcher
    # assigns them downstream, and a self-assignment here would race the
    # dedup guard. Non-blocking: assignment failure does not fail creation.
    if [[ "$origin_label" == "origin:interactive" ]]; then
        _gh_auto_assign_from_url "$issue_url" || true
    fi
    return 0
}
```

Plus a new helper `_gh_auto_assign_from_url` that parses `https://github.com/<owner>/<repo>/issues/<num>` and runs `gh issue edit <num> --repo <owner>/<repo> --add-assignee @me`. Pattern lifted from `claim-task-id.sh:_auto_assign_issue` but driven from a URL instead of (issue_num, repo_path).

## Why

### Direct evidence from the session that produced this brief

Seven `origin:interactive` PRs across multiple sessions were stuck in `BLOCKED/REVIEW_REQUIRED`:

```text
#18460 t2013 — headless-runtime-helper split (pre-existing session)
#18495 t2027 — pr-loop Gate Failure Playbook
#18497 t2024 — scope-aware simplification gate (this session)
#18500 t2028 — auto-assign from interactive sessions (related work)
#18502 t2032 — tighten pulse merge-pass close-comment wording
#18505 t2031 — pulse-dep-graph non-dep blocks
#18506 t2029 — issue-sync push failure visibility
```

Every one was authored by the OWNER, every one carried `origin:interactive`, and every one was blocked because its linked issue had no assignee — which meant the maintainer-gate workflow couldn't apply the OWNER-author exemption.

`#18507` files the workflow-side fix (the gate should also exempt origin:interactive + OWNER for the assignee check). This task is the upstream complement: prevent the unassigned state from existing in the first place.

### Why this is a wrapper-level fix and not a "remember to pass --assignee" prompt rule

`AGENTS.md` already says "NEVER use raw `gh pr create` or `gh issue create` directly. Always use the wrappers". The wrapper is the contract. If the contract is "use the wrapper and the right thing happens", the wrapper has to actually do the right thing — including self-assignment for interactive sessions. A prompt rule telling implementers to "remember to pass --assignee" is fragile and exactly the kind of thing the wrapper exists to prevent.

### Effect

- Eliminates the cascade of unassigned issues that #18507 currently has to work around
- Six of seven currently-stuck PRs (#18460 has additional merge conflicts) become unblockable as soon as the wrapper change deploys
- Zero impact on worker dispatch — the wrapper distinguishes `origin:interactive` from `origin:worker` and only self-assigns the former

## Tier

### Tier checklist

- [x] **2 or fewer files to modify?** Yes — 1 file (`shared-constants.sh`); test file optional
- [x] **Complete code blocks for every edit?** Yes — verbatim diffs above
- [x] **No judgment or design decisions?** Yes — the design is fully specified (interactive only, post-creation, non-blocking)
- [x] **No error handling or fallback logic to design?** Yes — non-blocking on assign failure, propagate creation errors
- [x] **Estimate 1h or less?** Yes — ~20 minutes
- [x] **4 or fewer acceptance criteria?** Yes — 4

**Selected tier:** `tier:simple` — single file, copy-pasteable diff, mirrors an existing helper, no design ambiguity. Haiku-appropriate.

## How (Approach)

### Files to modify

- `EDIT: .agents/scripts/shared-constants.sh:823-829` — replace `gh_create_issue` body with the variant above
- `EDIT: .agents/scripts/shared-constants.sh` (after `_ensure_origin_labels_for_args` definition) — add new `_gh_auto_assign_from_url` helper

### `_gh_auto_assign_from_url` implementation (verbatim)

```bash
# Internal: parse a GitHub issue URL and self-assign to the current user.
# Used by gh_create_issue for origin:interactive sessions so the issue
# matches the maintainer-gate "assigned" check from creation onwards.
# Non-blocking — assignment failure is logged but does not fail the caller.
# URL format: https://github.com/<owner>/<repo>/issues/<num>
_gh_auto_assign_from_url() {
    local issue_url="$1"
    [[ -z "$issue_url" ]] && return 0

    # Parse URL → owner/repo and issue number
    local issue_num repo_slug
    issue_num=$(printf '%s' "$issue_url" | grep -oE '[0-9]+$' || echo "")
    repo_slug=$(printf '%s' "$issue_url" | sed -n 's|^https://github\.com/\([^/]*/[^/]*\)/issues/.*|\1|p')
    [[ -z "$issue_num" || -z "$repo_slug" ]] && return 0

    local current_user
    current_user=$(gh api user --jq '.login' 2>/dev/null || echo "")
    [[ -z "$current_user" ]] && return 0

    gh issue edit "$issue_num" --repo "$repo_slug" \
        --add-assignee "$current_user" >/dev/null 2>&1 || true
    return 0
}
```

### Verification

```bash
# 1. Shellcheck clean on the modified file
shellcheck .agents/scripts/shared-constants.sh

# 2. Existing characterization tests still pass
bash .agents/scripts/tests/test-pulse-wrapper-characterization.sh

# 3. Manual smoke test (in any worktree of an aidevops repo):
source .agents/scripts/shared-constants.sh
URL=$(gh_create_issue --repo marcusquinn/aidevops \
    --title "smoke-test t2035 (interactive auto-assign)" \
    --label "test" --body "ignore" 2>&1 | tail -1)
NUM=$(echo "$URL" | grep -oE '[0-9]+$')
gh issue view "$NUM" --repo marcusquinn/aidevops --json assignees --jq '.assignees[].login'
# Expected: marcusquinn (or the current authenticated gh user)
gh issue close "$NUM" --repo marcusquinn/aidevops --reason "not planned"

# 4. Worker-context smoke test (verify workers do NOT self-assign):
AIDEVOPS_HEADLESS=1 bash -c '
    source .agents/scripts/shared-constants.sh
    URL=$(gh_create_issue --repo marcusquinn/aidevops \
        --title "smoke-test t2035 (worker no-assign)" \
        --label "test" --body "ignore" 2>&1 | tail -1)
    NUM=$(echo "$URL" | grep -oE "[0-9]+$")
    ASSIGNEES=$(gh issue view "$NUM" --repo marcusquinn/aidevops --json assignees --jq ".assignees | length")
    echo "Worker-context assignees: $ASSIGNEES (expected 0)"
    gh issue close "$NUM" --repo marcusquinn/aidevops --reason "not planned"
'
```

## Acceptance Criteria

- [ ] `gh_create_issue` calls `_gh_auto_assign_from_url` after a successful create when the session origin is `interactive`
  ```yaml
  verify:
    method: codebase
    pattern: "_gh_auto_assign_from_url"
    path: ".agents/scripts/shared-constants.sh"
  ```
- [ ] Worker-origin sessions (`AIDEVOPS_HEADLESS=1` or detected via `session_origin_label`) do NOT trigger the self-assign path
  ```yaml
  verify:
    method: codebase
    pattern: 'origin_label.*==.*"origin:interactive"'
    path: ".agents/scripts/shared-constants.sh"
  ```
- [ ] Assignment failure does not fail issue creation (non-blocking — `|| true` or equivalent)
  ```yaml
  verify:
    method: codebase
    pattern: "_gh_auto_assign_from_url.*\\|\\| true"
    path: ".agents/scripts/shared-constants.sh"
  ```
- [ ] `shellcheck` exits 0 on the modified file
  ```yaml
  verify:
    method: bash
    run: "shellcheck .agents/scripts/shared-constants.sh"
  ```

## Context & Decisions

- **Why post-creation, not via `--assignee` flag on the `gh issue create` call?** Because `--assignee` requires the user to already exist as a collaborator on the repo and silently fails if not — whereas `gh issue edit --add-assignee @me` is more tolerant and gives a clearer error path. This also matches the pattern already used by `claim-task-id.sh:_auto_assign_issue`. Preserves consistency.
- **Why interactive-only?** Worker sessions are dispatched by the pulse and the dispatcher handles assignment via `dispatch-dedup-helper.sh` and origin labels. A worker that self-assigns at creation time would race the dispatcher's deferred assignment, possibly creating dedup-guard collisions.
- **Why echo the URL to stdout in addition to triggering the helper?** Backwards compatibility: callers that capture `URL=$(gh_create_issue ...)` continue to work. The current `gh issue create` returns the URL on stdout, and the wrapper must preserve that contract.
- **Non-goals:**
  - Changing `claim-task-id.sh` (which already has its own self-assignment in the delegated path)
  - Rewriting the maintainer-gate workflow (that's #18507's scope, and is a complementary belt-and-braces fix)
  - Auto-assigning PRs (PRs are auto-attributed to the author by GitHub; no separate assignment needed)
  - Testing infrastructure beyond the manual smoke test (a full bash test would require mocking `gh`, which is heavier than this fix warrants)

## Relevant Files

- `.agents/scripts/shared-constants.sh:823-836` — `gh_create_issue` definition (site of edit)
- `.agents/scripts/claim-task-id.sh:607-625` — `_auto_assign_issue` (reference pattern)
- `.agents/scripts/claim-task-id.sh:804` — call site demonstrating the pattern in production use
- `.github/workflows/maintainer-gate.yml:275-289` — the gate check this fix targets (tracked by #18507)
- `.agents/AGENTS.md` — "Origin labelling (MANDATORY)" section that mandates wrapper usage

## Dependencies

- **Blocked by:** none
- **Blocks:** indirectly improves throughput on #18507 (workflow-side fix becomes belt-and-braces rather than essential after this lands)
- **External:** none — `gh api user --jq '.login'` is available with the existing gh CLI auth

## Estimate Breakdown

| Phase | Time | Notes |
|-------|------|-------|
| Implementation | 10m | One file, ~30 lines added/modified |
| Verification | 5m | Shellcheck + manual smoke test |
| Commit + PR | 5m | Conventional commit, PR body with evidence |
| **Total** | **~20m** | |
