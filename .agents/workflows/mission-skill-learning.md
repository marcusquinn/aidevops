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

**Related**:

| File | Purpose |
|------|---------|
| `workflows/mission-orchestrator.md` | Orchestrator that invokes skill learning at completion |
| `reference/memory.md` | Cross-session memory system |
| `tools/build-agent/build-agent.md` | Agent lifecycle tiers (draft/custom/shared) |
| `templates/mission-template.md` | Mission state file with "Mission Agents" table |

<!-- AI-CONTEXT-END -->

## Capture Points

**During execution (lightweight):** The orchestrator notes observations in the mission's decision log as they occur — no interruption. Raw observations, not yet scored.

**At completion (full scan):** When a mission reaches `status: completed`, run `mission-skill-learner.sh scan <mission-dir>`. This scans `agents/` and `scripts/` subdirectories, extracts decisions and lessons from the decision log and retrospective, scores each artifact (0-100), stores results in `memory.db`, and suggests promotions.

## Artifact Scoring

Mission agents and scripts are scored on 5 dimensions:

| Factor | Weight | Measures |
|--------|--------|----------|
| Generality | +30 | Not project-specific (no hardcoded paths, URLs, repo names) |
| Documentation | +20 | Has description, usage comments, structured sections |
| Size | +15 | Appropriate length (not trivial, not bloated) |
| Standard format | +15 | Follows aidevops conventions (frontmatter, set -euo, local vars) |
| Multi-feature usage | +20 | Referenced by multiple features within the mission |

## Pattern Capture

Decisions and lessons from the mission state file are stored as `MISSION_PATTERN` memory entries, accumulating across missions and surfacing via `/recall` when planning future missions.

**Pattern types**: decisions (technology/architecture choices), lessons (what worked/didn't), failure modes (approaches that failed and why).

## Promotion Lifecycle

```text
mission-only -> draft/ -> custom/ -> shared/
   (score < 40)  (>= 40)   (>= 70)   (>= 85)
```

| Tier | Score | Location | Notes |
|------|-------|----------|-------|
| Mission-only | < 40 | Mission directory | Too specific/trivial; learning still captured in memory |
| Draft | >= 40 | `~/.aidevops/agents/draft/` | Experimental, survives updates. `promote <path> draft` |
| Custom | >= 70 | `~/.aidevops/agents/custom/` | Proven useful across missions. `promote <path> custom` |
| Shared | >= 85 | Requires PR to aidevops repo | Flagged as candidate; user/supervisor creates PR |

**Recurring patterns**: `mission-skill-learner.sh patterns` identifies artifacts appearing across multiple missions — strong promotion candidates.

## Integration Points

### Cross-Session Memory

| Entry type | Memory type | Tags |
|------------|-------------|------|
| Decisions | `MISSION_PATTERN` | `mission,decision,{mission_id}` |
| Lessons | `MISSION_PATTERN` | `mission,lesson,{mission_id}` |
| Promotions | `MISSION_AGENT` | `mission,promotion,{tier},{name}` |

These surface automatically when planning missions (`/recall "mission patterns"`), when workers encounter problems (`/recall "mission lesson {domain}"`), and during pulse runs.

### Mission Orchestrator (Phase 5)

1. Run `mission-skill-learner.sh scan <mission-dir>`
2. For each suggestion with score >= 40, promote based on tier:
   - **Score >= 40 and < 85 (draft/custom)**: promote directly via CLI — `mission-skill-learner.sh promote <path> draft` (score 40–69) or `mission-skill-learner.sh promote <path> custom` (score 70–84); leave project-specific artifacts in place
   - **Score >= 85 (shared)**: do NOT use CLI promote; create a PR to the aidevops repo and follow the shared-tier review workflow (see Promotion Lifecycle table above)
3. Record decisions in the mission's "Mission Agents" table
4. File GitHub issues for framework improvements; record in "Framework Improvements" section

### Pulse Supervisor

Detects missions with `status: completed` not yet scanned (no `mission_learnings` entries for that mission_id), runs the scan, and logs promotion candidates in the pulse report.

## CLI Detail

| Command | Description |
|---------|-------------|
| `scan <mission-dir>` | Score artifacts, extract patterns/lessons, suggest promotions |
| `scan-all [--repo <path>]` | Scan all missions: `{repo}/todo/missions/*/mission.md` (repo-attached) and `~/.aidevops/missions/*/mission.md` (homeless) |
| `promote <path> [draft\|custom]` | Copy artifact to agent tier, update learning record, store promotion event |
| `patterns [--mission <id>]` | Identify artifacts seen across multiple missions, top promotion candidates |
| `suggest <mission-dir>` | Fresh scan with detailed promotion suggestions and recommended commands |
| `stats` | Total artifacts, by type, promotion counts, missions scanned, memory pattern counts |
