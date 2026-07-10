---
mode: subagent
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->
# t18080: Guarantee safety-stop recovery without objective loss

## Pre-flight

- [x] Memory recall captured the user's no-loss safety-stop requirement.
- [x] Duplicate discovery found no existing universal recovery invariant.
- [x] Architecture review selected guidance and templates, not a new stateful script.
- [x] Tier: `tier:standard` — universal lifecycle semantics span progressive-disclosure files.

## Origin

- **Created:** 2026-07-10
- **Session:** OpenCode interactive mission recovery
- **Created by:** AI DevOps (ai-interactive)
- **Conversation context:** The user requires safety fuses to redirect work without losing objectives, directions, evidence, or remaining value.

## What

Make safety stops non-terminal across tasks, workers, and missions. Require a durable checkpoint and safer continuation until completion, explicit user cancellation, or demonstrated impossibility.

## Why

Treating a fuse as justification to skip work protects one machine at the cost of silently abandoning user value. Safety and completion must reinforce each other: stop unsafe execution, preserve all knowledge, then continue differently.

## Tier

**Selected tier:** `tier:standard`

## How (Approach)

### Files to Modify

- `NEW: .agents/reference/safety-stop-recovery.md` — invariant, checkpoint, recovery ladder, and terminal exceptions.
- `EDIT: .agents/AGENTS.md` — short always-loaded pointer.
- `EDIT: .agents/reference/task-lifecycle.md` — keep stopped objectives open.
- `EDIT: .agents/workflows/brief.md` — require recovery context in briefs.
- `EDIT: .agents/workflows/full-loop.md` — turn time/resource stops into continuation checkpoints.
- `EDIT: .agents/workflows/mission.md` — add recovering lifecycle semantics.
- `EDIT: .agents/templates/brief-template.md` — standard recovery fields.
- `EDIT: .agents/templates/mission-template.md` — recovery status and log.

### Implementation Steps

1. Define that a fuse stops an execution path, never the objective.
2. Require preservation of the original direction, evidence, completed work, and remaining criteria.
3. Provide a safer-route ladder from narrower scope through later-session continuation.
4. Permit terminal non-completion only for explicit cancellation or demonstrated impossibility.
5. Update worker time limits and mission states so they cannot imply abandonment.

### Verification

```bash
.agents/scripts/markdown-lint-fix.sh .agents/reference/safety-stop-recovery.md .agents/AGENTS.md .agents/reference/task-lifecycle.md .agents/workflows/brief.md .agents/workflows/full-loop.md .agents/workflows/mission.md .agents/templates/brief-template.md .agents/templates/mission-template.md todo/tasks/t18080-brief.md
.agents/scripts/linters-local.sh --changed
```

### Recoverability Checkpoint

- [x] Focused Markdown checks pass.
- [x] WIP checkpoint committed before broad validation: `31e06fcd3`.
- [x] Broad changed-mode validation passes.

### Files Scope

- `.agents/reference/safety-stop-recovery.md`
- `.agents/AGENTS.md`
- `.agents/reference/task-lifecycle.md`
- `.agents/workflows/brief.md`
- `.agents/workflows/full-loop.md`
- `.agents/workflows/mission.md`
- `.agents/templates/brief-template.md`
- `.agents/templates/mission-template.md`
- `todo/tasks/t18080-brief.md`
- `TODO.md`

## Acceptance Criteria

- [x] Safety stops explicitly preserve and keep the original objective open.
- [x] Briefs and missions contain durable recovery fields and a next safe action.
- [x] Worker time/resource limits produce checkpoints and continuation, not abandonment.
- [x] Terminal non-completion requires explicit cancellation or demonstrated impossibility.

## Context & Decisions

- Follow the framework architecture rule: guidance owns judgment; scripts remain deterministic utilities.
- Do not weaken any fuse or suggest identical unsafe retries.
- Apply the policy immediately to the active lint-resource mission by reopening its Target B objective.
