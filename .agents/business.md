---
name: business
description: Company orchestration - AI agents managing company functions including financial operations, invoicing, receipts
mode: subagent
tools:
  read: true
  write: true
  edit: true
  bash: true
  glob: true
  grep: true
subagents:
  - company-runners
  - accounts-receipt-ocr
  - accounts-subscription-audit
  - marketing-sales
  - legal
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Business - Company Orchestration Agent

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Purpose**: Orchestrate AI agents across company functions (HR, Finance, Operations, Marketing)
- **Pattern**: Named runners per function, coordinated via pulse supervisor (t109)
- **Scripts**: `runner-helper.sh`, `mail-helper.sh`, `/pulse`, `/full-loop`
- **Subagents**: `accounts-receipt-ocr.md`, `accounts-subscription-audit.md`, `marketing-sales.md`, `legal.md`
- **Runner configs**: `business/company-runners.md`

<!-- AI-CONTEXT-END -->

## Architecture

Named runners map to company functions. Pulse dispatches tasks by label; each runner operates in its own worktree.

| Runner | Function |
|--------|----------|
| `hiring-coordinator` | Recruitment pipeline |
| `finance-reviewer` | Expense/invoice review |
| `ops-monitor` | Infrastructure monitoring |
| `marketing-scheduler` | Campaign scheduling |
| `support-triage` | Customer issue classification |

**Flow**: Task (issue/TODO/mailbox) → pulse dispatches → runner executes in worktree → pulse observes outcomes → files improvement issues on patterns.

## Guardrails

Inherited from `/full-loop` and worktree isolation. Finance and legal runners additionally require PR review gates.

- **Scope**: Path/tool whitelists per runner via AGENTS.md
- **Audit**: Git commits + PR history
- **Rollback**: Worktree isolation per runner
- **Judgment**: `/full-loop` decides stop/retry/escalate

## Runner Setup

Create via `runner-helper.sh`. Each runner gets `~/.aidevops/.agent-workspace/runners/<name>/AGENTS.md`. Full templates: `business/company-runners.md`.

```bash
runner-helper.sh create hiring-coordinator \
  --description "Recruitment - job posts, screening, scheduling" --model sonnet
runner-helper.sh create finance-reviewer \
  --description "Expense review - OCR, approval, QuickFile sync" --model sonnet
runner-helper.sh create ops-monitor \
  --description "Infrastructure - uptime, deploys, incidents" --model haiku

runner-helper.sh list                    # Show all runners
runner-helper.sh run hiring-coordinator "Review latest 3 applications"
```

Pulse handles dispatch automatically. Manual one-off tasks: `/full-loop` directly.

## Cross-Function Workflows

Multi-department tasks use chained GitHub issues routed by label. Single-department sequences (e.g., monthly close) use multiple issues with the same label — pulse processes in order.

```bash
# New hire onboarding (3 departments)
gh issue create --repo <owner/repo> --title "Onboard: Confirm offer" --label "hiring"
gh issue create --repo <owner/repo> --title "Onboard: Setup payroll" --label "finance"
gh issue create --repo <owner/repo> --title "Onboard: Provision accounts" --label "ops"
```

## Pre-flight Questions

1. Which functions need autonomous agents vs. human-triggered workflows?
2. Escalation path for out-of-scope work?
3. Budget and rate limits per function?
4. Which operations require human approval?
5. How are cross-function handoffs tracked?
