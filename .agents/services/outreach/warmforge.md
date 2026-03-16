---
description: WarmForge API playbook for deliverability monitoring and mailbox warmup orchestration
mode: subagent
tools:
  read: true
  bash: true
  grep: true
---

# WarmForge

<!-- AI-CONTEXT-START -->

## Quick Reference

- Use WarmForge to monitor domain-level deliverability signals and automate mailbox warmup state transitions
- Keep warmup deterministic: only one active schedule profile per mailbox (`conservative`, `standard`, or `aggressive`)
- Gate scale decisions on evidence: improve volume only after at least 7 days of stable health (low bounce, low spam-folder drift, steady positive reply baseline)
- Pause warmup automatically on anomaly thresholds (bounce spike, complaint spike, sudden inbox-placement drop)
- Resume warmup with reduced profile after remediation; never jump directly back to prior peak volume

### Helper Script

Use `.agents/scripts/warmforge-helper.sh` for API access.

- `warmforge-helper.sh health`
- `warmforge-helper.sh domains`
- `warmforge-helper.sh mailboxes [status]`
- `warmforge-helper.sh deliverability <domain> [window]`
- `warmforge-helper.sh warmup-status <mailbox_id>`
- `warmforge-helper.sh warmup-start <mailbox_id> [profile] [start_date]`
- `warmforge-helper.sh warmup-pause <mailbox_id>`
- `warmforge-helper.sh warmup-resume <mailbox_id>`
- `warmforge-helper.sh raw <METHOD> <PATH> [JSON_BODY]`

### Required Environment

- `WARMFORGE_API_KEY` (required)
- `WARMFORGE_API_BASE_URL` (optional, defaults to `https://api.warmforge.ai/v1`)

### Operational Policy

1. Check `health` and `domains` before running orchestration commands.
2. Pull `deliverability` metrics for the active domain window (default `7d`).
3. If health is stable, run `warmup-start` or `warmup-resume` for the mailbox.
4. If metrics degrade, run `warmup-pause` and open an incident note with root-cause hypothesis.
5. Re-check after remediation and resume with a lower profile before re-scaling.

### Failure Handling

- Treat HTTP 4xx as configuration/auth problems first (token scope, mailbox ID, domain ID)
- Treat HTTP 5xx as provider-side reliability incidents; retry with backoff and preserve request context for debugging
- Keep API-key handling terminal-local only; never paste secrets into chat or issue comments

<!-- AI-CONTEXT-END -->

This document defines the baseline WarmForge operating model for deliverability monitoring and warmup orchestration tasks.
