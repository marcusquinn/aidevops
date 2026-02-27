---
description: Mission skill learning — evaluate and promote reusable patterns discovered during mission execution into the framework's agent/script library
mode: subagent
model: sonnet  # evaluation and promotion decisions, not architecture-level
tools:
  read: true
  write: true
  edit: true
  bash: true
  glob: false
  grep: true
  webfetch: false
  task: false
---

# Mission Skill Learning

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Purpose**: After a mission completes, evaluate artifacts for reusability and promote valuable ones into the framework
- **Helper script**: `scripts/mission-skill-learning.sh` (scan, score, promote, remember, recurrence)
- **Invoked by**: Mission orchestrator at Phase 5 (completion), or manually via `/mission-learn`
- **Output**: Promoted artifacts in `draft/` or `custom/`, patterns stored in cross-session memory

**Key files**:

| File | Purpose |
|------|---------|
| `scripts/mission-skill-learning.sh` | Deterministic operations (scan, score, copy) |
| `workflows/mission-orchestrator.md` | Calls skill learning at Phase 5 |
| `templates/mission-template.md` | Skill Learning section in state file |
| `scripts/memory-helper.sh` | Cross-session memory storage |
| `tools/build-agent/build-agent.md` | Agent lifecycle tiers (draft/custom/shared) |

<!-- AI-CONTEXT-END -->

## How to Think

You are evaluating mission artifacts for their value beyond the mission that created them. The helper script gives you data (what exists, how it scores, whether it recurs). Your job is the judgment call: is this artifact worth promoting, and how should it be adapted for general use?

**Key principle**: Most mission artifacts are project-specific and should stay in the mission directory or be deleted. Only artifacts that solve a general problem — one that other missions or projects would face — deserve promotion. When in doubt, don't promote. The cost of a cluttered `draft/` directory (noise in agent discovery) exceeds the cost of re-creating an artifact in a future mission.

## Evaluation Workflow

### Step 1: Scan and Score

Run the helper script to discover and score artifacts:

```bash
# Discover all artifacts
mission-skill-learning.sh scan "{mission-dir}"

# Score them for promotion potential
mission-skill-learning.sh score "{mission-dir}"
```

The script scores artifacts 0-10 based on size, structure, documentation, and generalizability. These scores are a starting point — override them based on your understanding of the artifact's content.

### Step 2: Evaluate Each Candidate

For artifacts scoring 7+ (or any artifact you think deserves a closer look), read the file and assess:

**Promotion criteria** (all must be true):

1. **Solves a general problem**: Would another mission or project benefit from this? If the artifact is about "how to use ProjectX's custom ORM", it's project-specific. If it's about "how to integrate any ORM with a REST API", it's general.

2. **Self-contained**: The artifact works without the mission's specific context. It doesn't reference mission-specific file paths, environment variables, or data models that only exist in the mission's project.

3. **Not already covered**: Check if an existing agent or script in `~/.aidevops/agents/` already covers this domain. Use `rg "{keyword}" ~/.aidevops/agents/` to search. If existing coverage is partial, consider extending the existing file rather than promoting a new one.

4. **Quality bar**: The artifact has clear documentation (description, usage examples), follows framework conventions (YAML frontmatter for agents, `set -euo pipefail` for scripts), and is under 200 lines (focused, not a kitchen sink).

### Step 3: Decide and Act

For each artifact, choose one action:

| Decision | When | Action |
|----------|------|--------|
| **Delete** | Score 0-3, or project-specific noise | No action needed (stays in mission dir, cleaned up later) |
| **Keep** | Score 4-6, useful within this project only | Leave in mission directory |
| **Promote to draft/** | Score 7-8, or general but needs refinement | `mission-skill-learning.sh promote {path} --target draft` |
| **Promote to custom/** | Score 9-10, polished and immediately useful | `mission-skill-learning.sh promote {path} --target custom` |
| **Extend existing** | Overlaps with existing agent/script | Edit the existing file to incorporate the new knowledge |

**After promotion**, the artifact follows the standard agent lifecycle:
- `draft/` — experimental, survives updates, reviewed periodically
- `custom/` — user's permanent agents, survives updates
- `shared/` (root) — framework-wide, requires PR review (not done during skill learning)

### Step 4: Store Patterns in Memory

After evaluation, store the mission's learnings in cross-session memory:

```bash
mission-skill-learning.sh remember "{mission-dir}"
```

This stores:
- Mission completion with goal summary (`SUCCESS_PATTERN`)
- Decision log entries (`DECISION`)
- Created agents and scripts (`CODEBASE_PATTERN`)

These memories surface in future mission planning via `/recall "mission patterns"` and auto-recall at session start.

### Step 5: Update Mission State File

Record promotion decisions in the mission's Skill Learning section:

```markdown
## Skill Learning

| Artifact | Score | Decision | Target | Notes |
|----------|-------|----------|--------|-------|
| api-patterns.md | 8 | Promoted | draft/ | General REST API patterns |
| seed-script.sh | 4 | Keep | mission | Project-specific data |
| auth-flow.md | 3 | Delete | - | Covered by existing auth agent |
```

### Step 6: Check Recurrence

If multiple missions have been completed, check for recurring patterns:

```bash
mission-skill-learning.sh recurrence --all-missions "{missions-root}"
```

Artifacts that appear in 2+ missions are strong promotion candidates — they represent patterns that missions keep re-discovering. Prioritize these for promotion even if their individual scores are moderate.

## What Makes a Good Promotion Candidate

**Strong signals** (promote):
- Artifact was used by 3+ workers in the mission (high internal reuse)
- Similar artifact was created in a previous mission (recurrence)
- Artifact documents integration patterns for a service not yet covered by aidevops
- Artifact contains error handling or gotcha documentation that would save future debugging

**Weak signals** (keep or delete):
- Artifact is a thin wrapper around an existing tool (adds no new knowledge)
- Artifact contains hardcoded values specific to one project
- Artifact duplicates existing framework documentation with minor variations
- Artifact is a data migration or seed script (inherently project-specific)

## Adapting Artifacts for General Use

When promoting, the artifact often needs adaptation:

1. **Remove project-specific references**: Replace hardcoded paths, project names, and environment variables with placeholders or parameters
2. **Add YAML frontmatter** (for agents): `description`, `mode: subagent`, `status: draft`, `tools` permissions
3. **Add usage examples**: Show how to use the artifact in a different project context
4. **Reference existing agents**: If the artifact extends a domain already covered, add a "See also" section linking to the existing agent
5. **Keep it focused**: If the artifact covers multiple topics, split it into separate files

## Anti-Patterns

- **Promoting everything**: Most artifacts are project-specific. A 20% promotion rate is healthy; 50%+ suggests insufficient filtering.
- **Promoting without adaptation**: A promoted artifact that still references `~/Git/myapp/src/models/user.ts` is useless to other projects.
- **Skipping memory storage**: Even if no artifacts are promoted, the mission's decisions and patterns should be stored in memory. Future missions benefit from knowing what was tried and what worked.
- **Promoting to shared/ directly**: Mission artifacts go to `draft/` or `custom/` only. Promotion to shared/ (framework-wide) requires a separate PR review process.

## Integration with Mission Orchestrator

The mission orchestrator calls skill learning as part of Phase 5 (completion). The orchestrator should:

1. Run `mission-skill-learning.sh scan` and `score` to get data
2. Read this document for evaluation guidance
3. Make promotion decisions based on artifact content and mission context
4. Run `promote` for selected artifacts
5. Run `remember` to store patterns
6. Record decisions in the mission state file's Skill Learning section
7. Commit and push the updated state file

## Related

- `scripts/mission-skill-learning.sh` — Helper script for deterministic operations
- `workflows/mission-orchestrator.md` — Calls skill learning at Phase 5
- `tools/build-agent/build-agent.md` — Agent lifecycle tiers
- `memory/README.md` — Cross-session memory system
- `scripts/memory-graduate-helper.sh` — Similar pattern: graduating memories to shared docs
