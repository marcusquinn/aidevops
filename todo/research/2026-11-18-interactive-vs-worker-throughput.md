<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Interactive full-loop vs pulse workers: solve throughput (2026-11-18)

Question: interactive sessions asked to "solve this full-loop" seem to close
issues faster than pulse workers. Should pulse/workers be simplified?

Evidence is GitHub search counts (`is:issue is:closed reason:completed`, split by
`solved:worker` / `solved:interactive`) plus the timelines of the slow
interactive solves. "Product repo" is a large private managed repository. Its
name is withheld.

## Weekly solves (closed as completed)

| Week ending | framework worker | framework interactive | framework issues created interactively | product worker | product interactive | product issues created by workers |
|---|---|---|---|---|---|---|
| 10-28 | 147 | 54 | 126 | 505 | 56 | 1002 |
| 11-04 | 219 | 124 | 264 | 356 | 95 | 615 |
| 11-11 | 345 | 134 | 346 | 520 | 174 | 560 |
| 11-18 | 331 | 215 | 470 | 1496 | 91 | 2188 |

- Workers solve more than interactive sessions in both repos every week. The
  product repo's worker output nearly tripled in the last week.
- Interactive solves are rising in the framework repo because interactive
  sessions now create most of its issues (470 last week) and solve their own
  filings in the same session (median close 1.1h). They solve work they have
  just discovered, while its context is loaded. They are not competing with
  workers for the existing backlog.
- One new framework issue was worker-dispatched about 90s after filing on
  2026-11-18. This is a single observation, not a dispatch-latency distribution
  for the wider backlog.

## Where interactive sessions really rescued work

Only 16 of 215 interactive solves in the week waited more than 12h:

- 7 were external-contributor reports held by the creation-time trust gate
  (`needs-maintainer-review`, `.github/workflows/issue-triage-gate-reusable.yml`
  lines ~112-150) with zero worker dispatches. They waited overnight until a
  maintainer reviewed them in a batch, then were solved within about an hour.
  In the last 30 days one repeat reporter filed 44 issues: 39 solved
  interactively, 2 by workers, 1 not planned, none still open. The gate exempts
  only OWNER/MEMBER, bots and write+ collaborators, so a consistently accurate
  read-only reporter pays the full review latency on every issue.
- 2 were long-stale worker issues (1730h and 2636h old) cleared in interactive
  backlog sweeps.
- The rest were single cases: a runner capability outage (fixed by GH#38966 and
  guarded by GH#38977), source-access holds, one review hold.

## Product-repo blocked backlog

354 open `status:blocked` issues: 286 `needs-dependency`, 304 worker-created
enrichment items. Blockers are spread out, not concentrated: 299 distinct open
blockers, at most 4 dependents each. 122 blockers are themselves
`needs-dependency` (chains), 78 are `status:available` (ready, waiting for a
slot), 50 are active and 20 need a maintainer. Weighting candidate ranking by
dependents (`pulse-dispatch-engine.sh` `_append_ranked_repo_candidates`)
would cut chain latency, not total throughput: there are always 99+ available
candidates, so capacity is the limit. 11 `needs-dependency` issues have no
machine-checkable blocker (no native blocker, body refs closed or absent). They
are external or data-trigger holds that recovery comments already explain.

## Conclusions

1. There is no evidence that interactive full-loop out-solves workers. Its edge
   is per-issue latency for freshly discovered work, which is the intended role
   of interactive sessions: seeding and decomposing needs.
2. The largest single cause among the delayed interactive solves (7 of 16) is
   the trust gate on external reporters. User time per cause was not
   measured, so this is a count of delayed issues, not a share of user time.
   It is a policy decision (trust boundary), not a worker-capability gap. Two
   gates hold these issues: the creation-time triage gate and the dispatch
   gate `_check_external_issue_author_gate`
   (`.agents/scripts/pulse-dispatch-commit-gates.sh`). The dispatch gate allows
   only write-authorized authors or a verified cryptographic approval. The
   existing `triage_known_contributors` setting
   (`.agents/configs/aidevops-config.schema.json`) gives advisory review
   priority only and grants no implementation authority. Options: grant the
   reporter write access (both gates pass), add a new issue-only dispatch-trust
   setting that both gates honour (a new trust-boundary contract; PR and merge
   trust unchanged), or keep per-issue approval.
3. Do not add more pulse ordering complexity for the blocked backlog. It is
   bounded by worker capacity and by external data triggers.

## Fixes shipped from this investigation

GH#38966 (gh agent-detection env strip), GH#38977 (runner capability-burst
breaker with self-probe), GH#38978 (Files Scope missing-path warning at
filing), GH#38990 (stale validator fixtures, worker-solved), GH#38993 (sweep
claim needs `--implementing`).
