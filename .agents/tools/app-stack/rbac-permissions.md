---
description: RBAC, capabilities, teams, field permissions, panel permissions, workflow guards, and RLS boundaries
mode: subagent
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# RBAC and Permissions

Standardise permissions from the first multi-user boundary. Roles describe what a principal can do; teams/user groups describe who a principal is grouped with.

## Concepts

| Concept | Purpose |
|---------|---------|
| `users` | Authenticated human identity records |
| `service_accounts` | Non-human actors for integrations, automations, imports, jobs, and API clients |
| `teams` / `user_groups` | User collections, departments, queues, or collaboration groups |
| `team_memberships` | User membership in teams, with optional position/title |
| `roles` | Named permission bundles, not user groups |
| `role_assignments` | Role assigned to a user or team within a workspace |
| `capabilities` | Named actions such as `invoice.issue`, `issue.triage`, `file.export` |
| `permission_rules` | Grants/denies by role, user, service account, team, entity, action, and scope |
| `field_permission_rules` | Field-level read/update/mask/hidden rules |
| `panel_permission_rules` | Layout/panel visibility and action rules |
| `workflow_transition_rules` | Who can move records between states |
| `workflow_approval_rules` | Who can approve, reject, delegate, override, or cancel workflow steps |

## Permission dimensions

- Action: `create`, `read`, `update`, `delete`, `export`, `import`, `assign`, `comment`, `attach`, `approve`, `reject`, `delegate`, `override`, `transition`, `manage`.
- Scope: `none`, `own`, `team`, `workspace`, `all`, or a named custom predicate. `all` means all records in the current workspace; platform-global access requires a separate system capability.
- Target: entity/object type, panel, field, workflow, transition, integration, or report.
- Principal: user, team/user group, role, service account.
- Context: workspace, record owner, assigned user/team, lifecycle state, sensitivity class.

## Evaluation rules

- Default deny for every non-public action.
- Workspace membership is the first gate; RLS enforces coarse workspace and row boundaries.
- System roles such as owner/admin/member/viewer bootstrap workspace access; custom roles hold product-specific capabilities. If a product needs immutable ceilings, model them separately and test them explicitly.
- Assign roles to users, service accounts, and teams; merge grants across assignments.
- Prefer additive grants. Avoid explicit denies by default; if denies are enabled, deny-overrides-grant precedence and tests are required.
- Apply field/panel/workflow rules after object-level permission so list/detail/edit screens cannot leak hidden fields or invalid actions.
- Cache permission matrices only with invalidation on role, team, membership, and field-rule changes.
- Audit permission changes, role assignments, workflow transitions, exports, and privileged reads.

## Object, panel, field, and workflow permissions

- Object permissions cover CRUD plus product actions such as export, import, assign, duplicate, archive, approve, issue, refund, and reconcile.
- Panel permissions control detail-page panels, relationship panels, admin panels, and dashboard widgets.
- Field permissions support hidden/read-only/editable/masked states and sensitivity-aware AI exposure.
- Workflow permissions bind transitions to roles/capabilities and guards: from state, to state, actor, record scope, validation, approval step, side effects.

## RLS defaults

- Every workspace-scoped table has `workspace_id` and RLS using current workspace/user context.
- Ownership and team scopes are backed by `created_by`, `owner_id`, `assigned_user_id`, `assigned_team_id`, or explicit membership join tables.
- Database RLS protects rows; application permission checks protect capabilities, fields, panels, workflow transitions, and UI affordances.

## Verification

- Build a permission matrix for one entity covering user, team, role, object action, field, panel, and workflow transition.
- Prove default deny, owner/admin access, own/team/workspace scopes, and field masking with tests.
- Verify RLS blocks cross-workspace reads/writes even when application code omits filters.
- Verify role/team changes invalidate caches and produce audit events.
