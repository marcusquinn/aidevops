---
description: Provider-neutral offline marketing decision contract and recovery behavior
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2026 Marcus Quinn -->

# Marketing decisions

`marketing_decisions.py` is the stable import contract for bounded, evidence-backed
decisions shared by ads, SEO/GEO, and creative workflows. It performs mechanical
validation and accounting only. Callers retain semantic policy, provider selection,
permissions, and action authority. The current schemas are
`aidevops.marketing-decision-{input,supplied,report}/v1`; unknown versions fail closed.

## Import and CLI contracts

```python
from marketing_decisions import load_json, run, validate_input, validate_supplied

request = validate_input(load_json("request.json"))
report = run(request, validate_supplied(load_json("decisions.json"), request))
```

```bash
python3 .agents/scripts/marketing-decision-helper.py validate --input request.json
python3 .agents/scripts/marketing-decision-helper.py run --input request.json --decisions decisions.json --dry-run
```

The supplied-decision adapter is intentionally narrow: an already-authorized host
may implement `DecisionAdapter.decide(request)` and pass its returned document to
`validate_supplied`. This module does not launch agents, select providers, retry
through model fallbacks, use credentials, or access the network. Existing Jev,
runtime, and marketing performance routes remain separate and unchanged.

## Evidence, economics, and authority

Inputs preserve account/site scope, opaque row and candidate IDs, source ID/span,
capture/as-of times, performance window, classification, digest, rubric, model, and
provider version. Reports retain every accepted, deferred, and failed row. Reported
probability and confidence are distinct; a score cannot also be a probability.
Calibration provenance is explicit. Latency, token usage, and cost accept `null` as
unknown; unknown cost is never converted to zero. Reports are non-mutating
recommendations. Model output cannot grant permissions or provide executable
commands or URLs.

The cache key covers normalized content, project/account/site scope, rubric, model,
and performance window. Therefore a stale window or different account cannot replay
an earlier result. `--store ABSOLUTE_PRIVATE_DIR` is opt-in. It creates mode-0700
scope directories and mode-0600 artifacts, rejects symlinks and Git worktrees,
atomically creates identities/cache records, safely replays identical bytes, and
rejects conflicting retries. No account or existing marketing/Jev store is modified.

## Recovery

Bounds cover bytes, rows, candidates, and concurrency. Budgets cover latency,
input/output tokens, and cost. Missing usage for a configured budget fails closed;
exceeded rows and all following evidence remain in the checkpoint for explicit
recovery. `cancelled_after_row_id` preserves subsequent rows as deferred. Invalid
candidate IDs, unsafe action proposals, malformed inputs, cross-request decisions,
and conflicting retries cannot become accepted decisions. Rollback removes only the
new scripts/schema/workflow; operators retain or delete private evidence explicitly.

## Delivered capability matrix

| Need | Offline path | Output boundary |
|---|---|---|
| Imported account/page/answer evidence | `marketing-snapshot-helper.py import` | validates source scope without network access |
| Matching, links, disposition, creative, community, visibility | `marketing-decision-helper.py run --dry-run` with supplied decisions | accepted/deferred/unsupported rows remain explicit |
| Shared reporting | `marketing-decision-report-helper.py report --dry-run` | recommendations preserve unknown economics |
| Optional Jev classification | `marketing-decision-jev-helper.py decide --dry-run` | use only after privacy and readiness checks; no fallback is invoked |
| Local action proposal | `marketing-action-helper.py plan --dry-run` | proposal only; apply requires trusted approval adapter |

Run one bounded agent review per collected batch, not one worker per row. Cache invalidation follows the existing scope, rubric, model, and performance-window key; calibrate each job before relying on scores. First-party conversion gaps normally take priority over broad citation polling, although operator context can change that cadence. No fixture establishes ROI, live provider readiness, or economics that were not observed.
