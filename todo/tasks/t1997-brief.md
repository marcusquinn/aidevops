---
mode: subagent
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->
# t1997: tier-label collision: dedup multiple `tier:*` labels via GitHub Action + worker fallback to highest tier

## Origin

- **Created:** 2026-04-12
- **Session:** claude-code:interactive
- **Created by:** marcusquinn (human) via ai-interactive
- **Parent task:** none
- **Conversation context:** While retagging t1993 (#18420) for worker dispatch, the issue ended up with both `tier:simple` AND `tier:standard` labels simultaneously. The user's response: "I think workers should use the highest tier label already, but maybe a github action can clean that up?". This task implements the GitHub Action as the primary cleanup mechanism plus a defensive worker-side fallback that picks the highest tier when multiple are present.

## What

Two complementary fixes for the tier-label collision class of bug:

1. **GitHub Action (primary fix)**: a workflow that fires on `issues.labeled` events, detects when an issue carries more than one `tier:*` label, removes all but the highest, and posts an explanatory comment. This eliminates the collision at source.
2. **Worker dispatcher (defensive fallback)**: when reading tier labels for routing, prefer the highest-rank tier present (`tier:reasoning` > `tier:standard` > `tier:simple`) instead of failing or picking arbitrarily. This catches any race window between the collision and the Action's cleanup, plus any historical issues with stale collisions.

The GitHub Action is the canonical cleanup. The worker fallback is a belt-and-braces guarantee that the dispatcher never crashes or mis-tiers because of the collision.

## Why

Concrete repro from this session: issue #18420 (t1993) was filed with `tier:simple`, then via `gh issue edit ... --add-label "auto-dispatch"`, then issue-sync ran on a TODO push that added the `pulse` tag. By the time the pulse claimed it at 21:08:35Z, the issue carried both `tier:simple` AND `tier:standard` per the timeline:

```text
20:58:00Z labeled tier:simple
21:03:26Z labeled tier:standard
```

The `tier:standard` was added by an automatic process — most likely either:

- The issue-sync workflow merging tier indications from both the TODO entry (`tier:simple`) and the brief content (the brief's tier-checklist shows the disqualifier list, which mentions `tier:standard`), or
- An auto-classifier that read the brief and concluded "this is non-trivial" without checking whether a tier label already existed.

Either way, the result is an issue with two contradictory tier labels, which breaks the canonical "one tier per issue" invariant the dispatch logic relies on. Today the dispatcher silently picks one (in this case it dispatched at Sonnet which is `tier:standard` — the higher tier). The user's framing is: that defaulting behaviour should be explicit, AND the collision should be auto-cleaned at source.

This is a low-severity but irritating class of bug. It causes:

- Confusion when reviewing issues (which tier is the worker actually using?)
- Potential mis-dispatch if the dispatcher's tier selection logic ever changes (today it might pick "highest" by accident; tomorrow it might pick "first encountered" and quietly use Haiku for a Sonnet task)
- Pollution of the tier label set as the source of truth

## Tier

### Tier checklist (verify before assigning)

- [x] **2 or fewer files to modify?** → yes (new workflow file + one dispatcher edit + tests = arguably 3, but the workflow is self-contained)
- [x] **Complete code blocks for every edit?** → yes, both pieces have copy-pasteable skeletons below
- [x] **No judgment or design decisions?** → yes (rank order is deterministic: reasoning > standard > simple)
- [x] **No error handling or fallback logic to design?** → yes (workflow has trivial error handling; dispatcher falls back to standard if no tier is present)
- [x] **Estimate 1h or less?** → yes (~45m)
- [x] **4 or fewer acceptance criteria?** → yes (4 criteria)

**Selected tier:** `tier:simple`

**Tier rationale:** Mechanical implementation of a deterministic rank order. Workflow is a small jq + gh CLI script. Dispatcher edit is a one-line change to use the highest tier. No design judgment. Haiku-friendly.

## How (Approach)

### Files to Modify

- `NEW: .github/workflows/dedup-tier-labels.yml` — GitHub Action workflow that fires on `issues.labeled`, dedupes `tier:*` labels.
- `EDIT: .agents/scripts/pulse-dispatch-core.sh` (or wherever tier extraction happens — search for `tier:simple|tier:standard|tier:reasoning`) — when multiple tier labels are present on the same issue, pick the highest by rank order.
- `NEW: .agents/scripts/tests/test-tier-label-dedup.sh` — assert the rank-order extraction.

### Implementation Steps

1. **Workflow file** at `.github/workflows/dedup-tier-labels.yml`:

   ```yaml
   name: Dedup tier:* labels

   on:
     issues:
       types: [labeled]
     pull_request_target:
       types: [labeled]

   permissions:
     issues: write
     pull-requests: write

   jobs:
     dedup:
       if: startsWith(github.event.label.name, 'tier:')
       runs-on: ubuntu-latest
       steps:
         - name: Dedup tier labels (keep highest)
           env:
             GH_TOKEN: ${{ secrets.GITHUB_TOKEN }}
             TARGET_NUMBER: ${{ github.event.issue.number || github.event.pull_request.number }}
             REPO: ${{ github.repository }}
             KIND: ${{ github.event.issue && 'issue' || 'pr' }}
           run: |
             set -euo pipefail

             # Rank order — index in the array is the rank (highest first)
             RANK=("tier:reasoning" "tier:standard" "tier:simple")

             # Fetch current tier labels on the target
             current=$(gh "${KIND}" view "$TARGET_NUMBER" --repo "$REPO" \
               --json labels --jq '[.labels[].name | select(startswith("tier:"))]')

             count=$(printf '%s' "$current" | jq 'length')
             if [[ "$count" -lt 2 ]]; then
               echo "Only ${count} tier label(s) present — nothing to dedup"
               exit 0
             fi

             # Find the highest-ranked label currently present
             keep=""
             for tier in "${RANK[@]}"; do
               if printf '%s' "$current" | jq -e --arg t "$tier" 'index($t) != null' >/dev/null; then
                 keep="$tier"
                 break
               fi
             done

             if [[ -z "$keep" ]]; then
               echo "No known tier label present — nothing to keep"
               exit 0
             fi

             # Remove every tier label except the highest
             removed=()
             while IFS= read -r tier; do
               if [[ "$tier" != "$keep" ]]; then
                 gh "${KIND}" edit "$TARGET_NUMBER" --repo "$REPO" --remove-label "$tier"
                 removed+=("$tier")
               fi
             done < <(printf '%s' "$current" | jq -r '.[]')

             # Post an explanatory comment (idempotent — only if anything changed)
             if [[ "${#removed[@]}" -gt 0 ]]; then
               removed_csv=$(IFS=,; printf '%s' "${removed[*]}")
               gh "${KIND}" comment "$TARGET_NUMBER" --repo "$REPO" --body "## Tier label dedup (t1997)

   Detected multiple \`tier:*\` labels on this ${KIND}. Kept the highest-ranked label (\`${keep}\`) and removed: \`${removed_csv}\`.

   Rank order: \`tier:reasoning\` > \`tier:standard\` > \`tier:simple\`.

   _Auto-cleaned by \`.github/workflows/dedup-tier-labels.yml\`_"
             fi
   ```

2. **Worker dispatcher fallback** — find the place that extracts tier from labels. Search:

   ```bash
   rg -n '"tier:simple"|"tier:standard"|"tier:reasoning"' .agents/scripts/pulse-*.sh | head -20
   ```

   Wherever the dispatcher reads "the tier label", replace single-label extraction with rank-order extraction. Skeleton:

   ```bash
   # Resolve the worker tier from issue labels. When multiple tier:* labels
   # are present (collision — see t1997), pick the highest rank order.
   # Fallback: tier:standard if no tier label is present.
   _resolve_worker_tier() {
       local labels_csv="$1"
       local labels_lower=",${labels_csv,,},"
       if [[ "$labels_lower" == *",tier:reasoning,"* ]]; then
           printf 'tier:reasoning'
       elif [[ "$labels_lower" == *",tier:standard,"* ]]; then
           printf 'tier:standard'
       elif [[ "$labels_lower" == *",tier:simple,"* ]]; then
           printf 'tier:simple'
       else
           printf 'tier:standard'  # default when no tier label present
       fi
       return 0
   }
   ```

   Wire `_resolve_worker_tier` into wherever the dispatcher currently reads `.labels[] | select(startswith("tier:"))`. The behaviour should be: a single tier label still resolves correctly; multiple tier labels resolve to the highest; no tier labels resolve to `tier:standard`.

3. **Test** at `.agents/scripts/tests/test-tier-label-dedup.sh`:

   ```bash
   #!/usr/bin/env bash
   set -euo pipefail

   SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
   # Source the dispatcher (or extract _resolve_worker_tier into a small lib)
   # Then assert:
   #   _resolve_worker_tier "bug,tier:simple"               → tier:simple
   #   _resolve_worker_tier "bug,tier:standard,tier:simple" → tier:standard
   #   _resolve_worker_tier "tier:reasoning,tier:simple"    → tier:reasoning
   #   _resolve_worker_tier "tier:standard,tier:reasoning"  → tier:reasoning (order independence)
   #   _resolve_worker_tier "bug,auto-dispatch"             → tier:standard (default)
   #   _resolve_worker_tier "TIER:STANDARD"                 → tier:standard (case insensitive)
   ```

4. **Manual smoke test of the workflow**: trigger the action by adding a redundant tier label to a test issue (e.g., add `tier:simple` to an issue that already has `tier:standard`). The workflow should fire, remove the lower tier, and post a comment.

### Verification

```bash
# Static checks
shellcheck .agents/scripts/tests/test-tier-label-dedup.sh
shellcheck .agents/scripts/pulse-dispatch-core.sh  # or whichever file got the dispatcher edit

# Workflow lint (if actionlint installed)
actionlint .github/workflows/dedup-tier-labels.yml 2>/dev/null || true

# Unit test
bash .agents/scripts/tests/test-tier-label-dedup.sh

# Manual smoke (in a sandbox issue)
gh issue create --repo marcusquinn/aidevops --title "test: tier dedup" --label "tier:standard,tier:simple"
# Expect the workflow to fire, remove tier:simple, and post the dedup comment
```

## Acceptance Criteria

- [ ] `.github/workflows/dedup-tier-labels.yml` exists, fires on `issues.labeled` and `pull_request_target.labeled`, removes lower-ranked `tier:*` labels keeping only the highest, and posts an explanatory comment.
  ```yaml
  verify:
    method: codebase
    pattern: "Dedup tier:\\* labels"
    path: ".github/workflows/dedup-tier-labels.yml"
  ```
- [ ] `_resolve_worker_tier` (or equivalent) exists in the dispatcher and resolves multi-tier-label issues to the highest rank.
  ```yaml
  verify:
    method: codebase
    pattern: "_resolve_worker_tier|highest.*tier"
    path: ".agents/scripts/pulse-dispatch-core.sh"
  ```
- [ ] Regression test `test-tier-label-dedup.sh` passes with at least 5 assertions covering single tier, double tier, triple tier, no tier, and case-insensitive matching.
  ```yaml
  verify:
    method: bash
    run: "bash .agents/scripts/tests/test-tier-label-dedup.sh"
  ```
- [ ] `shellcheck` clean on all touched scripts; `actionlint` clean on the new workflow if installed.
  ```yaml
  verify:
    method: bash
    run: "shellcheck .agents/scripts/tests/test-tier-label-dedup.sh"
  ```

## Context & Decisions

- **Why both fixes (Action + dispatcher fallback) instead of one:** the Action takes a few seconds to fire after a label event; if the pulse claims an issue during that race window, it would still see the collision. The dispatcher fallback closes the race. Conversely, the Action prevents historical pollution from accumulating — without it, issues touched once with a stale collision would carry the duplicate forever.
- **Why this rank order:** `tier:reasoning` > `tier:standard` > `tier:simple` matches the model capability hierarchy (Opus > Sonnet > Haiku). Picking the highest is always a safe default — running an Opus-tier task on Sonnet might fail, but running a Haiku task on Sonnet just costs a bit more.
- **Why default to `tier:standard` when no tier label is present:** this is the existing convention from `AGENTS.md` "Use when uncertain. This is the default tier."
- **Workflow uses `pull_request_target` not `pull_request`:** because the dedup needs write permissions on the PR labels and `pull_request` from forks doesn't get write access. `pull_request_target` runs in the base repo context with write permissions.
- **Ruled out:**
  - *Removing the tier-collision source (the auto-classifier or issue-sync rule that adds the second tier)* — better long-term but requires identifying and patching the source. The Action is a defence in depth that catches all sources, including future ones we haven't identified.
  - *Failing the dispatch when multiple tier labels are detected* — defensive but disruptive; user explicitly said "workers should use the highest tier label already", indicating prefer-to-resolve over fail.

## Relevant Files

- `.agents/scripts/pulse-dispatch-core.sh` — dispatcher that reads tier labels (search for `tier:` literal strings to find the exact site)
- `.github/workflows/` — directory for the new workflow
- Concrete repro: issue #18420 (t1993) timeline showing the collision was added by `issue-sync` workflow
- `AGENTS.md` "Briefs, Tiers, and Dispatchability" — documents the tier system

## Dependencies

- **Blocked by:** none
- **Blocks:** none directly; cleanup task that improves dispatch hygiene
- **External:** GitHub Actions runner availability (standard ubuntu-latest)

## Estimate Breakdown

| Phase | Time | Notes |
|-------|------|-------|
| Write workflow file | 15m | YAML + bash, mechanical |
| Find dispatcher tier-extraction site + add `_resolve_worker_tier` | 15m | rg-driven |
| Write regression test | 10m | 5+ assertions |
| Manual smoke test in sandbox | 5m | Optional but verifies workflow |
| Shellcheck + actionlint + commit | 5m | |
| **Total** | **~50m** | |
