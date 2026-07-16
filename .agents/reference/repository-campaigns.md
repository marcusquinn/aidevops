<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Pulse Repository Campaigns

## Status and Authority

Repository campaigns are a default-off Pulse shadow capability. They preserve
a rolling repository-level planning view without changing dispatch order or
creating, claiming, assigning, labelling, commenting on, or closing GitHub
issues.

GitHub and git remain canonical. A campaign checkpoint is a private,
rebuildable projection. Existing claim fencing, deterministic deduplication,
trust, merge, release, and deployment gates remain authoritative.

## Enable or Roll Back

```bash
# Opt in to shadow projection. Legacy candidates still drive dispatch.
export AIDEVOPS_PULSE_CAMPAIGN_SHADOW_ENABLED=1

# Optional bounded settings.
export AIDEVOPS_PULSE_CAMPAIGN_HORIZON=10
export AIDEVOPS_PULSE_CAMPAIGN_CHECKPOINT_TTL_SECONDS=3600
export AIDEVOPS_PULSE_CAMPAIGN_TIMEOUT_SECONDS=5
```

Unset the gate or set it to `0`/`false` for immediate rollback. The disabled
path performs no campaign write and no additional GitHub query. Planner,
timeout, malformed-state, and checkpoint-write failures also fail open to the
exact legacy candidate JSON.

## Checkpoint Contract

Each enabled cycle reuses the exact open-issue snapshot and filtered-ready set
already collected by Pulse. It writes one schema-v1 JSON file per Git common
directory:

```text
${AIDEVOPS_TEMP_DIR:-$HOME/.aidevops/.agent-workspace/tmp}/repository-campaigns/repo-<scope-hash>.json
```

The directory is mode `0700`; checkpoints and lock files are mode `0600`.
Writers atomically publish an owner-token lock, serialize read/plan/write, then
use a private sibling temporary file and atomic rename. Concurrent readers see
a complete old or new generation, and concurrent renewals advance in order.
Stale same-host locks are reclaimed only after host, PID, and process-start
checks. Checkpoint roots must be local filesystems without symlink traversal;
cross-host shared checkpoint roots are unsupported. Unsupported, malformed,
oversized, foreign, or expired checkpoints are ignored. Deleting the file is
safe because the next enabled cycle rebuilds it.

Schema-v1 records:

- generation and `generatedAt`/`renewAfter`/`expiresAt` timestamps;
- source hash, observation time, limit, and conservative
  successful/complete markers;
- bounded completed evidence and discoveries;
- active, blocked, oldest-ready frontier, and remaining-ready issue numbers;
- composite `(lowercase login, stable device_id)` runners and non-overlapping
  issue lanes;
- `canonicalAuthority: github+git`, `mode: shadow`, and the explicit legacy
  fallback.

The configured repository slug must bind uniquely to the same Git-common-dir
path in `repos.json`; a mismatch or ambiguous duplicate fails open without
replacing the checkpoint. The default frontier contains the oldest 10 exact
ready candidates, ordered by `createdAt` then issue number. Ready IDs are
deduplicated and intersected with the validated open snapshot. A snapshot that
reaches its configured fetch limit is marked incomplete. Failed, malformed, or
duplicate source entries are unsuccessful and incomplete, and never create
completion evidence. Known open evidence survives an incomplete/failed cycle,
while source observation ordering prevents a delayed older snapshot from
replacing a newer checkpoint.

## Runner Fitness and Devices

`peer-productivity-monitor.sh` retains additive per-repository claim, worker-PR,
interactive-PR, and bounded fitness metrics in its private state file. Its
existing honour/ignore votes and hysteresis are unchanged; an ignored peer has
zero planning capacity.

Optional explicit runner capacity can be added to a repository's `repos.json`
entry:

```json
{
  "pulse_campaign": {
    "runners": [
      {
        "login": "example-runner",
        "device_id": "stable-device-id",
        "fitness": 75,
        "capacity": 1
      }
    ]
  }
}
```

Store only identifiers and capacity metadata here, never credentials. Two
devices using one GitHub login remain separate lanes. Older peer observations
without device evidence use the `legacy` device identity until explicit or
newer evidence is available. Lane plans never supersede live GitHub claims.

## Semantic Compaction

OpenCode compaction restores only the fresh checkpoint whose Git-common-dir
scope matches the active repository. It renders bounded numeric issue IDs for
completed evidence, discoveries, active work, blocked work, the frontier,
remaining work, and validated runner lanes. Issue-derived strings are omitted
and the whole section is labelled untrusted historical data, not instructions.

## Diagnostics and Verification

Pulse writes bounded summaries to its existing log:

```text
[pulse-wrapper] Campaign shadow: repo=<owner/repo> generation=<n> frontier=<n> lanes=<n> complete=<true|false>
```

Focused verification:

```bash
node --test .agents/scripts/tests/test-pulse-campaign-coordinator.mjs
bash .agents/scripts/tests/test-pulse-campaign-shadow.sh
bash .agents/scripts/tests/test-dependency-readiness-normalization.sh
node --test .agents/plugins/opencode-aidevops/tests/test-compaction-checkpoint-scope.mjs
bash tests/test-peer-productivity-monitor.sh
```

Mixed-version fleets are safe: older runners ignore checkpoints, while newer
runners continue to honour the same canonical GitHub claims and overrides.
