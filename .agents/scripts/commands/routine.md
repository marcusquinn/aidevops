---
description: Design and schedule recurring non-code operational routines
agent: Build+
mode: subagent
---

Create a recurring operational routine (reports, audits, monitoring, outreach) without forcing `/full-loop`.

Arguments: $ARGUMENTS

## Goal

Build a reliable routine from three independent dimensions:

1. **SOP** - what to do
2. **Targets** - who/what to apply it to
3. **Schedule** - when to run

Keep these separate so each can evolve independently.

## Decision Rule

- If the routine needs repo code changes and PR traceability, use `/full-loop`
- If the routine is operational execution, run direct commands with `opencode run`

## Workflow

### Step 1: Define the SOP command

Create or select the command that performs one run for one target.

Examples:

```bash
/seo-export --account client-a --format summary
/keyword-research --domain example.com --market uk
/email-health-check --tenant client-a
```

Prefer deterministic helper/script commands over free-form prompts.

### Step 2: Validate quality and safety manually

Run ad-hoc before scheduling:

```bash
opencode run --dir ~/Git/<repo> --agent SEO --title "Routine dry run" \
  "/seo-export --account client-a --format summary"
```

Required checks before rollout:

- Output format is stable and client-safe
- No cross-client data leakage
- Retry and timeout behavior are acceptable
- Human review exists for outbound communication

### Step 3: Pilot rollout

Roll out in this order:

1. Internal/self target
2. Single client
3. Small client cohort
4. Full target set

Do not skip stages for outbound client-facing routines.

### Step 4: Schedule the command

Use launchd/cron to run the proven command on a fixed cadence.

Use helper script (recommended):

```bash
~/.aidevops/agents/scripts/routine-helper.sh plan \
  --name weekly-seo-rankings \
  --schedule "0 9 * * 1" \
  --dir ~/Git/aidev-ops-client-seo-reports \
  --agent SEO \
  --title "Weekly rankings" \
  --prompt "/seo-export --account client-a --format summary"
```

```bash
# macOS launchd/cron wrapper style
# aidevops: weekly client rankings
opencode run --dir ~/Git/<repo> --agent SEO --title "Weekly rankings" \
  "/seo-export --account client-a --format summary"
```

For queue-driven development work, use `/pulse`. For fixed-time routines, use scheduler entries.

## Example: Mine Failed GitHub Notifications

When your notification inbox accumulates `ci_activity` failures, schedule a routine that clusters failure signatures and surfaces systemic fixes.

By default this mines both PR and push notification sources. Add `--pr-only` if you want PR-only analysis.

```bash
~/.aidevops/agents/scripts/gh-failure-miner-helper.sh report \
  --since-hours 24 \
  --pulse-repos
```

To generate an issue-ready root-cause draft from the top cluster:

```bash
~/.aidevops/agents/scripts/gh-failure-miner-helper.sh issue-body \
  --since-hours 24 \
  --pulse-repos
```

To auto-file deduplicated systemic-fix issues in affected repos:

```bash
~/.aidevops/agents/scripts/gh-failure-miner-helper.sh create-issues \
  --since-hours 24 \
  --pulse-repos \
  --systemic-threshold 3 \
  --max-issues 3 \
  --label auto-dispatch
```

One-shot launchd installer (recommended):

```bash
~/.aidevops/agents/scripts/gh-failure-miner-helper.sh install-launchd-routine
```

Preview without installing:

```bash
~/.aidevops/agents/scripts/gh-failure-miner-helper.sh install-launchd-routine --dry-run
```

Schedule it as a routine:

```bash
~/.aidevops/agents/scripts/routine-helper.sh install-cron \
  --name gh-failure-miner \
  --schedule "15 */2 * * *" \
  --dir ~/Git/aidevops \
  --title "GH failed notifications: systemic triage" \
  --prompt "Run ~/.aidevops/agents/scripts/gh-failure-miner-helper.sh create-issues --since-hours 6 --pulse-repos --systemic-threshold 3 --max-issues 3 --label auto-dispatch and then print ~/.aidevops/agents/scripts/gh-failure-miner-helper.sh report --since-hours 6 --pulse-repos."
```

This routine is operational (triage + issue filing), so it should not use `/full-loop`.

## Routine Spec Template

Store routine definitions in your repo (for example `routines/seo-weekly.yaml`):

```yaml
name: weekly-seo-rankings
agent: SEO
repo_dir: ~/Git/aidev-ops-client-seo-reports
schedule: "0 9 * * 1"
targets_cmd: "wp-helper --list-category client --jsonl"
run_template: "/seo-export --account {{target.account}} --format summary"
```

`targets_cmd` should emit one JSON object per line so a scheduler can iterate targets.

Note: this template is architectural guidance. `routine-helper.sh` currently schedules a literal `--prompt` command and does not parse `targets_cmd` or `run_template` directly.

## Anti-Patterns

- Repeating TODO items for routine execution
- Running operational routines through `/full-loop`
- Skipping pilot stages for outbound content
- Mixing SOP logic, target selection, and schedule in one monolithic prompt
