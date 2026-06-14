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
- Members, roles, invitations, and access policies.
- AI memory/context, tool permissions, and audit trails.
- Integrations, secrets references, and environment settings.
- Collaboration state such as comments, activity, notifications, and tasks.

## Kernel tables

Start with these concepts before app-specific objects:

- `workspaces`
- `workspace_memberships`
- `workspace_roles`
- `workspace_invitations`
- `workspace_settings`
- `audit_events`
- `files` / `attachments`
- `comments` / `activity_events`
- `notifications`

## Boundary rules

- Every durable business record belongs to exactly one workspace unless the product explicitly needs cross-workspace sharing.
- RLS policies include workspace membership and role checks.
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
