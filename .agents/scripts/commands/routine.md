---
description: Design and schedule recurring non-code operational routines
agent: Build+
mode: subagent
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

Create recurring operational routines (reports, audits, monitoring, outreach) without `/full-loop`.

Arguments: $ARGUMENTS

## Route by work type

- Code changes or PR traceability needed → `/full-loop`
- Operational execution only → direct commands with `opencode run`

## Model the routine in 3 dimensions

Keep these independent so one can change without rewriting the others:

1. **SOP** — what to do
2. **Targets** — who/what to apply it to
3. **Schedule** — when to run

## Workflow

### Step 1: Define the SOP command

Pick or create a command that runs once for one target. Prefer deterministic helpers/scripts over free-form prompts.

```bash
/seo-export --account client-a --format summary
/keyword-research --domain example.com --market uk
/email-health-check --tenant client-a
```

### Step 2: Validate quality and safety

Run it ad hoc before scheduling:

```bash
opencode run --dir ~/Git/<repo> --agent SEO --title "Routine dry run" \
  "/seo-export --account client-a --format summary"
```

Before rollout, verify:

- Output format stable and client-safe
- No cross-client data leakage
- Retry/timeout behavior acceptable
- Human review exists for outbound communication

### Step 3: Pilot rollout

Roll out in order: internal/self → single client → small cohort → full target set. Do not skip stages for outbound routines.

### Step 4: Schedule

Use `routine-helper.sh` for launchd/cron when possible:

```bash
~/.aidevops/agents/scripts/routine-helper.sh plan \
  --name weekly-seo-rankings \
  --schedule "0 9 * * 1" \
  --dir ~/Git/aidev-ops-client-seo-reports \
  --agent SEO \
  --title "Weekly rankings" \
  --prompt "/seo-export --account client-a --format summary"
```

Raw launchd/cron wrapper style:

```bash
# aidevops: weekly client rankings
opencode run --dir ~/Git/<repo> --agent SEO --title "Weekly rankings" \
  "/seo-export --account client-a --format summary"
```

Queue-driven development goes through `/pulse`. Fixed-time routines go through scheduler entries.

## Example: GH Failure Miner routine

Cluster CI failure signatures from GitHub notifications and surface systemic fixes. It mines PR and push sources by default (`--pr-only` for PR-only).

```bash
# Ad-hoc report
~/.aidevops/agents/scripts/gh-failure-miner-helper.sh report --since-hours 24 --pulse-repos

# Issue-ready root-cause draft
~/.aidevops/agents/scripts/gh-failure-miner-helper.sh issue-body --since-hours 24 --pulse-repos

# Auto-file deduplicated systemic-fix issues
~/.aidevops/agents/scripts/gh-failure-miner-helper.sh create-issues \
  --since-hours 24 --pulse-repos --systemic-threshold 3 --max-issues 3 --label auto-dispatch

# One-shot launchd installer (--dry-run to preview)
~/.aidevops/agents/scripts/gh-failure-miner-helper.sh install-launchd-routine
```

Schedule via `routine-helper.sh`:

```bash
~/.aidevops/agents/scripts/routine-helper.sh install-cron \
  --name gh-failure-miner \
  --schedule "15 */2 * * *" \
  --dir ~/Git/aidevops \
  --title "GH failed notifications: systemic triage" \
  --prompt "Run ~/.aidevops/agents/scripts/gh-failure-miner-helper.sh create-issues --since-hours 6 --pulse-repos --systemic-threshold 3 --max-issues 3 --label auto-dispatch and then print ~/.aidevops/agents/scripts/gh-failure-miner-helper.sh report --since-hours 6 --pulse-repos."
```

This is operational work (triage + issue filing), so do not use `/full-loop`.

## Routine spec template

Store routine definitions in your repo, e.g. `routines/seo-weekly.yaml`:

```yaml
name: weekly-seo-rankings
agent: SEO
repo_dir: ~/Git/aidev-ops-client-seo-reports
schedule: "0 9 * * 1"
targets_cmd: "wp-helper --list-category client --jsonl"
run_template: "/seo-export --account {{target.account}} --format summary"
```

`targets_cmd` emits one JSON object per line for target iteration. `routine-helper.sh` currently schedules a literal `--prompt`; it does not parse `targets_cmd` or `run_template`.

## Anti-patterns

- Repeating TODO items for routine execution
- Running operational routines through `/full-loop`
- Skipping pilot stages for outbound content
- Mixing SOP logic, target selection, and schedule in one monolithic prompt
