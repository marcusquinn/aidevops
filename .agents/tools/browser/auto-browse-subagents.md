---
description: Auto-browse subagent role contracts for browser workflow learning and graduation
mode: subagent
model: sonnet
tools:
  read: true
  write: true
  edit: false
  bash: true
  webfetch: true
  task: true
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Auto-browse Subagents

<!-- AI-CONTEXT-START -->

Use these role contracts when `/auto-browse` decomposes work. They can be dispatched as focused prompts before dedicated runtime agents exist.

<!-- AI-CONTEXT-END -->

## Shared Contract

- Work only within the objective, authorization, safety policy, and private state path supplied by the coordinator.
- Do not reveal or copy secrets, cookies, tokens, private account names, downloaded private data, or private local paths into repo artifacts or chat.
- Prefer deterministic evidence: command result, trace path, selector, endpoint, output file, or verification result.
- Stop and report `SAFETY_GATE_REQUIRED` before high-impact actions listed in `.agents/workflows/auto-browse.md`.

## Roles

| Role | Inputs | Output |
|------|--------|--------|
| `auto-browse-intake` | User objective or empty invocation | Bounded objective, missing fields, authorization and stop-before policy |
| `auto-browse-router` | Objective, policy, existing strategy | Minimum-agency tool choice with escalation path |
| `auto-browse-explorer` | Target, profile policy, current tool choice | UI map, selectors, network clues, auth/download/form behavior |
| `auto-browse-data-miner` | Data objective, source pages/endpoints | API/fetch/crawler/parser strategy and schema |
| `auto-browse-operator` | Approved interaction plan | Executed steps, evidence, blocked safety gates |
| `auto-browse-profile-manager` | Profile class and auth/session need | Profile-policy file, storage paths, cleanup/expiry guidance |
| `auto-browse-safety-gate` | Proposed action and policy | Allow/confirm/block decision with rationale |
| `auto-browse-graduator` | Best run and strategy | Private workflow agent/helper or sanitized repo plan |
| `auto-browse-verifier` | Graduated artifact | Fresh-run verification result and fragility notes |

## Dispatch Prompt Skeleton

```text
You are <role>. Use .agents/workflows/auto-browse.md and .agents/tools/browser/auto-browse.md.

Objective: <objective>
Private state path: <path>
Authorization basis: <basis>
Allowed actions: <actions>
Stop-before actions: <actions>
Current strategy summary: <summary>

Return only:
1. Findings
2. Evidence
3. Recommended next step
4. Safety gates or blockers
```

## Role Boundaries

- Intake and safety-gate do not browse.
- Router does not execute browser actions.
- Explorer may inspect, but does not perform final submits, posts, payments, or destructive changes.
- Operator executes only approved steps and stops at confirmation boundaries.
- Graduator writes artifacts but does not verify them.
- Verifier tests artifacts but does not broaden scope.
