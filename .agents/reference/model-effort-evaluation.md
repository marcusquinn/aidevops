<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2026 Marcus Quinn -->

# Model effort and delegation evaluation

## Primary-session compaction target replay

**2026-09-28: retain the managed 240K target; do not change the default or
introduce another opt-in target yet.** A read-only replay of local
`llm_requests` from 2026-09-14 through 2026-09-27 selected top-level `Build+`
requests on `gpt-5.6-sol` with `routing_population=top_level_profile`
(1,811 turns, 2 sessions, $136.53 API-equivalent
request cost). This isolates a model with the managed 240K target rather than
mixing in newer Anthropic models with a 500K target or headless workers. The
observed cached input totals 264.96M tokens; its listed cache-read rate is
$0.40 per million tokens. The 27 recorded `compaction` requests in the window
have a median cost of $0.47022; this is a mixed-model median, not a forecast
for the newly routed simple-tier compaction model from #32494.

For each observed turn, the replay caps cached tokens at the candidate target
and charges the difference at $0.40/M. This is an *optimistic ceiling* on
cached-input savings: real context builds up again after each additional
compaction, and repeated turns at the old ceiling need not disappear. For the
added compactions, positive consecutive cached-token increments within each
session total 5.44M tokens. Dividing that growth by each candidate target and
subtracting the 240K count estimates extra cycles, charged at the observed
median. Reset turns and uncached input/output costs are otherwise held fixed.

| Target | Cached-input saving ceiling | Added compactions (estimate) | Added cost | Net saving ceiling | Share of observed primary request cost |
| --- | ---: | ---: | ---: | ---: | ---: |
| 240K | $0 | 0 | $0 | $0 | 0% |
| 200K | $3.84 | 4.5 | $2.13 | $1.71 | 1.3% |
| 160K | $14.00 | 11.3 | $5.33 | $8.67 | 6.4% |

Fractional counts represent expected cycles, not actual calls. The cap model
does not simulate changed cache-hit rates, summary length, session lifetimes,
or quality. Even its optimistic net saving does not reach the issue's >10%
materiality threshold, so the telemetry does not support shipping another
selection or lowering the default. The sibling #32494 simple-tier route is
already merged; its future normal-use compaction costs could change this
decision. Re-evaluate with model-specific post-route compaction costs and
continuity evidence (first post-compaction re-reads and user corrections)
before changing the target. API-equivalent estimates are not billed spend.

## Compaction routing observation

**2026-09-27: enabled a guarded simple-tier compaction route.** OpenCode 1.18.32
accepts built-in agent configuration, so unpinned `agent.compaction` now resolves
from the active `simple` routing profile only when its registered input limit is at
least the managed 240K target. Explicit user pins and unknown/insufficient limits
retain the parent model. This is a configuration safety decision, not outcome
evidence.

The pre-change 14-day local review cited by #32494 found compaction at about 3%
of API-equivalent spend, $0.30–2.30 per request, and approximately zero cache
hits. Measure one normal-use week after deployment with `llm_requests` rows whose
mode is `compaction`: compare request count, input/output tokens, cache-hit rate,
and API-equivalent cost against that baseline. For each compacted session, record
whether the first post-compaction turn completes without re-reading summarised
files or a user correction. Do not claim a cost or continuation-quality improvement
until that dated comparison has matched rows and outcome evidence.

## Decision

**2026-09-10: retain the current workload routes.** Keep Luna low for simple
work, Terra low for standard work, Sol medium for thinking work, and Astra low
only for bounded specialist advice. No default, account, provider, sandbox, or
routing-table change is justified by the available evidence.

This is a retain-with-specific-next-evidence decision, not evidence that the
current routes are optimal. The isolated pilot stopped at its enforcing
filesystem-sandbox prerequisite, and the production window had no verified
objective attachments from which to calculate acceptance or cost per objective.

## Fixed evidence

The production observation was captured at `2026-09-10T06:13:11Z` for the
window beginning `2026-09-03T06:13:10Z`. Its private JSON has SHA-256
`4cc02778420136ea0f5ce6e37e690eaccd8dfccf7582bed9969f5b0cb362b594`.
It used pricing version `2026-09-05.1` and contained 13,077 requests across 558
session families. Recorded lineage had zero ambiguous sessions, but objective
coverage was zero: no mapped or independently verified objectives, no
attributable requests, and therefore no completion rate or cost per verified
objective.

The aggregate model rows are descriptive, not matched comparisons:

| Route observed | Requests | Raw tokens | Cache-token hit | API-equivalent estimate | Errors |
| --- | ---: | ---: | ---: | ---: | ---: |
| Sol medium | 1,652 | 105,313,324 | 96.11% | $63.568131 | 0 |
| Astra low | 300 | 18,757,858 | 80.76% | $53.888020 | 0 |
| Astra medium | 3,421 | 731,274,802 | 98.26% | $885.951364 | 8 |

These populations differ in workload, context, cache state, parentage, and
sample size. API-equivalent estimates are not invoices or subscription-allowance
measurements. They cannot establish a causal model or effort advantage.

Production lineage can group parent and child requests, but this window does not
attach accepted outcomes or parent integration/repair to those families.
Delegation economics are therefore unknown rather than zero. The isolated replay
also disables aidevops plugins and subagents, so it could not establish an
end-to-end delegation-policy improvement even if cells had launched.

## Pilot outcome

The public recipe was read from base commit
`3226532e2659b69f644a9aba99feda4a02845a79`. At execution commit
`057ed4c79785d89665df0dbd7325756988b0e080`, the public configuration and
protocol SHA-256 fingerprints were respectively
`7c767526a081436ebad987d343cfd007d0f26f34724d014bae88c102d4bb529d` and
`7425b77e1182cf9a98ff736bf7a6aeea08953802146ebe8ae5e6889689a61cff`.

Three private reconstructed cases were built from the public commit: a bounded
configuration task, a protocol-documentation task, and the aggregate-budget
harness task. Each retained one deterministic fail-to-pass check, one
pass-to-pass check, and its gold patch. Qualification was requested three times
per case with reconstructed-input disclosure.

All three cases terminated before planning with the same prerequisite result:
`No enforcing verifier filesystem sandbox is available on linux`. The host had
`unshare` and `systemd-run`, but neither is an approved backend for this harness;
Bubblewrap was unavailable. OpenAI readiness was cached healthy, but provider
readiness cannot substitute for the failed verifier boundary.

No plan or prediction seal was created, no provider call occurred, and no cell
was launched. Programme consumption is **0 of 24 launches**, **0 completed
cells**, and **0 seconds of cell execution**. There are no ambiguous attempts.
Using `trusted-local`, installing a new backend, switching provider, using API-key
billing, or weakening the verifier would have violated the authorised controls.
Accordingly, the experiment criterion remains incomplete; the prerequisite
failure is not represented as a successful pilot.

## Workload decisions

| Workload class | Decision | Reason | Evidence needed to reconsider |
| --- | --- | --- | --- |
| Simple | Retain Luna low | No matched accepted outcomes compare a higher route with Luna. | Verified simple objectives with total parent/repair work and current pricing. |
| Standard | Retain Terra low | Production aggregates are unmatched and the replay did not launch. | Matched standard objectives, including retries and acceptance. |
| Thinking | Retain Sol medium | Astra's larger unmatched aggregate cost does not prove per-objective inferiority, but supplies no case for a default change. | Qualified Sol/Astra cells plus matched production outcomes by context/cache band. |
| Specialist delegation | Retain bounded Astra low | Accepted child contribution and parent integration/repair are not measured. | Outcome-linked parent/child/repair evidence for the same task class. |

## Resume condition

Resume only on an approved runner where the existing enforced verifier
filesystem sandbox passes qualification. Rebuild the private cases from the
fingerprinted public recipe, qualify all cases three times, then create fresh
seals before inference. Preserve the original 24-launch, 180-second-per-cell,
90-minute, and one-cell-at-a-time ceilings; completed or ambiguous attempts must
remain charged. A future recommendation must report failures, effective model
and effort, deterministic acceptance, active and elapsed time, total estimated
cost per verified objective, and independent sample counts.
