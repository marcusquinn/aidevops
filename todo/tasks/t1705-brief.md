<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# t1705: Organizational Repo Templating + Pulse Self-Activity Triage

## Session Origin

Interactive `/full-loop` request to implement three connected changes: mission-control repo init seeding, repos.json pulse registration defaults, and pulse/contribution notification triage that recognizes aidevops-authored activity via signature footer detection.

## What

Implement end-to-end defaults and triage behavior so new mission-control repositories are seeded with the right operating template, newly initialized repos get sane pulse defaults in repos.json, and comment-based activity triage stops flagging aidevops-authored comments as external follow-up work.

## Why

Without explicit mission-control seeding, init does not provide a tailored bootstrap for personal vs org control repos. Without pulse defaults, repo registrations can silently remain non-dispatched despite docs indicating pulse-first usage. Without signature-aware triage, automation comments can be misclassified as external activity, creating false-positive reply prompts.

## How

- Extend `aidevops.sh` registration logic to compute defaults (`pulse`, optional `priority`) at registration time and backfill missing values on updates.
- Add mission-control detection and init-time seeding in `aidevops.sh` for personal/org scopes.
- Update `.agents/scripts/contribution-watch-helper.sh` notification/backfill triage to treat comments containing `aidevops.sh` signature footer as self activity.
- Wire scan pipeline changes so username + signature detection are both considered before marking threads as needing attention.

## Acceptance Criteria

- [ ] `aidevops init` in a mission-control repo creates mission-control seed guidance (`personal` or `org`) in `todo/mission-control-seed.md`.
- [ ] `register_repo` writes default `pulse` values for new registrations and preserves existing explicit values.
- [ ] Existing registrations missing `pulse` are backfilled during updates without overriding explicit non-null values.
- [ ] Notification triage classifies latest comments with `aidevops.sh` signature as self activity.
- [ ] Backfill triage updates `last_our_comment` when latest comment is authored by current user **or** carries aidevops signature.

## Context

- `aidevops.sh` (`register_repo`, `cmd_init`) is the canonical path for init + repo registration behavior.
- `.agents/scripts/contribution-watch-helper.sh` drives external contribution notification scanning and auto-draft triggers.
- Existing signature footer conventions already reference `aidevops.sh`; this task reuses that signal for deterministic self-activity detection.
