---
description: WarmForge API playbook for deliverability monitoring and mailbox warmup orchestration
mode: subagent
tools:
  read: true
  bash: true
  grep: true
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# WarmForge

Monitors domain deliverability signals and automates mailbox warmup state transitions.

- One active profile per mailbox: `conservative`, `standard`, or `aggressive`
- Scale only after 7+ days stable health (low bounce, low spam-folder drift, positive reply baseline)
- Auto-pause on anomaly thresholds; resume at reduced profile after remediation — never jump to prior peak

## Operational Policy

1. Check `health` and `domains` before any orchestration command.
2. Pull `deliverability` for active domain window (default `7d`).
3. Stable → `warmup-start` or `warmup-resume`. Degraded → `warmup-pause` + incident note with root-cause hypothesis.
4. After remediation → resume at lower profile before re-scaling.

## Helper Script

`.agents/scripts/warmforge-helper.sh` — **Env:** `WARMFORGE_API_KEY` (required); `WARMFORGE_API_BASE_URL` (optional, default `https://api.warmforge.ai/v1`). API keys: terminal-local only.

| Command | Args |
|---------|------|
| `health` | |
| `domains` | |
| `mailboxes` | `[status]` |
| `deliverability` | `<domain> [window]` |
| `warmup-status` | `<mailbox_id>` |
| `warmup-start` | `<mailbox_id> [profile] [start_date]` |
| `warmup-pause` | `<mailbox_id>` |
| `warmup-resume` | `<mailbox_id>` |
| `raw` | `<METHOD> <PATH> [JSON_BODY]` |

## Failure Handling

- HTTP 4xx → configuration/auth problem (token scope, mailbox ID, domain ID)
- HTTP 5xx → provider-side incident; retry with backoff, preserve request context
