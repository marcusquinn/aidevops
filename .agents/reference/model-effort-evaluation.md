<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2026 Marcus Quinn -->

# Model effort and delegation evaluation

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
