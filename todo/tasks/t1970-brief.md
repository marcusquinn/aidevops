<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->
# t1970: claim-task-id.sh — auto-assign @me when session origin is interactive

## Origin

- **Created:** 2026-04-12
- **Session:** claude-code:interactive
- **Created by:** ai-interactive
- **Parent task:** none (observational finding from the t1965 session)
- **Conversation context:** When we opened PR #18361 (t1965), the "Maintainer Review & Assignee Gate" failed because issue #18359 had no assignee at the time CI ran. We self-assigned after the fact, but CI doesn't auto-re-run on assignee changes, so we had to manually rerun the workflow and fall back to `gh pr merge --admin`. The fix is simple: when `claim-task-id.sh` is called from an interactive session (origin:interactive), it should also self-assign the created issue to `@me` atomically. This eliminates the race where an interactive session claims a task but forgets to self-assign before CI fires.

## What

Modify `.agents/scripts/claim-task-id.sh` so that when it creates a GitHub issue and the session origin is `interactive` (detected via the existing `ORIGIN` / `origin:interactive` label flow, OR via an explicit `--origin interactive` CLI flag), it also calls `gh issue edit <num> --add-assignee @me`. If `@me` fails to resolve (unauthenticated `gh`) or the API call fails, log a warning and continue — do not fail the claim.

Also add a dedup fix as a narrow follow-up in the same PR: when `claim-task-id.sh` does its title-similarity match against existing issues, filter to `state:open` only. The t1968 claim in this same session accidentally linked to closed issue #18359 because the dedup check considered closed issues too.

## Why

Two user-visible problems in the same helper:

1. **Assignee race:** interactive sessions that claim a task + create a brief + push quickly hit the Maintainer Gate before a human has a chance to assign. CI fails; human has to re-run the workflow. The fix costs one `gh issue edit` call and removes a consistent friction point for interactive PR flows.

2. **Closed-issue false match:** the dedup's title-similarity check doesn't filter by state. Any closed issue whose title substring-matches the new claim can steal the ref. This poisons the TODO entry with a dead ref (`ref:GH#NNN` where NNN is closed), which downstream tools then skip or misroute.

Both are small fixes. Keeping them in one PR makes sense because they're both in `claim-task-id.sh` and both improve the same interactive flow.

## Tier

### Tier checklist

- [x] **2 or fewer files to modify?** — 1 (`claim-task-id.sh`)
- [x] **Complete code blocks for every edit?** — yes, exact patches below
- [x] **No judgment or design decisions?** — contract is fixed; the two edits are surgical
- [x] **No error handling or fallback logic to design?** — assignee failure logs + continues; that's settled
- [x] **Estimate 1h or less?** — ~40m
- [x] **4 or fewer acceptance criteria?** — 4

**Selected tier:** `tier:simple`

## How (Approach)

### Files to Modify

- `EDIT: .agents/scripts/claim-task-id.sh` — two small patches:
  1. After the issue is created, if origin is interactive, call `gh issue edit <num> --add-assignee @me`.
  2. In the dedup title-similarity check, add `--state open` to the `gh issue list` call so closed issues can't match.

### Implementation Steps

1. Locate the issue-creation success path in `claim-task-id.sh` (where it prints `Created issue: GH#NNN`). Immediately after that print, add:

    ```bash
    # If origin is interactive, self-assign so the Maintainer Gate passes on
    # the first CI run (avoids the race where a worker pushes before a human
    # can assign). See t1970.
    local claim_origin="${ORIGIN:-${CLAIM_ORIGIN:-}}"
    if [[ "$claim_origin" == "interactive" ]] || [[ "${AIDEVOPS_SESSION_ORIGIN:-}" == "interactive" ]]; then
        if gh issue edit "$issue_number" --repo "$repo_slug" --add-assignee @me >/dev/null 2>&1; then
            print_info "Auto-assigned @me to #${issue_number} (origin:interactive)"
        else
            print_warning "Could not self-assign #${issue_number} — assign manually to unblock Maintainer Gate"
        fi
    fi
    ```

2. Locate the title-similarity dedup call — look for `gh issue list` followed by jq filtering on title substring. Change the `gh issue list` call to include `--state open` (or `--search "state:open <title>"` if the search path is used). Exact one-line edit:

    ```bash
    # Before:
    gh issue list --repo "$repo_slug" --search "$search_query" ...
    # After:
    gh issue list --repo "$repo_slug" --state open --search "$search_query" ...
    ```

    If the existing call already uses `--state all` explicitly, change it to `--state open`. If dedup walks a paginated API response, add the state filter to the API query.

3. Read the actual existing code in `claim-task-id.sh` before applying — the exact variable names and flow may differ from my skeleton above. The intent is what matters: post-create, check origin, self-assign; dedup, restrict to open.

4. Shellcheck clean.

5. Manual test:

    ```bash
    # Create a throwaway test task with origin:interactive and confirm self-assign
    AIDEVOPS_SESSION_ORIGIN=interactive ./claim-task-id.sh --repo-path ~/Git/aidevops --title "tNNNN: test task for assignee race"
    # Expect output: "Auto-assigned @me to #NNNN (origin:interactive)"
    gh issue view NNNN --repo marcusquinn/aidevops --json assignees

    # Close the test issue and verify dedup doesn't re-match:
    gh issue close NNNN
    ./claim-task-id.sh --repo-path ~/Git/aidevops --title "tNNNN: test task for assignee race"
    # Expect: NO "Found existing issue #NNNN matching title" — new issue created
    ```

### Verification

```bash
shellcheck .agents/scripts/claim-task-id.sh
bash -n .agents/scripts/claim-task-id.sh   # syntax check

# Integration with real issue creation (cleanup after)
AIDEVOPS_SESSION_ORIGIN=interactive \
    .agents/scripts/claim-task-id.sh --repo-path ~/Git/aidevops --title "tTEST: dedup sanity" --dry-run
```

## Acceptance Criteria

- [ ] When `AIDEVOPS_SESSION_ORIGIN=interactive` (or `ORIGIN=interactive`) is set and `claim-task-id.sh` creates a new GitHub issue, the issue is assigned to `@me` immediately after creation. Verified via `gh issue view <num> --json assignees`.
- [ ] If self-assign fails (e.g., unauthenticated `gh`), the claim still succeeds and a warning is printed — the claim is not blocked.
- [ ] `claim-task-id.sh` dedup check does NOT match against closed issues. Verified by closing a test issue and re-claiming the same title: a new issue is created instead of re-linking to the closed one.
- [ ] Existing worker (non-interactive) flows are unchanged: no self-assign is attempted when origin is not interactive.

## Context & Decisions

- **Why detect origin via env var rather than a CLI flag:** the framework already propagates `AIDEVOPS_SESSION_ORIGIN` through headless and interactive dispatch paths. Reusing it keeps this fix consistent with the existing origin taxonomy. A `--origin` CLI flag is accepted as a fallback for direct invocation.
- **Why include the dedup fix in the same PR:** both edits are in the same file, both address friction in the same interactive claim flow, and splitting them buys no clarity. They're independent behaviours with independent acceptance criteria, so the PR remains small and auditable.
- **Why self-assign `@me` and not the repo maintainer:** `@me` resolves to whoever is running the CLI, which for interactive sessions is always the human operator. For worker dispatches (non-interactive), no self-assign is attempted, so assignment still goes through the normal maintainer-gate flow.

## Relevant Files

- `.agents/scripts/claim-task-id.sh` — the file to patch
- `.github/workflows/maintainer-gate.yml` — the gate that benefits (no change required)
- `.agents/scripts/issue-sync-helper.sh` — neighbouring helper, reference pattern for origin handling

## Dependencies

- **Blocked by:** none
- **Blocks:** none

## Estimate Breakdown

| Phase | Time | Notes |
|-------|------|-------|
| Research/read | 10m | Read the actual dedup and create paths in claim-task-id.sh |
| Implementation | 15m | 2 small patches |
| Testing | 10m | self-assign verify + closed-issue dedup verify |
| PR | 5m | |

**Total estimate:** ~40m
