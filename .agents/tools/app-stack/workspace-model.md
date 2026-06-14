---
description: Workspace model for data containers, permission boundaries, AI context, and collaboration scope
mode: subagent
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Workspace Model

Use `Workspace` as the default container abstraction for app data, permissions, AI context, and collaboration.

## Definition

A workspace is a named boundary that groups:

- Data records and files.
- Members, teams/user groups, roles, role assignments, invitations, and access policies.
- AI memory/context, tool permissions, and audit trails.
- Integrations, secrets references, and environment settings.
- Collaboration state such as issues, channels, chats, comments, activity, notifications, labels, files, folders, and tasks.

## Kernel tables

Start with these concepts before app-specific objects:

- `workspaces`
- `workspace_memberships`
- `teams` / `user_groups`
- `team_memberships`
- `roles`
- `role_assignments`
- `workspace_invitations`
- `workspace_settings`
- `labels` / `label_assignments`
- `issues` / issue relationships
- `channel_groups` / `channels` / `chats`
- `messages` / `threads` / `reactions`
- `activities` / calls / meetings / tasks / reminders
- `audit_events`
- `files` / `folders` / `attachments`
- `comments` / `activity_events`
- `notifications`

## Boundary rules

- Every durable business record belongs to exactly one workspace unless the product explicitly needs cross-workspace sharing.
- RLS policies include workspace membership and role checks.
- Teams group users; roles grant capabilities. Do not collapse teams/user groups into roles.
- AI agents receive only the workspace context needed for the task.
- Secrets are referenced by name/handle, not copied into workspace rows.
- Cross-workspace reporting uses read models or controlled exports, not hidden permission bypasses.

## Collaboration modes

| Mode | Pattern |
|------|---------|
| Local single-user | One workspace, local store, no invitations |
| Local AI-assisted | Workspace scopes agent tools, files, memory, and audit |
| Remote sync | Workspace IDs and RLS travel with records |
| Multi-user | Workspace memberships, roles, audit, notifications, conflict policy |

## Verification

- Trace one example record from creation to RLS policy to audit event.
- Confirm workspace ID propagation through API, jobs, imports, and exports.
- Confirm AI/tool context cannot cross workspace boundaries by default.
