---
mode: subagent
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->
# t2180: feat(claim-task-id): pre-claim discovery pass — warn on similar in-flight or recently-merged work

## Origin

- **Created:** 2026-04-18
- **Session:** opencode:interactive
- **Created by:** marcusquinn (ai-interactive)
- **Conversation context:** While clearing stuck PRs, found PR #19494 (t2167 video-seo) was a duplicate of PR #19495 — same task, shipped a day earlier. PR #19494 had been opened in parallel without checking whether t2167's work was already in flight or merged. The branch went DIRTY on rebase (add/add conflict on three SEO agent files), and the PR had to be closed as superseded. The t2046 pre-implementation discovery rule (`prompts/build.txt`) exists exactly to catch this, but it fires at implementation time — too late if the brief and worktree are already created.

## What

Extend `claim-task-id.sh` to run a pre-claim discovery pass that:

1. Extracts 3-5 keyword stems from the `--title` argument (drop common words: `feat`, `fix`, `chore`, `add`, `the`, `for`, etc.)
2. Runs `gh pr list --repo <slug> --state all --search "<keywords>" --limit 5` to surface PRs (open OR recently merged within last 14 days) that match
3. If hits surface AND we are in an interactive TTY:
    - Print up to 3 hits with title, number, state, and merge date
    - Prompt: "Continue claiming this ID anyway? [y/N]"
    - Default N — caller must explicitly continue
4. If hits surface AND we are NOT in a TTY (worker / pulse / CI):
    - Print a structured warning to stderr (machine-readable: `[claim-task-id] WARN: similar PR found: #N <title> <state>`)
    - Continue anyway (workers can't answer prompts; the warning is for the audit log)
5. If no hits, behave as today — silent fast-path

This complements t2046, which runs a similar check at implementation time. t2046 catches duplicates AFTER the brief and worktree exist (waste already incurred); this catches them BEFORE any of that work is done.

## Why

PR #19494 (t2167) cost: brief written, worktree created, 3 commits pushed, CI ran on each, GitHub issue opened, then closed as duplicate. Total ~30 minutes of session time + ~10 CI workflow runs. A 2-second `gh pr list --search` at claim time would have surfaced PR #19495 (already merged) and let the maintainer say "oh, that's already done — what was I thinking" before any waste.

This is not a one-off. The framework dispatches dozens of tasks per day across pulse + interactive + worker sessions; duplicate-detection at claim time scales linearly with the dispatch rate. The cost ratio is asymmetric: ~1 second of `gh` latency per claim vs ~30 minutes of waste per duplicate. Even at a 1-in-100 duplicate rate, the check pays for itself.

The t2046 rule (in `prompts/build.txt`) exists and is correct, but agents (and humans) skip it when momentum is high. Putting the check in the tool that allocates IDs makes it unmissable — the warning is structural, not advisory.

Doing nothing means we keep losing ~30 min per duplicate task, plus the user has to manually close the duplicate PR, plus the next agent re-learns the lesson the slow way. Filing this as `#auto-dispatch` so a worker picks it up.

## Tier

### Tier checklist (verify before assigning)

- [x] **2 or fewer files to modify?** (claim-task-id.sh + test = 2)
- [x] **Every target file under 500 lines?** (claim-task-id.sh ~400 lines)
- [ ] **Exact `oldString`/`newString` for every edit?** (helper needs design — keyword extraction logic, prompt UX)
- [ ] **No judgment or design decisions?** (decide what counts as "similar" — keyword overlap threshold, time window for "recent")
- [ ] **No error handling or fallback logic to design?** (offline gh, rate-limited gh, malformed search results)
- [x] **No cross-package or cross-module changes?**
- [x] **Estimate 1h or less?** (~1.5-2h)
- [x] **4 or fewer acceptance criteria?** (5 — borderline)

**Selected tier:** `tier:standard`

**Tier rationale:** Three checklist failures: keyword extraction needs design (stop-word list, stemming heuristic), TTY-vs-worker UX branches differ, and offline-gh fallback path needs care. Pattern is novel (no existing pre-claim discovery elsewhere in the framework) but constrained — `gh pr list --search` is the obvious primitive. Sonnet handles this; Opus is overkill.

## PR Conventions

Leaf task. PR body: `Resolves #19638`.

## How (Approach)

### Worker Quick-Start

- Read: `.agents/scripts/claim-task-id.sh` (whole file, ~400 lines) — the entry point and the `_create_github_issue` helper are the integration sites
- Pattern reference for similar workflow: `.agents/scripts/issue-sync-helper.sh` `_check_dedup_against_existing` (if it exists; otherwise the broader issue-sync dedup logic for inspiration)
- t2046 rule text: `.agents/prompts/build.txt` "Pre-implementation discovery (t2046)" — same checks, run earlier
- TTY detection idiom in framework: `[[ -t 0 ]] && [[ -t 1 ]]` (interactive)

### Files to Modify

- **EDIT:** `.agents/scripts/claim-task-id.sh` — add `_pre_claim_discovery_pass` helper, call it from main flow before `_atomic_claim_id`
- **NEW:** `.agents/scripts/tests/test-claim-task-id-discovery.sh` — model on `test-claim-task-id-*.sh` if any exist; otherwise on `test-issue-sync-helper.sh`

### Implementation Steps

1. **Add helper `_pre_claim_discovery_pass` to `claim-task-id.sh`:**
    - Args: `title`, `repo_slug`
    - Steps:
        - Extract keywords: tokenize title on whitespace + non-word chars, lowercase, drop stop words (`feat`, `fix`, `chore`, `add`, `update`, `the`, `for`, `to`, `a`, `an`, `with`, `from`, `into`, `via`)
        - Take top 3-5 longest tokens (longer = more discriminating)
        - Build search query: `keyword1 OR keyword2 OR keyword3` (gh search syntax)
        - Run `gh pr list --repo "$repo_slug" --state all --search "$query" --limit 5 --json number,title,state,mergedAt,createdAt`
        - Filter hits: keep those whose title shares >= 2 keywords with our title (rough relevance gate)
        - Filter by recency: open PRs always relevant; merged PRs only if `mergedAt` within last 14 days
    - Returns list of relevant hits (or empty)
2. **Wire into main flow:**
    - After `--title` is validated and before `_atomic_claim_id` runs
    - Skip if `--no-issue` (we're not creating an issue, no duplicate risk)
    - Skip if `--offline` or `gh` unauthenticated (fail-open)
3. **Interactive UX (`[[ -t 0 ]] && [[ -t 1 ]]` true):**
    - Print: "⚠ Found N similar PR(s) — please check before claiming a new task ID:"
    - Print each hit: `  • #N <state> <title>  (<merged|opened> YYYY-MM-DD)`
    - Print: "Continue claiming a new ID? [y/N]: "
    - Read 1 char; default N. If N, exit 10 (new exit code: "user declined claim after dedup warning")
    - If Y, continue to atomic claim
4. **Non-interactive UX (workers, pulse, CI):**
    - Print structured warnings to stderr: `[claim-task-id] WARN: similar PR found: #19495 MERGED 2026-04-17 — t2167: add video-seo, transcript-seo, video-schema agents`
    - One line per hit (max 3)
    - Continue to atomic claim regardless (workers can't answer prompts; the audit log is the deterrent)
5. **Tests (`test-claim-task-id-discovery.sh`):**
    - Mock `gh` via PATH shim, return fixture JSON
    - Case A: no hits → no warning, no prompt, normal claim
    - Case B: hits + interactive + user answers `n` → exit 10, no claim made
    - Case C: hits + interactive + user answers `y` → claim proceeds
    - Case D: hits + non-interactive → warnings to stderr, claim proceeds
    - Case E: gh offline → fail-open, no warnings, normal claim

### Verification

- `bash .agents/scripts/tests/test-claim-task-id-discovery.sh` — all 5 cases pass
- `shellcheck .agents/scripts/claim-task-id.sh` — zero new violations
- Manual smoke: `claim-task-id.sh --title "fix CodeRabbit nit dismiss" --dry-run` — should warn about t2179 if it's still open or recently merged
- Backward compat smoke: `claim-task-id.sh --no-issue --title "anything"` — no discovery pass, behaves identically to today

## Acceptance Criteria

- [ ] Discovery pass runs by default before atomic claim, skipped on `--no-issue`, `--offline`, or unauthenticated `gh`
- [ ] Interactive TTY: hits surface as a numbered list + Y/N prompt with default N; declined → exit code 10
- [ ] Non-interactive: hits print as structured stderr warnings; claim proceeds (workers can't answer prompts)
- [ ] Recency filter: merged PRs older than 14 days are dropped (configurable via env: `AIDEVOPS_CLAIM_DEDUP_DAYS=14`)
- [ ] Test harness covers no-hits / hits+interactive-Y / hits+interactive-N / hits+non-interactive / offline-gh
- [ ] Backwards compatible: existing scripts that pipe input to `claim-task-id.sh` see no behavioural change (the prompt only fires on real TTY)

## Context

- Sibling rule that this enforces structurally: `prompts/build.txt` "Pre-implementation discovery (t2046)" — a textual rule that agents skip under momentum. This task moves the rule from advisory text into the tool that allocates IDs, where it can't be skipped.
- Concrete evidence: PR #19494 closed 2026-04-18 as duplicate of merged PR #19495. Both for t2167. ~30 min of session waste + 10 CI runs.
- Adjacent helper: `gh pr list --search` is GitHub's text-search API; not full-text but good enough for keyword overlap.
- Out of scope: cross-repo discovery (search only the target repo). Cross-repo duplicate-detection is a harder problem, file separately if it surfaces.
