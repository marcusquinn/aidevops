<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2026 Marcus Quinn -->

# Portable bounded model-effort pilot

This is a three-case, isolated historical-replay pilot. It produces harness evidence,
not aidevops end-to-end efficiency or an automatic routing change. Reconstructed
prompts and any non-fresh case remain quarantined in the result.

## Public handoff

`configs/model-effort-pilot.json` supplies the public base commit, case metadata,
candidate requests, and the aggregate budget. On an approved runner, create the
private corpus, catalog, candidate manifests, hidden checks, and gold patches under
`$PILOT_ROOT`; none are committed. Use `init --profiles aidevops --quick-size 3
--full-size 3`, add the three cases, then qualify them three times.

The runner must label reconstructed prompts and unavailable variants. Do not replace
an unavailable requested arm with another model or effort.

## Sealed execution recipe

Use separate candidate manifests for each same-model effort arm. Before a provider
call, create and seal each plan with the committed budget contract:

```bash
HELPER="$HOME/.aidevops/agents/scripts/brief-tier-test-helper.sh"
"$HELPER" qualify --corpus "$PILOT_ROOT/corpus" --catalog "$PILOT_ROOT/catalog.json" --repetitions 3
"$HELPER" plan --corpus "$PILOT_ROOT/corpus" --candidates "$PILOT_ROOT/candidates/ARM.json" --experiment "$PILOT_ROOT/experiments/ARM" --experiment-id "ARM" --suite quick --stage canary --mode autonomous --execution-posture enforced --budget "$PILOT_ROOT/budget.json"
"$HELPER" seal --experiment "$PILOT_ROOT/experiments/ARM" --input "$PILOT_ROOT/predictions/ARM.json"
"$HELPER" run --experiment "$PILOT_ROOT/experiments/ARM" --corpus "$PILOT_ROOT/corpus" --catalog "$PILOT_ROOT/catalog.json" --dry-run
```

For a real run, extract the `budget` object into a local JSON file with schema
`aidevops-model-replay-budget/v1`; the public pilot file also contains metadata and
is intentionally not accepted as a bare budget contract. A sealed plan copies the
contract. It reserves a cell before launch, persists the reservation, and rejects a
resume with an uncompleted launch until reconciled. These limits bound launches,
wall time, per-cell timeout, and concurrency; they do not cap provider cost or quota.

Real execution is restricted to approved OpenAI ChatGPT OAuth. It must retain the
existing enforced egress sandbox and observed concrete model/effort evidence; do not
use API-key billing, fixture runtimes, trusted-local posture, or alternate providers.
The runner records the outcome and exact prerequisite failure. The t18425 report may
join only sealed receipts and public hashes, not raw artifacts.

## 2026-09-10 execution outcome

The first approved attempt reconstructed and disclosed all three private cases,
then stopped during three-repeat qualification because the Linux runner had no
enforcing verifier filesystem sandbox. No plan or seal was created, no provider
call occurred, and 0 of 24 launches were consumed. `unshare` and `systemd-run`
were present, but the harness approves neither as a substitute for Bubblewrap.

The retain decision, production coverage, fingerprints, and exact resume
condition are recorded in `model-effort-evaluation.md`. This prerequisite failure
is terminal evidence for the attempt, not a successful pilot. Do not resume with
`trusted-local`, a different provider, API-key billing, or weaker verification.
