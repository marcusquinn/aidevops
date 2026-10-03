---
description: Tier optimisation from production telemetry and sealed historical model replay
agent: Build+
mode: subagent
tools:
  read: true
  write: true
  edit: true
  bash: true
  glob: true
  grep: true
  task: true
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# /optimize-tiers

Use production dispatch telemetry and deterministic historical replay to evaluate
model-tier and reasoning-effort changes. Do not change routing from benchmark
results until the result is confirmed and consistent with production evidence.

Topic: $ARGUMENTS

## Production telemetry

### `/optimize-tiers report`

Show current tier dispatch telemetry from production data:

```bash
~/.aidevops/agents/scripts/dispatch-ledger-helper.sh tier-report [--days N] [--json]
```

The report covers attempts dispatched in the last 30 days by default; `--days 0`
reads all history and `--json` prints the raw summary. Terminal outcomes count
in the window of their dispatch. Sections:

- Dispatches, outcomes, and escalation reasons, with dispatch counts by tier
- Pass rate by tier: success over terminal outcomes
- First-dispatch pass rate: only the first attempt per issue, the best measure
  of solving on the first attempt
- Pass rate by tier and `model@variant`, with deferred outcomes excluded from
  the denominator and shown separately, so provider deferrals do not read as
  model failures

Telemetry is recorded automatically by:

- `dispatch-ledger-helper.sh register` — records tier + model at dispatch time
- `dispatch-ledger-helper.sh record-outcome` — records outcome + escalation
  reason, plus the model, variant, and route-attempt count that last ran. The
  dispatch row owns tier and model; worker values only fill launches that
  registered before routing
- Append-only log: `~/.aidevops/.agent-workspace/tmp/tier-telemetry.jsonl`

### Opt-in issue-level model A/B observation

Interactive OpenCode children use a separate **off-by-default** opt-in. Set
`AIDEVOPS_SUBAGENT_AB_CONFIG` to a user-owned private JSON path in the
interactive OpenCode process (not Pulse). Reuse the provider-family JSON shape
below with `"enrollment":{"mode":"new-auto-dispatch-issues"}` as the
validation marker; interactive assignment does **not** enroll issues. Give it
a distinct experiment ID, seed, repository, two all-tier arms, and a bounded
`starts_at`/`ends_at` interval (at most 168 hours). Each child session is
assigned independently by a stable hash of ID, seed, and session ID. Disabled,
expired, headless, pinned, domain, creative, browser and specialist-advisor
routes keep their existing behavior. Connected same-tier shipped models remain
fallbacks; only same-model parent/child effort is clamped. After collecting
observations, run:

```bash
AIDEVOPS_SUBAGENT_AB_CONFIG=/path/to/private/interactive-ab.json \
  node ~/.aidevops/agents/scripts/model-ab-helper.mjs report-subagents
```

This reports distinct routed child sessions per arm, tokens/cost from observed
requests, and only explicit parent acceptance receipts linked by
`opencode-child:<sessionID>`. Missing receipts remain unknown, not accepted.
No trial starts merely by running the report.

`model-ab-helper.mjs` supports a bounded initial-route comparison without
dispatching two workers for one issue. It is **off by default**. Configure a
private JSON file and pass its absolute path as `AIDEVOPS_MODEL_AB_CONFIG` to
the *Pulse process* (not just an interactive shell):

```bash
node ~/.aidevops/agents/scripts/model-ab-helper.mjs start OWNER/REPO \
  [--preset standard-luna-terra|openai-anthropic] [--hours N]
aidevops setup --scope pulse
```

`start` creates a private prospective configuration and updates the
user-owned persistent Pulse plist override without changing the running
scheduler. The scoped setup applies that override; inspect the active Pulse
environment before counting exposure. A second start refuses to replace an
existing configured trial, including an expired one, until it is reviewed.
Windows are bounded to 168 hours. Presets:

| Preset | Default window | Enrollment | Arms |
|---|---|---|---|
| `standard-luna-terra` (default) | 48 h | `new-standard-issues` | standard-tier model/effort only |
| `openai-anthropic` | 168 h | `new-auto-dispatch-issues` | provider-family routes for every tier, taken from the first OpenAI and first Anthropic model per tier in `configs/model-routing-table.json` |

The standard-only preset generates this shape:

```json
{
  "id": "standard-luna-terra", "repo": "OWNER/REPO", "seed": "cohort-1",
  "starts_at": "2026-09-23T00:00:00Z", "ends_at": "2026-09-25T00:00:00Z",
  "enrollment": {"mode": "new-standard-issues"},
  "arms": [
    {"name": "luna-max", "model": "openai/gpt-6-luna", "variant": "max"},
    {"name": "terra-medium", "model": "openai/gpt-5.6-terra", "variant": "medium"}
  ]
}
```

`start` refuses `none`, `minimal` and `low` arm variants. Background and
subagent work never runs below medium, so the routing floor would silently
raise such an arm and mislabel the comparison (GH#32539 compared medium vs
medium for this reason). Older configs that declare `low` still validate for
reporting.

A provider-family arm replaces `model`/`variant` with a route per tier. Omit
`variant` to keep the provider default. Both arms must use the same form.

```json
{"name": "anthropic", "tiers": {
  "simple": {"model": "anthropic/claude-haiku-4-5", "variant": "high"},
  "standard": {"model": "anthropic/claude-sonnet-5-5", "variant": "medium"},
  "thinking": {"model": "anthropic/claude-opus-5-5", "variant": "high"}
}}
```

Prospective enrollment requires the issue's trusted `createdAt` to fall
inside the window and its pre-claim labels to contain `auto-dispatch` and
`status:available`. Persistent, parent, held and `no-auto-dispatch` issues are
always excluded. `new-standard-issues` also excludes simple and thinking
issues. `new-auto-dispatch-issues` enrolls every tier and requires
provider-family arms. A fixed `"issues": [101, 102, ...]` array remains
available instead of `enrollment` for a predeclared cohort. The two modes
cannot be combined.
Apply the private config path through the Pulse LaunchAgent's persistent
environment override (see `reference/plist-env-overrides.md`) and regenerate
the Pulse scheduler; a shell-only export does not enable unattended workers.

Only eligible issues without an explicit model override are assigned. Each
issue keeps one arm across retries. The per-issue route table is inherited by
its worker and the worker's OpenCode subagent delegations. It keeps same-tier
availability fallbacks. A standard-only arm keeps the ordinary thinking-tier
escalation. A provider-family arm routes every tier, so escalation and child
delegations stay with the assigned provider unless it is unavailable.
Arm assignment is an **initial intention**, never a model pin or
proof of exposure. A report joins local routing telemetry with read-only
GitHub issue/merged-PR state and parent-recorded subagent acceptance:

```bash
AIDEVOPS_MODEL_AB_CONFIG=/path/to/private/model-ab.json \
  node ~/.aidevops/agents/scripts/model-ab-helper.mjs report
```

The report retains assigned-issue denominators, fallback, retry and escalation
counts, and separately marks missing observations and pending outcomes.
`off_arm_models` lists observed models outside the arm's routes, and
`off_arm_issues` counts the issues that have any. These cover cross-provider
fallbacks, legacy-arm escalations and unexplained crossovers. Review them
before comparing arms. It does
not declare a winner or equate child completion with acceptance. The cohort
rule must be defined before work begins, use issues not already in flight, and run
on one configured dispatch device: assignment receipts and observations are
local, not a cross-runner coordinated experiment. Do not use the output for a
shared-default change without independent outcome verification, repair costs,
cohort balance, actual model/variant evidence and enough terminal issues in
both arms. Ending the window stops new assignments, not already running work.

## Historical replay

Keep corpora, repository catalogs, candidate files, prompts, patches, artifacts,
results, and reports outside Git under a private local directory. Never publish
private repository identities or archived prompts.

The local benchmark operator and curated checks are trusted. Integrity hashes,
read-only prediction files, exclusive result appends, and run locks detect drift
and ordinary tampering; they are not cryptographic attestation against a
malicious process already running as the same local account.

```bash
ROOT="${HOME}/.aidevops/.agent-workspace/work/model-replay"
CORPUS="${ROOT}/corpus"
CATALOG="${ROOT}/repositories.json"
CANDIDATES="${ROOT}/candidates.json"
EXPERIMENT="${ROOT}/experiments/quick-primary-autonomous"
HELPER="${HOME}/.aidevops/agents/scripts/brief-tier-test-helper.sh"
```

### 1. Initialise and populate the corpus

```bash
"$HELPER" init --corpus "$CORPUS"
```

The default design requires three repository profiles, nine quick cases, and
eighteen full cases. For each case, archive:

- the exact historical prompt, or explicitly mark a reconstruction;
- an immutable full base commit SHA;
- a reference patch kept unavailable to the model;
- deterministic `fail_to_pass` and `pass_to_pass` command arrays;
- provenance, visibility, merge date, expected tier, and supported replay modes.

Register each case with `add-case`, then edit the generated local repository
catalog so each repository key resolves to a local canonical checkout. The
catalog is never passed to the model.

```bash
"$HELPER" add-case \
  --corpus "$CORPUS" \
  --case-id CASE_ID \
  --repo-key REPOSITORY_KEY \
  --profile PROFILE \
  --tier simple \
  --base-sha FULL_COMMIT_SHA \
  --prompt-file ARCHIVED_PROMPT \
  --gold-patch REFERENCE_PATCH \
  --checks-file HIDDEN_CHECKS_JSON \
  --visibility private \
  --quick

"$HELPER" qualify \
  --corpus "$CORPUS" \
  --catalog "$CATALOG" \
  --repetitions 3
```

Qualification fails closed unless the target checks fail on the base, regression
checks pass on the base, all checks pass after the reference patch, prompt scans
pass, and repeated outcomes are deterministic. It resolves the exact full commit,
rejects base symlinks and gitlinks, and runs checks with a minimal environment
that excludes parent credentials and Git overrides.

### 2. Configure candidates

Create a local candidate JSON file using schema
`aidevops-model-replay-candidates/v1`. It requires:

- an explicit provider allowlist;
- one `provider/model`, tier, primary effort, and supported effort list per model;
- the `opencode` runtime and a bounded timeout;
- a knowledge cutoff for public cases.

Anthropic-family providers and models are rejected by policy, including Claude
models exposed through another provider. Use only providers explicitly approved
for the experiment.

### 3. Plan and seal predictions

Create separate experiment directories for autonomous and prescriptive replay.
The modes must never be aggregated.

```bash
"$HELPER" plan \
  --corpus "$CORPUS" \
  --candidates "$CANDIDATES" \
  --experiment "$EXPERIMENT" \
  --experiment-id quick-primary-autonomous \
  --suite quick \
  --stage primary \
  --mode autonomous \
  --execution-posture enforced
```

The default `enforced` posture requires verified provider-only process-tree
egress. For a curated V1 experiment on an operator-controlled machine, select
`--execution-posture trusted-local` explicitly. The posture is sealed into the
plan and cannot be changed later; create a new experiment to change it.

Fill every field in `prediction-template.json` before any provider call, then
seal it. The CLI will not replace or reseal an existing prediction ledger.

```bash
"$HELPER" seal \
  --experiment "$EXPERIMENT" \
  --input "${ROOT}/predictions/quick-primary-autonomous.json"

"$HELPER" run \
  --experiment "$EXPERIMENT" \
  --corpus "$CORPUS" \
  --catalog "$CATALOG" \
  --dry-run
```

The dry run holds the experiment lock, validates the corpus, catalog, exact base
trees, plan, candidate, prediction, and runtime seals, makes zero provider calls,
and writes a reproducible report.

### Bounded pilot

`configs/model-effort-pilot.json` defines a portable three-case pilot and its public
source metadata. Pass a local file containing its `budget` object to `plan --budget`.
The sealed receipt reserves launches before execution and does not refund an
interrupted launch on resume. See `reference/model-effort-pilot.md` for the approved
runner recipe and limitations.

### 4. Execute and interpret

```bash
"$HELPER" run \
  --experiment "$EXPERIMENT" \
  --corpus "$CORPUS" \
  --catalog "$CATALOG"

"$HELPER" report --experiment "$EXPERIMENT"
```

Each cell runs in a fresh synthetic one-commit linked worktree with no remote or
later history. Correctness comes only from hidden deterministic checks; diff
similarity and LLM grading are excluded. Reports compare completion, functional
correctness, model/effort evidence, duration, cost when observed, failure class,
pairwise separation, and sealed-prediction calibration.

Every execution posture requires the restricted OpenCode profile, scoped
provider auth, isolated sandbox, disabled MCP/subagents/shell/network tools, and
concrete provider-request plus resource evidence. The captured patch is reapplied
to another clean synthetic base and regraded; prompt, log, metrics, and patch
hashes remain bound to the append-only result record.

OpenCode's built-in provider-auth plugins remain available for scoped OAuth;
`OPENCODE_PURE=1` still excludes external plugins and the restricted profile
prevents those built-ins from expanding the model replay tool boundary.

Dry runs never contact providers and do not require an egress backend. Before an
`enforced` real run, set `AIDEVOPS_WORKER_EGRESS_BACKEND` to an absolute
executable that implements the v1 kernel/equivalent contract documented by
`sandbox-exec-helper.sh`; the run fails before provider execution when this
trusted operator prerequisite is absent. Never use a test fixture backend.

`trusted-local` deliberately records that process-tree egress was not enforced.
It is only for curated local experiments on an operator-controlled machine. Its
correctness, cost, duration, identity, and resource observations remain visible,
but reports quarantine them from automatic routing or release recommendations.
It never weakens public triage, worker, or other runtime roles.
Each deterministic check receives a disposable patch snapshot in a separate
filesystem-deny sandbox, so check-time writes cannot affect later checks. The
enforcing backends are macOS Seatbelt and Linux Bubblewrap. Linux requires an
executable `/usr/bin/bwrap` or `/bin/bwrap`; the sandbox uses a new mount,
process, user, and network namespace, grants write access only to the disposable
snapshot and its isolated HOME/TMP/XDG tree, and mounts only required system
runtime paths read-only. Qualification and grading fail before running checks
when the platform backend is missing or cannot establish those namespaces,
rather than exposing hidden corpus, operator state, results, runtime data, or
sibling workspaces.

Use stages in order:

1. `canary` — one simple case per profile; stop if no candidate passes.
2. `primary` — quick-suite comparison at each candidate's primary effort.
3. `sweep` — effort variants on discriminator cases when primary is unresolved.
4. `confirm` — repeated route-changing candidates before a full-suite run.

Non-fresh cases admitted by explicit override remain quarantined from routing
recommendations. Unknown model identity or unsupported effective effort cannot
produce a passing result.

## Migration from the placeholder harness

The former `extract`, `enrich`, `test`, and `score` commands intentionally fail.
They relied on provider-branded assumptions, diff similarity, and unsealed
results. Replace them as follows:

| Removed command | Replacement |
|---|---|
| `extract` | Curate locally, then `init` and `add-case` |
| `enrich` | Optional `--prescriptive-file` on `add-case` |
| `test` | `plan`, `seal`, `run` |
| `score` | `report` |

Do not automatically mutate brief templates or routing. First confirm the result
on repeated quick and full replay, then compare it with production telemetry and
review the proposed routing change separately.

## Related

- `tools/context/model-routing.md` — current model and effort routing
- `reference/task-taxonomy.md` — tier definitions and cascade model
- `scripts/brief-tier-test-helper.sh` — replay benchmark entry point
- `workflows/model-replay.md` — isolated implementation-agent contract
- `todo/research/optimize-brief-tiers.md` — superseded proposal and migration record
