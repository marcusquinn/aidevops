<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# t1517: Google Workspace CLI integration — Gmail, Calendar, Contacts via gws

## Origin

- **Created:** 2026-03-16
- **Session:** opencode:email-system-planning
- **Created by:** human + ai-interactive
- **Parent task:** none (Phase 4 polish)
- **Conversation context:** Google released `gws` CLI (googleworkspace/cli) — Rust binary, 20.6k stars, covers Gmail, Calendar, Sheets, Drive, Chat. Tessl eval shows it needs improvement but Gmail helpers (+triage, +send, +reply, +watch) are directly useful.

## What

Create `services/email/google-workspace.md` agent doc and integration wrapper:

1. `gws` CLI installation and auth setup guidance
2. Gmail operations via `gws gmail +triage`, `+send`, `+reply`, `+reply-all`, `+forward`, `+watch`
3. Google Calendar via `gws calendar +insert`, `+agenda`
4. Google Contacts sync patterns
5. Gmail label management (labels-as-folders mapping)
6. Evaluate as potential skill import via aidevops skill routines

## Why

Google Workspace is the most common business email platform. `gws` provides structured JSON output ideal for AI agent integration. The helper commands (+triage, +send, +reply) map directly to our email operations.

## How (Approach)

- Agent doc with installation, auth, and usage guidance
- Thin shell wrapper if needed for aidevops integration patterns
- Evaluate Tessl skill import vs direct CLI usage

## Acceptance Criteria

- [ ] `services/email/google-workspace.md` exists
- [ ] Gmail helper commands documented with examples
- [ ] Auth setup guidance (OAuth, service account, headless)

## Dependencies

- **Blocked by:** none (can be built independently)
- **External:** `gws` CLI installed, Google Cloud project for OAuth

## Estimate Breakdown

| Phase | Time | Notes |
|-------|------|-------|
| Implementation | 3h | Agent doc + integration testing |
| **Total** | **3h** | |
