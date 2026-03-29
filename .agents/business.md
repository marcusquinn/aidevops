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
  - sales
  - marketing
  - legal
---

# Business - Company Orchestration Agent

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Purpose**: Orchestrate AI agents across company functions (HR, Finance, Operations, Marketing)
- **Pattern**: Named runners per function, coordinated via pulse supervisor (t109)
- **Scripts**: `runner-helper.sh`, `mail-helper.sh`, `/pulse`, `/full-loop`
- **Subagents**: `accounts-receipt-ocr.md`, `accounts-subscription-audit.md`, `marketing-sales.md`, `legal.md`
- **Runner configs**: `business/company-runners.md`

<!-- AI-CONTEXT-END -->

## Company Agent Pattern

Maps company departments to named runners with:
- Persistent identity/memory (`runner-helper.sh`)
- Mailbox communication (`mail-helper.sh`)
- Stateless pulse coordination (GitHub is state DB)
- Safety guardrails (`/full-loop` iteration limits)

### Architecture

```text
Pulse supervisor (every 2 min)
├── Fetches GitHub state (issues, PRs)
├── Observes outcomes (stale PRs, failures)
├── Dispatches to available worker slots
└── Exits (stateless)

Named Runners:
├── hiring-coordinator   — Recruitment pipeline
├── finance-reviewer     — Expense/invoice review
├── ops-monitor          — Infrastructure monitoring
├── marketing-scheduler  — Campaign scheduling
└── support-triage       — Customer issue classification
```

### Communication Flow

Task arrives (issue/TODO/mailbox) → pulse picks up → dispatches to runner → worker executes → pulse observes outcomes → files improvement issues if patterns emerge.

## Setting Up Runners

```bash
# Create runners
runner-helper.sh create hiring-coordinator \
  --description "Recruitment - job posts, screening, scheduling" --model sonnet
runner-helper.sh create finance-reviewer \
  --description "Expense review - OCR, approval, QuickFile sync" --model sonnet
runner-helper.sh create ops-monitor \
  --description "Infrastructure - uptime, deploys, incidents" --model haiku

# Manage
runner-helper.sh list
runner-helper.sh run hiring-coordinator "Review latest 3 applications"
```

### Manual Dispatch

Pulse handles dispatch automatically. For manual:

```bash
opencode run --dir ~/Git/<repo> --agent Business --title "Review Q1 expenses" \
  "/full-loop Review Q1 expense reports for anomalies" &
```

## Cross-Function Workflows

Multi-department tasks use chained GitHub issues. Pulse routes by label:

```bash
# New hire onboarding (3 departments)
gh issue create --repo <owner/repo> --title "Onboard: Confirm offer" --label "hiring"
gh issue create --repo <owner/repo> --title "Onboard: Setup payroll" --label "finance"
gh issue create --repo <owner/repo> --title "Onboard: Provision accounts" --label "ops"

# Monthly close (single department, sequenced)
for step in "Reconcile transactions" "Review expenses" "Generate P&L" "Send summary"; do
  gh issue create --repo <owner/repo> --title "Monthly close: $step" --label "finance"
done
```

## Guardrails

Inherited from `/full-loop` and worktree isolation:
- **Scope**: Path/tool whitelists per runner via AGENTS.md
- **Audit**: Git commits and PR history
- **Rollback**: Worktree isolation
- **Judgment**: `/full-loop` decides stop/retry/escalate

Finance and legal runners require dedicated worktrees + PR review gates.

## Pre-flight Questions

1. Which functions need autonomous agents vs. human-triggered workflows?
2. Escalation path when agent encounters out-of-scope work?
3. Budget and rate limits per function?
4. Which operations require human approval?
5. How are cross-function handoffs tracked and audited?
