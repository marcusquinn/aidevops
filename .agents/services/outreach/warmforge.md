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

## Quick Reference

- Monitor domain-level deliverability signals; automate mailbox warmup state transitions
- One active schedule profile per mailbox: `conservative`, `standard`, or `aggressive`
- Scale only after 7+ days of stable health (low bounce, low spam-folder drift, steady positive reply baseline)
- Auto-pause on anomaly thresholds (bounce spike, complaint spike, inbox-placement drop)
- Resume with reduced profile after remediation — never jump back to prior peak volume

## Operational Policy

1. Check `health` and `domains` before any orchestration command.
2. Pull `deliverability` metrics for the active domain window (default `7d`).
3. Stable health → `warmup-start` or `warmup-resume`.
4. Degraded metrics → `warmup-pause`; open incident note with root-cause hypothesis.
5. After remediation → resume with lower profile before re-scaling.

## Helper Script

`.agents/scripts/warmforge-helper.sh` — commands:

- `warmforge-helper.sh health`
- `warmforge-helper.sh domains`
- `warmforge-helper.sh mailboxes [status]`
- `warmforge-helper.sh deliverability <domain> [window]`
- `warmforge-helper.sh warmup-status <mailbox_id>`
- `warmforge-helper.sh warmup-start <mailbox_id> [profile] [start_date]`
- `warmforge-helper.sh warmup-pause <mailbox_id>`
- `warmforge-helper.sh warmup-resume <mailbox_id>`
- `warmforge-helper.sh raw <METHOD> <PATH> [JSON_BODY]`

**Env:** `WARMFORGE_API_KEY` (required); `WARMFORGE_API_BASE_URL` (optional, defaults to `https://api.warmforge.ai/v1`)

## Failure Handling

- HTTP 4xx → configuration/auth problem (token scope, mailbox ID, domain ID)
- HTTP 5xx → provider-side incident; retry with backoff, preserve request context
- API keys: terminal-local only; never paste into chat or issue comments
