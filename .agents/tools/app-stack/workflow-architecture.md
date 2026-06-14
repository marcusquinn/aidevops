---
description: Workflow, automation, approval, state machine, and runtime event architecture for business apps
mode: subagent
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Workflow Architecture

Model workflows as explicit, versioned state machines with runtime events. Workflow state must be queryable, auditable, permissioned, and testable.

## Canonical objects

| Object | Purpose |
|--------|---------|
| `workflow_definitions` | Workflow key, version, entity scope, trigger model, owner, lifecycle |
| `workflow_state_definitions` | State keys, labels, categories, initial/terminal flags, display order |
| `workflow_transition_definitions` | From/to states, label, actor type, capability, guard, action list |
| `workflow_guard_definitions` | Deterministic predicates: field values, role/team, amount limits, dates, related records |
| `workflow_action_definitions` | Field update, task/issue creation, approval request, notification, webhook, job, document, ledger post |
| `workflow_runs` | Runtime instance for a record/process with current state, definition version, correlation ID |
| `workflow_transition_events` | Append-only event log: actor, old/new state, guard result, reason, metadata |
| `approval_requests` | Human approval/rejection/delegation step assigned to user, team, role, or capability |
| `automation_rules` | Event/schedule/integration triggers that start workflows or enqueue safe actions |
| `workflow_timers` | Delays, SLA timers, escalation, reminders, timeouts, retry windows |
| `workflow_outbox` | Reliable side-effect queue for email, webhooks, AI calls, documents, ledger posts |

## Definition vs runtime

- Definition tables describe allowed states, transitions, guards, actions, and approvals.
- Runtime tables record the current workflow run, transition history, pending approvals, timers, and outbox jobs.
- `workflow_runs.current_state` is authoritative for workflow-managed records. A business-record status field may denormalise current state for fast queries, but transition history still lives in `workflow_transition_events`.
- Labels such as `status:normal` can mirror workflow state for grouping; they are not the source of truth for a state machine.

## Triggers

| Trigger | Use |
|---------|-----|
| Record event | create/update/delete, field changed, label assigned, file attached |
| User action | explicit transition, approve, reject, submit, publish, close |
| Timer | due date, SLA, scheduled recurrence, timeout, retry |
| Integration | webhook, payment event, email, calendar sync, import completion |
| AI/tool event | reviewed output, extraction complete, confidence threshold crossed |

## Guards and actions

- Guards are side-effect free checks. Examples: role/capability, amount threshold, required fields, related approval, no open blockers, valid transition.
- Actions run only after guards pass. Examples: update state, create task/issue/activity, request approval, send notification, enqueue webhook, generate document, post ledger entry.
- Actions that touch external systems use `workflow_outbox` and idempotency keys.

## Approvals

- Approval definitions belong to the workflow, not only to comments or tasks.
- Approval requests record approver user/team/role/capability, due date, delegation, decision, reason, and audit metadata.
- Multi-step approvals need order, quorum/all-of/any-of policy, escalation, and override rules.
- Approval permissions are capabilities such as `invoice.approve`, `workflow.override`, or `quote.reject`.

## Relationship to other standard objects

- Issues track human-visible work; workflows can create, update, block, or close issues.
- Activities schedule/log calls, meetings, tasks, deadlines, and reminders; workflows can wait for or create activities.
- Conversations/comments discuss records; workflow actions can emit comments/messages, but comments are not workflow state.
- Labels group/filter records; typed state and transition events remain authoritative.
- Files/documents can be workflow inputs/outputs; document generation and signing use outbox jobs and audit events.

## Verification

- Draw the state diagram before writing migrations.
- Demonstrate one workflow from draft definition to active version, start trigger, transition, guard, approval, action, timer, outbox job, and audit event.
- Prove invalid transitions fail, stale versions remain reproducible, and repeated external events are idempotent.
- Test RBAC/RLS for transition, approval, override, export, and privileged read actions.
- Confirm workflow events are append-only and enough to explain current state.
