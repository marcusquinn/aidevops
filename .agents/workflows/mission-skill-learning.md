---
description: Mission skill learning — auto-capture reusable patterns from missions, suggest promotion of temporary agents/scripts, track recurring patterns across missions
mode: subagent
model: sonnet  # pattern evaluation, not architecture-level reasoning
tools:
  read: true
  write: false
  edit: false
  bash: true
  glob: false
  grep: true
  webfetch: false
  task: false
---

# Mission Skill Learning

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Purpose**: Capture reusable patterns from missions, promote useful artifacts, feed learnings into cross-session memory
- **Script**: `scripts/mission-skill-learner.sh` — CLI for scanning, scoring, promoting, and tracking
- **Called by**: Mission orchestrator (Phase 5), pulse supervisor (mission completion), manual invocation
- **Stores to**: `memory.db` (mission_learnings table + memory entries via memory-helper.sh)

**Key commands**:

```bash
mission-skill-learner.sh scan <mission-dir>          # Scan a completed mission
mission-skill-learner.sh scan-all [--repo <path>]    # Scan all missions
mission-skill-learner.sh promote <path> [draft|custom]  # Promote artifact
mission-skill-learner.sh patterns [--mission <id>]   # Show recurring patterns
mission-skill-learner.sh suggest <mission-dir>       # Suggest promotions
mission-skill-learner.sh stats                       # Show statistics
```

**Promotion tiers**: mission-only -> `draft/` (score >= 40) -> `custom/` (score >= 70) -> `shared/` (score >= 85, PR required)

**Related**:

| File | Purpose |
|------|---------|
| `workflows/mission-orchestrator.md` | Orchestrator that invokes skill learning at completion |
| `memory/README.md` | Cross-session memory system |
| `tools/build-agent/build-agent.md` | Agent lifecycle tiers (draft/custom/shared) |
| `templates/mission-template.md` | Mission state file with "Mission Agents" table |

<!-- AI-CONTEXT-END -->

## When to Capture

The skill learning system captures at two points in the mission lifecycle:

### During Execution (Lightweight)

The orchestrator notes observations in the mission's decision log as they occur. No interruption to the mission flow. Examples:

- "Created a mission agent for X because workers kept failing without it"
- "Wrote a custom validation script that could be generalised"
- "Discovered that approach Y works well for this class of problem"

These are raw observations — not yet scored or promoted.

### At Completion (Full Scan)

When a mission reaches `status: completed`, the orchestrator runs the full skill learning scan:

```bash
mission-skill-learner.sh scan <mission-dir>
```

This:

1. Scans `{mission-dir}/agents/` for mission-specific agents
2. Scans `{mission-dir}/scripts/` for mission-specific scripts
3. Extracts decisions from the decision log
4. Extracts lessons learned from the retrospective
5. Scores each artifact for reusability (0-100)
6. Stores everything in `memory.db` (mission_learnings table)
7. Stores patterns in cross-session memory via `memory-helper.sh`
8. Suggests promotions for high-scoring artifacts

## What to Capture

### Artifacts (Agents and Scripts)

Mission agents and scripts are scored on 5 dimensions:

| Factor | Weight | What it measures |
|--------|--------|-----------------|
| Generality | +30 | Not project-specific (no hardcoded paths, URLs, repo names) |
| Documentation | +20 | Has description, usage comments, structured sections |
| Size | +15 | Appropriate length (not trivial, not bloated) |
| Standard format | +15 | Follows aidevops conventions (frontmatter, set -euo, local vars) |
| Multi-feature usage | +20 | Referenced by multiple features within the mission |

### Patterns (Decisions and Lessons)

Decisions and lessons from the mission state file are stored as memory entries with type `MISSION_PATTERN`. These accumulate across missions and surface via `/recall` when planning future missions.

Pattern types:

- **Decisions**: Technology choices, architecture decisions, trade-offs made
- **Lessons**: What worked, what didn't, what to do differently
- **Failure modes**: Approaches that failed and why (prevents repeating mistakes)

## Promotion Lifecycle

```text
mission-only -> draft/ -> custom/ -> shared/
   (score < 40)  (>= 40)   (>= 70)   (>= 85)
```

### Mission-Only (Score < 40)

The artifact stays in the mission directory. It's too project-specific or too trivial to promote. The learning is still captured in memory for pattern tracking.

### Draft Tier (Score >= 40)

```bash
mission-skill-learner.sh promote <path> draft
```

Copies to `~/.aidevops/agents/draft/`. Draft agents survive framework updates but are experimental. Good for artifacts that solve a general problem but need refinement.

### Custom Tier (Score >= 70)

```bash
mission-skill-learner.sh promote <path> custom
```

Copies to `~/.aidevops/agents/custom/`. Custom agents are the user's permanent private agents. Good for artifacts that are proven useful across multiple missions.

### Shared Tier (Score >= 85)

Cannot be promoted directly — requires a PR to the aidevops repo. The skill learner flags these as candidates and the user (or supervisor) creates a PR.

## Recurring Pattern Detection

The `patterns` command identifies artifacts that appear across multiple missions:

```bash
mission-skill-learner.sh patterns
```

This queries the `mission_learnings` table for artifacts with the same name/type seen in different missions. Recurring patterns are strong candidates for promotion — if the same agent or script keeps being created, it should be part of the framework.

## Integration with Cross-Session Memory

All mission learnings feed into the existing memory system:

- **Decisions** are stored as `MISSION_PATTERN` type memories with tags `mission,decision,{mission_id}`
- **Lessons** are stored as `MISSION_PATTERN` type memories with tags `mission,lesson,{mission_id}`
- **Promotions** are stored as `MISSION_AGENT` type memories with tags `mission,promotion,{tier},{name}`

These memories surface automatically when:

- Planning a new mission (`/mission`) — `/recall "mission patterns"` shows what worked before
- A worker encounters a problem — `/recall "mission lesson {domain}"` shows past lessons
- The supervisor runs a pulse — pattern data informs dispatch decisions

## Integration with Mission Orchestrator

The mission orchestrator (`workflows/mission-orchestrator.md`) invokes skill learning at Phase 5 (completion):

1. Run `mission-skill-learner.sh scan <mission-dir>` to capture all artifacts
2. Review the promotion suggestions in the scan output
3. For each suggestion with score >= 40:
   - If the artifact is generally useful: run `mission-skill-learner.sh promote <path> draft`
   - If the artifact is project-specific: leave in mission directory
   - Record the decision in the mission's "Mission Agents" table
4. For framework improvements identified during the mission:
   - File a GitHub issue on the aidevops repo
   - Record the issue number in the mission's "Framework Improvements" section

## Integration with Pulse Supervisor

The pulse supervisor checks for completed missions and triggers skill learning:

1. Detect missions with `status: completed` that haven't been scanned (no entries in `mission_learnings` for that mission_id)
2. Run `mission-skill-learner.sh scan <mission-dir>`
3. Log promotion candidates in the pulse report

## CLI Reference

### `scan <mission-dir>`

Scan a single mission directory for reusable artifacts. Outputs scored artifacts, decision patterns, lessons learned, and promotion suggestions.

### `scan-all [--repo <path>]`

Scan all mission directories. Checks:

- `{repo}/todo/missions/*/mission.md` (repo-attached)
- `~/.aidevops/missions/*/mission.md` (homeless)

### `promote <path> [draft|custom]`

Copy an artifact from a mission directory to the specified agent tier. Updates the learning record and stores a promotion event in memory.

### `patterns [--mission <id>]`

Show recurring patterns across missions. Identifies artifacts seen in multiple missions and top promotion candidates.

### `suggest <mission-dir>`

Run a fresh scan and display detailed promotion suggestions with recommended actions and commands.

### `stats`

Show overall learning statistics: total artifacts tracked, by type, promotion counts, missions scanned, and memory pattern counts.
