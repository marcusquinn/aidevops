<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->
# t1980: claim-task-id dedup — use exact-title match instead of fuzzy substring search

## Origin

- **Created:** 2026-04-12
- **Session:** claude-code:interactive (follow-up from t1970)
- **Created by:** ai-interactive
- **Parent task:** t1970 (merged via PR #18374) — fixed `--state all → --state open`; this task tightens the match algorithm itself.
- **Conversation context:** When I claimed t1968 during this session with title `"setup.sh: auto-install privacy guard pre-push hook in every initialized repo"`, `claim-task-id.sh _check_duplicate_title` fuzzy-matched against the already-closed t1965 issue #18359 (`"t1965: feat: git pre-push hook to detect private repo slug leaks in TODO.md pushes to public repos"`) and recorded `ref=GH#18359` — a dead ref to a merged issue. The substring overlap on `"privacy guard pre-push hook"` was enough for GitHub's full-text search to rank it as a match.

## What

Change `claim-task-id.sh _check_duplicate_title` (line ~685) to perform **exact full-title match** instead of `gh issue list --search "$search_terms"` which uses GitHub's full-text relevance ranking. If the exact title match misses, fall back to the fuzzy search but require a secondary verification (e.g., title must start with `tNNN:` and the tNNN must match) before treating it as a duplicate.

Simpler variant that's probably correct for our use case: require the first `^t[0-9]+: ` prefix of the candidate issue's title to match the first `^t[0-9]+: ` prefix of the new claim. If we're claiming "t1968: setup.sh: auto-install privacy guard..." and an existing issue is "t1965: feat: git pre-push hook...", the prefixes differ (t1968 vs t1965) and no match. The dedup's purpose is to catch **the same task claimed twice**, not "issues with similar wording" — the task ID IS the uniqueness key.

## Why

t1970 tightened one half of the problem (don't match against closed issues). This task tightens the other half — don't match based on fuzzy content similarity at all. The two fixes together give us:

1. **Open issues only** (t1970) — closed/merged issues are stale, never re-link
2. **Exact task-ID match** (this task) — the dedup key is the task ID, not a bag of words

Without this tightening, a new task with a coincidentally-similar title to any existing open task will silently re-link to the wrong issue. Observed symptom (t1968 → #18359 before t1970 was merged): a dead ref in the claim output, an orphan TODO entry, and a later manual cleanup.

GitHub's `--search` query is optimised for humans searching issues, not for machine uniqueness checks. Using it for dedup is a category error.

## Tier

### Tier checklist

- [x] **2 or fewer files to modify?** — 1 (`claim-task-id.sh`)
- [x] **Complete code blocks for every edit?** — yes
- [x] **No judgment or design decisions?** — exact-match is the settled decision
- [x] **No error handling or fallback logic to design?** — no
- [x] **Estimate 1h or less?** — yes, ~30m
- [x] **4 or fewer acceptance criteria?** — 3

**Selected tier:** `tier:simple`

**Tier rationale:** Single-file surgical change with a fixed algorithm. The worker copies the block and verifies.

## How (Approach)

### Files to Modify

- `EDIT: .agents/scripts/claim-task-id.sh:676-696` — replace `_check_duplicate_title` body with exact-prefix match

### Implementation Steps

1. Read the current `_check_duplicate_title` function (around line 676):

    ```bash
    grep -n "_check_duplicate_title\|gh issue list.*search" .agents/scripts/claim-task-id.sh
    ```

2. Replace the body with an exact-prefix match. The new logic:
   - Derive `tNNN:` prefix from the claim's `$title` argument
   - Query `gh issue list --repo "$repo_slug" --state open --limit 500 --json number,title`
   - Iterate results client-side, matching exact `^tNNN: ` prefix
   - Return the matching issue number (and log) or nothing (caller creates new issue)

3. Example replacement:

    ```bash
    _check_duplicate_title() {
        local repo_slug="$1"
        local title="$2"
        local search_terms="$3"  # kept for API compat; ignored

        # Extract task ID prefix (e.g. "t1968" from "t1968: ...")
        local task_id_prefix
        task_id_prefix=$(printf '%s' "$title" | grep -oE '^t[0-9]+' || echo "")
        if [[ -z "$task_id_prefix" ]]; then
            # No tNNN prefix to match against — fall back to old behaviour
            # but ONLY if search_terms is substantial enough to be safe.
            if [[ ${#search_terms} -lt 10 ]]; then
                return 1
            fi
            local existing_issue
            existing_issue=$(gh issue list --repo "$repo_slug" \
                --state open --search "\"$search_terms\"" \
                --json number --limit 1 -q '.[0].number' 2>/dev/null || echo "")
            if [[ -n "$existing_issue" && "$existing_issue" != "null" ]]; then
                log_info "Found existing OPEN issue #$existing_issue matching title, skipping duplicate creation"
                echo "$existing_issue"
                return 0
            fi
            return 1
        fi

        # Exact tNNN: prefix match, case-sensitive
        local existing_issue
        existing_issue=$(gh issue list --repo "$repo_slug" \
            --state open --search "${task_id_prefix}: in:title" \
            --json number,title --limit 10 \
            -q ".[] | select(.title | startswith(\"${task_id_prefix}: \")) | .number" 2>/dev/null | head -1)

        if [[ -n "$existing_issue" && "$existing_issue" != "null" ]]; then
            log_info "Found existing OPEN issue #$existing_issue with exact ${task_id_prefix} prefix, skipping duplicate creation"
            echo "$existing_issue"
            return 0
        fi
        return 1
    }
    ```

4. Run `shellcheck .agents/scripts/claim-task-id.sh`.

5. Manual tests (all should run against a scratch branch/fork, not main):

    ```bash
    # 1. Same tNNN prefix → match
    # Create a test open issue titled "t9999: original", then try to claim
    # with title "t9999: updated" — should re-link to the existing issue.

    # 2. Different tNNN prefix, fuzzy-similar titles → no match
    # Existing open issue: "t9998: feat: foo bar baz"
    # New claim: "t9999: feat: foo bar baz" — should NOT match, new issue.

    # 3. Closed issue with exact tNNN prefix match → no match
    # Create + close a test issue "t9997: closed test", then claim "t9997:
    # revival". Should create a new issue (state:open filter excludes closed).
    ```

### Verification

```bash
shellcheck .agents/scripts/claim-task-id.sh
bash -n .agents/scripts/claim-task-id.sh   # syntax check

# Regression: re-run the failure scenario from this session
# (simulated via test fixture — see Implementation Step 5)
```

## Acceptance Criteria

- [ ] A new claim with title `"tNNNN: some description"` matches ONLY against open issues whose title starts with `"tNNNN: "` exactly. Fuzzy content matches on other tMMMM: prefixes are not treated as duplicates.
- [ ] A new claim without a `tNNNN:` prefix (e.g. GH#-style claims) falls back to the previous substring search behaviour (kept for back-compat).
- [ ] `shellcheck` clean; existing claim-task-id tests (if any) still pass.

## Context & Decisions

- **Why not drop the fuzzy fallback entirely:** some callers invoke claim-task-id without a `tNNN:` prefix — GitHub-only tasks use `GH#NNN:` or bare title (see `reference/task-taxonomy.md`). Keeping the fallback for prefix-less claims preserves back-compat without re-introducing the fuzzy-match hazard for the common case.
- **Why client-side filtering (`startswith`) instead of server-side search:** `gh issue list --search` uses GitHub's full-text relevance ranking which is exactly what got us into trouble. `startswith` is a string operation on the returned JSON — zero ambiguity.
- **Why `--limit 10`:** exact prefix match should return 0 or 1 result. 10 gives headroom for unusual cases (label-rename noise, GitHub search re-ranking) without over-fetching.
- **Why keep the `search:` query string even for exact match:** the `--search "tNNNN: in:title"` narrows the server-side result set so we don't transfer 500 issues over the wire on every claim.

## Relevant Files

- `.agents/scripts/claim-task-id.sh:676-696` — `_check_duplicate_title`
- `.agents/scripts/issue-sync-helper.sh` — uses a similar `gh_find_issue_by_title` helper; worth auditing for the same fuzzy-match hazard as a follow-up (not in this PR's scope)
- Evidence: conversation transcript from this session showing the t1968 → #18359 false match

## Dependencies

- **Blocked by:** t1970 (merged)
- **Blocks:** none
- **External:** none

## Estimate Breakdown

| Phase | Time | Notes |
|-------|------|-------|
| Research/read | 5m | Done (this session) |
| Implementation | 15m | Single-function rewrite |
| Testing | 10m | 3 manual scenarios |
| PR | 5m | |

**Total estimate:** ~35m
