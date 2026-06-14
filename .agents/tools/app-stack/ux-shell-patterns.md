---
description: UX shell patterns for metadata-driven dashboards, control rooms, and AI-assisted business apps
mode: subagent
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# UX Shell Patterns

Use for admin/control-room apps where users manage settings, services, assets, projects, reports, campaigns, cases, knowledge, feedback, and inboxes.

## Shell layout

- Persistent workspace switcher.
- Primary nav grouped by user job, not database table name.
- Command palette for actions, search, and AI assistance.
- Global inbox/activity stream for tasks, approvals, alerts, and comments.
- Context panel for selected record metadata, permissions, provenance, and AI summary.
- Detail pages use tabs/panels generated from layout metadata where possible.

## Core surfaces

| Surface | Purpose |
|---------|---------|
| Setup | onboarding, environment checks, required integrations |
| Settings | workspace, users, roles, secrets references, billing/config |
| Services/tools | connected providers, health, credentials status, scopes |
| Assets | files, media, imports, exports, provenance |
| Projects/cases | work tracking and operational state |
| Reports | evidence, generated outputs, delivery status |
| Knowledge | docs, memory references, decisions, search |
| Feedback/inbox | user feedback, external messages, alerts, triage |

## Interaction rules

- Every destructive action has preview, scope, and audit trail.
- Bulk actions show count, filters, and rollback/undo plan when available.
- AI suggestions are drafts until a user/worker applies and verifies them.
- Empty states teach the next action and link to setup.
- Tables support saved views, filters, column selection, export, and keyboard navigation.

## Verification

- Test the shell at narrow and wide widths.
- Verify keyboard navigation through nav, command palette, tables, panels, and dialogs.
- Verify every AI-generated or automated action has provenance and review state.
