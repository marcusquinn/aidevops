# t2030: Refactor pulse prefetch to use org-level GitHub search

## Session Origin
Interactive session 2026-04-07. User reported pulse exhausting GitHub API rate limit ("API rate limit already exceeded" on `gh repo list`). 46 `Ultimate-Multisite/*` repos (plus others) each cause per-repo `gh issue list`/`gh pr list` calls every pulse cycle. Stopgap applied: `pulse_hours: {start:3, end:5}` on all UM repos to shrink the cycle window. This task is the proper fix.

## What
Replace per-repo prefetch/scan calls in `.agents/scripts/pulse-wrapper.sh` with one org-level (or global) `gh search issues` / `gh search prs` call per category, then group results by `repository.nameWithOwner` in jq and distribute to the existing per-slug cache structures. Target ~10–20x reduction in `gh` calls per cycle.

## Why
- 46+ pulse-enabled repos × multiple prefetch functions per cycle = hundreds of API calls per pulse run.
- GitHub REST has a 5000 req/hr cap; we're exhausting it during normal operation.
- `gh search issues --owner ORG --state open --json ...` returns all matching issues in one call — same data, fraction of the cost.
- Per-issue/per-PR mutations (edit, comment, merge, labels) and `gh api .../timeline` calls must stay per-repo — they have no org-level equivalent. The win is purely in the scan/prefetch phase.

## How

### Files to modify
- **EDIT**: `.agents/scripts/pulse-wrapper.sh` — functions to convert to org-level prefetch:
  - `_prefetch_repo_prs` (~line 989)
  - `_prefetch_repo_issues` (~line 1170)
  - `_prefetch_repo_daily_cap` (~line 1038)
  - `prefetch_triage_review_status` (~line 3630) — `needs-maintainer-review` label scan
  - `prefetch_needs_info_replies` (~line 3737) — `status:needs-info` label scan
  - `_fetch_queue_metrics` (~line 7321, 7336)
  - `count_runnable_candidates` (~line 7735)
  - `count_queued_without_worker` (~line 7776)
  - Debt counters (~line 11084-11096) — `quality-debt`, `simplification-debt`
- **KEEP UNCHANGED** (cannot use org search): all `gh issue edit/comment/close`, `gh pr edit/comment/merge/close`, `gh pr view --json files/comments`, `gh api .../timeline`, `gh api .../comments --paginate`.

### Pattern to follow
Group pulse-enabled repos by org owner (from `~/.config/aidevops/repos.json` `slug` field), then for each owner run:
```
gh search issues --owner "$owner" --state open --limit 1000 \
  --json number,title,labels,assignees,repository,updatedAt,url
```
Cache result keyed by `${owner}:${category}`, then for each repo slug filter via jq:
```
jq --arg slug "$slug" '[.[] | select(.repository.nameWithOwner == $slug)]'
```
Write to the same per-slug cache files the existing prefetch functions populate, so downstream code is unchanged.

For label-filtered scans, add `--label` flags to `gh search issues`. For global/cross-org scans (e.g., FOSS contribution watchers), use `gh search issues --involves @me` or similar.

Handle single-repo case (non-org solo repos) by falling back to the existing per-repo `gh issue list` path — don't force org search when there's only one repo for an owner.

### Verification
1. Dry-run: `bash .agents/scripts/pulse-wrapper.sh --dry-run` (if supported) or run pulse manually and inspect `~/.aidevops/logs/pulse.log` for `gh issue list`/`gh pr list` call counts before and after.
2. Count API calls per cycle: `grep -c "^\[pulse-wrapper\].*gh (issue|pr) list" $LOGFILE` should drop ~10x.
3. Functional: confirm dispatched tasks, triage replies, and queue metrics still work across at least 3 repos on next pulse cycle.
4. Rate limit check: `gh api rate_limit` after a full cycle — remaining budget should be markedly higher.

### Rollout
- Implement behind a feature flag `PULSE_ORG_SEARCH_ENABLED=1` initially.
- Test on one org (e.g., Ultimate-Multisite) before enabling globally.
- Once proven, remove flag and old per-repo code paths.

## Acceptance Criteria
- [ ] `gh issue list --repo` / `gh pr list --repo` calls per pulse cycle reduced by ≥10x
- [ ] All existing prefetch cache files still populated correctly for every pulse-enabled repo
- [ ] No regression in dispatch, triage, needs-info, queue metrics, or debt counters
- [ ] Stopgap `pulse_hours: {3,5}` can be removed from UM repos afterward
- [ ] `gh api rate_limit` shows significantly higher remaining budget post-cycle
- [ ] Verification commands documented in PR description with before/after call counts

## Context
- Stopgap commit in `~/.config/aidevops/repos.json` (backup at `repos.json.bak-*`)
- Rate limit hit observed 2026-04-07 on `gh repo list Ultimate-Multisite`
- Related: pulse-wrapper.sh is ~11K lines; this refactor touches ~10 functions, not the mutation-heavy code paths
