---
description: Design and schedule recurring non-code operational routines
agent: Build+
mode: subagent
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

Create recurring operational routines (reports, audits, monitoring, outreach) without `/full-loop`.

Arguments: $ARGUMENTS

Canonical format: define recurring routines in `TODO.md` under `## Routines`. Field reference: `.agents/reference/routines.md`.

## Route by work type

- Code changes or PR traceability needed → `/full-loop`
- Operational execution only → direct commands with `opencode run`

## Routine dimensions (keep independent)

1. **SOP** — what to do
2. **Targets** — who/what to apply it to
3. **Schedule** — when to run

## Workflow

### Step 1: Define the routine entry in `TODO.md`

```markdown
## Routines

- [x] r001 Weekly SEO rankings export repeat:weekly(mon@09:00) ~30m run:custom/scripts/seo-export.sh
- [ ] r002 Monthly content calendar review repeat:monthly(1@09:00) ~15m agent:Content
```

Fields: `repeat:` (`daily(@HH:MM)`, `weekly(day@HH:MM)`, `monthly(N@HH:MM)`, `cron(expr)`), `run:` (script path relative to `~/.aidevops/agents/`), `agent:` (LLM-backed via `headless-runtime-helper.sh`). Prefer `run:` over `agent:`. Default: `run:custom/scripts/{routine-name}.sh` if present, else `agent:Build+`.

### Step 2: Define the SOP command

Pick or create a command that runs once for one target. Prefer deterministic helpers/scripts over free-form prompts.

```bash
/seo-export --account client-a --format summary
/email-health-check --tenant client-a
```

### Step 3: Validate quality and safety

Run ad hoc before scheduling:

```bash
opencode run --dir ~/Git/<repo> --agent SEO --title "Routine dry run" \
  "/seo-export --account client-a --format summary"
```

Verify: output format stable and client-safe, no cross-client data leakage, retry/timeout behavior acceptable, human review exists for outbound communication.

### Step 4: Pilot rollout

Roll out in order: internal/self → single client → small cohort → full target set. Do not skip stages for outbound routines.

### Step 5: Schedule

```bash
~/.aidevops/agents/scripts/routine-helper.sh plan \
  --name weekly-seo-rankings \
  --schedule "0 9 * * 1" \
  --dir ~/Git/aidev-ops-client-seo-reports \
  --agent SEO \
  --title "Weekly rankings" \
  --prompt "/seo-export --account client-a --format summary"
```

Raw cron wrapper style:

```bash
# aidevops: weekly client rankings
opencode run --dir ~/Git/<repo> --agent SEO --title "Weekly rankings" \
  "/seo-export --account client-a --format summary"
```

`TODO.md` is the source of truth even when the scheduler expands the routine into launchd or cron. Queue-driven work → `/pulse`. Fixed-time → scheduler entries.

## Example: GH Failure Miner routine

Clusters CI failure signatures from GitHub notifications and surfaces systemic fixes.

```bash
# Ad-hoc report
~/.aidevops/agents/scripts/gh-failure-miner-helper.sh report --since-hours 24 --pulse-repos

# Auto-file deduplicated systemic-fix issues
~/.aidevops/agents/scripts/gh-failure-miner-helper.sh create-issues \
  --since-hours 24 --pulse-repos --systemic-threshold 3 --max-issues 3 --label auto-dispatch

# One-shot launchd installer (--dry-run to preview)
~/.aidevops/agents/scripts/gh-failure-miner-helper.sh install-launchd-routine
```

Schedule via `routine-helper.sh install-cron`. This is operational work — do not use `/full-loop`.

TODO.md entry:

```markdown
- [x] r010 GH Failure Miner repeat:cron(15 */2 * * *) ~10m run:scripts/gh-failure-miner-helper.sh
```

## Anti-patterns

- Creating a second routine registry outside `TODO.md`
- Running operational routines through `/full-loop`
- Skipping pilot stages for outbound content
- Mixing SOP logic, target selection, and schedule in one monolithic prompt
