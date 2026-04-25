---
mode: subagent
---

# t2853: case milestone + deadline alarming routine

## Pre-flight

- [x] Memory recall: `pulse routine cron alarming reminder` → existing pulse routines pattern in `TODO.md` `## Routines`
- [x] Discovery: `pulse-wrapper.sh` is the routine integration point; sibling routines like nightly triage already work
- [x] File refs verified: `.agents/scripts/pulse-wrapper.sh`, `.agents/reference/routines.md`
- [x] Tier: `tier:standard` — routine + reminder logic; pulse-driven, no daemon

## Origin

- Created: 2026-04-25
- Parent task: t2840 / GH#20892
- Phase: P4 (cases plane)

## What

A pulse-driven routine that reads all open cases' deadlines, classifies each by urgency (red ≤7d, amber ≤30d, green >30d), and alarms via configurable channel (default: GH issue + ntfy notification + audit log). Sub-minute latency on legal deadlines is theatre — pulse polling (5-15min) is sufficient and avoids a daemon.

**Concrete deliverables:**

1. `scripts/case-alarm-helper.sh tick` — pulse-driven routine: scan all open cases' deadlines, classify, alarm if not already alarmed at this stage
2. Stage memory: `_cases/.alarm-state.json` records last-alarmed stage per (case-id, deadline-label) so re-runs don't spam
3. Config in `_config/case-alarms.json`: stages (default: `[7, 30]` days), channels (default: `["gh-issue", "ntfy"]`), per-case overrides
4. Alarm channels:
   - `gh-issue` — open a GH issue tagged `kind:case-alarm` with case-id + deadline + days-remaining; auto-close on next tick if deadline now passed or removed
   - `ntfy` — push notification (uses existing `aidevops` ntfy infrastructure if present)
   - `email` — stub for MVP (full email send arrives in P5)
5. Routine `r043` in `TODO.md` `## Routines`, repeat: `cron(*/15 * * * *)`, run: `scripts/case-alarm-helper.sh tick`
6. Manual: `aidevops case alarm-test <case-id>` — re-fires alarms once for a case (testing/debug)

## Why

Cases without deadline visibility get missed. Filing deadlines, statute-of-limitations dates, contractually-required notice periods — missing one of these has tangible cost (a dispute conceded, a contract auto-renewed, a regulatory penalty). The framework's job is to make missing them require active dismissal, not passive forgetfulness.

Pulse-based alarming (rather than a separate daemon) reuses existing infrastructure: the pulse already runs every 5 min, has lifecycle and lock primitives, and can dispatch alerts via existing channels. A separate alarm daemon would be parallel infrastructure for no functional gain.

## How (Approach)

1. **Alarm config** — `.agents/templates/case-alarms-config.json`:
   ```json
   {
     "stages_days": [30, 7, 1],
     "channels":    ["gh-issue", "ntfy"],
     "ntfy_topic":  "aidevops-case-alarms",
     "per_case_overrides": { "case-2026-0001-foo": { "stages_days": [60, 14, 3] } }
   }
   ```
2. **Alarm helper** — `scripts/case-alarm-helper.sh`:
   - `tick`: list all `_cases/case-*` (not archived); for each, read `dossier.toon.deadlines`; for each deadline, compute `days_until = (deadline_date - now)`; classify against stages (`green` if > max stage, `amber/red` between stages); for each `(case-id, deadline-label)` not yet alarmed at current stage, fire alarm; record in `.alarm-state.json`
   - `alarm-test <case-id>`: bypass stage memory, fire alarms for all deadlines once
   - `_alarm_gh-issue <case-id> <deadline> <days>` — opens GH issue, returns issue number; subsequent calls update or close the issue
   - `_alarm_ntfy <case-id> <deadline> <days>` — POST to configured ntfy topic
3. **Stage memory** — `_cases/.alarm-state.json`:
   ```json
   { "case-2026-0001-foo": { "filing-deadline-2026-08-31": "amber" } }
   ```
   On re-tick: only fire if computed-stage > recorded-stage (escalation). Auto-close GH alarm issues when deadline passes (timeline entry; alarm record cleared).
4. **GH issue lifecycle** — alarm issues use a stable title pattern (`Case alarm: <case-id> deadline <label>`) so re-tick updates rather than duplicates; closed when deadline passes or alarm cleared
5. **Routine `r043`** — append to `TODO.md` `## Routines`; pulse picks up automatically; lock-protected (only one alarm tick per cycle)
6. **Tests** — covers stage classification, no-spam (re-tick same stage), escalation (amber→red), gh-issue lifecycle, ntfy stub send, per-case override, archived cases ignored

### Files Scope

- NEW: `.agents/scripts/case-alarm-helper.sh`
- NEW: `.agents/templates/case-alarms-config.json`
- EDIT: `.agents/cli/aidevops` (add `case alarm-test` subcommand)
- EDIT: `TODO.md` (add `r043` routine entry — done in this task's PR)
- NEW: `.agents/tests/test-case-alarm.sh`
- EDIT: `.agents/aidevops/cases-plane.md` (alarming section)

## Acceptance Criteria

- [ ] `case-alarm-helper.sh tick` finds all open cases with future deadlines and classifies each by stage
- [ ] First tick at `red` stage opens a GH issue tagged `kind:case-alarm`
- [ ] Second tick at same stage does NOT open duplicate issue (stage memory)
- [ ] Escalation tick (amber → red): updates existing alarm issue with new severity comment
- [ ] Deadline passes: alarm issue auto-closes with summary timeline entry
- [ ] `--ntfy` configured: POST sent to topic with case-id + days-remaining + label
- [ ] Per-case override: case with `stages_days: [60, 14, 3]` alarms at 60d not 30d
- [ ] Archived cases are skipped
- [ ] Routine runs every 15 min on the pulse, lock-protected (no overlap)
- [ ] `aidevops case alarm-test <case-id>`: forces re-fire for testing without bumping stage memory
- [ ] ShellCheck zero violations
- [ ] Tests pass: `bash .agents/tests/test-case-alarm.sh`

## Dependencies

- **Blocked by:** t2851 (P4a — cases must exist with deadlines), t2852 (P4b — case list, status filtering)
- **Soft-blocked by:** none for MVP (email channel arrives in P5; for MVP, ntfy + GH-issue are enough)
- **Blocks:** none (final P4 leaf)

## Reference

- Parent brief: `todo/tasks/t2840-brief.md` § "Pulse-based deadline alarming"
- Routine pattern: `.agents/reference/routines.md` and existing routines in `TODO.md` `## Routines`
- ntfy integration pattern (if existing): check `~/.aidevops/agents/scripts/` for any `ntfy-helper.sh`; otherwise use plain `curl -d 'msg' https://ntfy.sh/<topic>`

<!-- aidevops:sig -->
---
[aidevops.sh](https://aidevops.sh) v3.11.2 plugin for [OpenCode](https://opencode.ai) v1.14.25 with claude-opus-4-7 spent 2h 18m and 138,839 tokens on this with the user in an interactive session.