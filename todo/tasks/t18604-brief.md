## Origin

- **Created:** 2026-10-06, interactive throughput review (maintainer session); maintainer proposal
- **Depends on:** t18603 / GH#33844 (conditional 304s must work before "nothing changed" signals can be trusted)
- blocked-by: t18603

## What

Pulse stops scanning repos that have no dispatchable work on every pass. A repo whose only open issues are persistent, non-dispatchable ones (reporting, parent and held issues) enters a **dormant** state and is skipped for candidate discovery and prefetch. It wakes only on an explicit signal: new or relabelled issues/PRs, a push to its planning files, or an interactive session starting or claiming work in it.

## Why

Most managed repos are not under active development; many hold only persistent reporting issues. Today every enabled repo is rechecked on a timer:

- `pulse-prefetch-orchestration.sh:517-570` `check_repo_tier_skip` gates only the prefetch stage (`pulse-prefetch-repo.sh:397`). Tiers come from `pulse-repo-tier.sh` (7-day GitHub event counts: hot ≥30, warm ≥5, cold <5) and the longest skip is `PULSE_TIER_COLD_INTERVAL=600`s (`pulse-wrapper-config.sh:243-246`). An event-quiet repo with no dispatchable work is still refetched every ~10 minutes, indefinitely.
- Tier reflects event volume, not whether dispatchable candidates exist. A busy repo with only reporting-issue churn stays hot; a quiet repo with one new `auto-dispatch` issue waits for its cold interval.
- `pulse-events-tickle.sh` keeps one ETag per **owner**, so any event anywhere under an owner marks all its repos stale.
- `interactive-session-helper.sh` and `interactive-start-helper.sh` emit no wake signal.

## Tier

`tier:thinking` — new scheduling state with cross-stage correctness constraints; a missed wake causes silent starvation.

## How (Approach)

### Verify first (findings decide the design)

1. Map which pulse stages enumerate repos: prefetch (`pulse-prefetch-repo.sh`, `pulse-batch-prefetch-helper.sh`), candidate discovery/dispatch fill, stale-PR/checkpoint continuation and sweeps. Record which stages would be gated by dormancy and which must keep running (open PRs, active workers, checkpoint recovery, CI repair must never sleep).
2. Define "no dispatchable work" from existing dispatch eligibility (labels such as `auto-dispatch`, `status:available`, `parent-task`, hold labels), reusing the existing predicate rather than inventing a second one.
3. Confirm which per-repo change signal is cheapest: per-repo events or issues `since=` with an ETag (after t18603) versus the owner-level tickle.

### Expected shape (adjust to findings)

- Dormancy state per repo with reason and entry time (for example alongside `~/.aidevops/cache/pulse-repo-tiers.json` or `pulse-tier-last-check.json`), entered when a full scan finds zero dispatchable candidates, zero open worker PRs and no active claims.
- Wake triggers: (a) per-repo conditional change detection returns 200; (b) `interactive-session-helper.sh claim` / `interactive-start-helper.sh` write a wake marker for the repo; (c) issue-sync / TODO.md publication for that repo writes the same marker.
- Safety net: a long backstop interval (configurable, e.g. 6h) still forces a scan, so a missed wake degrades latency, never correctness.
- Observability: health counters for dormant, woken-by-reason and backstop scans; a log line when a repo enters or leaves dormancy.
- Rollback flag, default on only after the backstop and wake markers are verified.

### Non-goals

- Do not enable, disable or edit `pulse`/`pulse_enabled` flags in `repos.json`; disabled repos stay disabled.
- Do not change the hot/warm/cold classifier thresholds.

Further candidate-discovery files are not yet knowable; verify-first step 1 determines them, and the PR must list them.

### Files Scope

- `.agents/scripts/pulse-prefetch-orchestration.sh`
- `.agents/scripts/pulse-prefetch-repo.sh`
- `.agents/scripts/pulse-repo-tier.sh`
- `.agents/scripts/pulse-wrapper-config.sh`
- `.agents/scripts/interactive-session-helper.sh`
- `.agents/scripts/interactive-start-helper.sh`
- `.agents/scripts/tests/test-pulse-repo-tier.sh`

### Verification

```bash
bash .agents/scripts/tests/test-pulse-repo-tier.sh
shellcheck .agents/scripts/pulse-prefetch-orchestration.sh .agents/scripts/pulse-repo-tier.sh
```

Runtime: after deploy, pulse logs show repos entering dormancy and being skipped. Creating an `auto-dispatch` issue in a dormant repo, or starting an interactive session there, wakes it on the next cycle.

- **Broad verification trigger:** Not required.

## Acceptance Criteria

- [ ] A repo with only non-dispatchable open issues, no open worker PRs and no active claims is skipped by prefetch and candidate discovery after one full scan.
- [ ] A new dispatchable issue, a planning publication, or an interactive claim/start wakes it within one pulse cycle.
- [ ] Repos with open PRs, active workers or checkpoint recovery are never dormant.
- [ ] Backstop scan runs at the configured interval; health and logs expose dormant and woken counts.
- [ ] Rollback flag disables dormancy completely.
