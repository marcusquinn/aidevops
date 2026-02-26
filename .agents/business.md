---
name: business
description: Company orchestration - AI agents managing company functions via runners and coordinator dispatch
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
  - accounts
  - sales
  - marketing
  - legal
---

# Business - Company Orchestration Agent

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Purpose**: Orchestrate AI agents across company functions (HR, Finance, Operations, Marketing)
- **Pattern**: Named runners per function, coordinated via pulse supervisor
- **Extends**: Parallel agents (t109), runner-helper.sh, pulse supervisor

**Related Agents**:

- `accounts.md` - Financial operations (QuickFile)
- `sales.md` - Sales pipeline and CRM (FluentCRM)
- `marketing.md` - Marketing campaigns and lead generation
- `legal.md` - Legal compliance and contracts

**Key Scripts**:

- `scripts/runner-helper.sh` - Create and manage named agent instances
- Pulse supervisor (`scripts/commands/pulse.md`) - Cross-function task dispatch
- `/full-loop` - End-to-end development loop with AI-guided iteration

<!-- AI-CONTEXT-END -->

## Company Agent Pattern

Inspired by the concept of AI agents managing company functions as autonomous departments,
each with clear responsibilities, communication channels, and escalation paths.

The pattern maps company departments to named runners that:

1. Have persistent identity and memory (via `runner-helper.sh`)
2. Communicate through the mailbox system (via `mail-helper.sh`)
3. Are coordinated by a stateless pulse loop (via pulse supervisor)
4. Operate within safety guardrails (via `/full-loop` iteration limits)

### Architecture

```text
Pulse supervisor (every 2 min)
├── Fetches GitHub state (issues, PRs)
├── Observes outcomes (stale PRs, failures)
├── Dispatches tasks to available worker slots
└── Exits (stateless — GitHub is the state DB)

Named Runners (persistent identity):
├── hiring-coordinator   — Recruitment pipeline
├── finance-reviewer     — Expense/invoice review
├── ops-monitor          — Infrastructure and process monitoring
├── marketing-scheduler  — Campaign scheduling and analytics
└── support-triage       — Customer issue classification
```

### Communication Flow

```text
1. Task arrives (GitHub issue, TODO.md, or mailbox message)
2. Pulse supervisor picks it up (Step 3: priority ordering)
3. Dispatches to appropriate runner/worker (Step 4)
4. Worker executes with its AGENTS.md personality
5. Pulse observes outcomes on next cycle (Step 2a)
6. Files improvement issues if patterns emerge
```

## Setting Up Company Runners

### Quick Start

```bash
# Create company function runners
runner-helper.sh create hiring-coordinator \
  --description "Recruitment pipeline - job posts, candidate screening, interview scheduling" \
  --model sonnet

runner-helper.sh create finance-reviewer \
  --description "Expense and invoice review - receipt OCR, approval routing, QuickFile sync" \
  --model sonnet

runner-helper.sh create ops-monitor \
  --description "Infrastructure monitoring - uptime checks, deploy verification, incident triage" \
  --model haiku

# List all runners
runner-helper.sh list

# Run a task on a specific runner
runner-helper.sh run hiring-coordinator "Review the 3 latest applications in the hiring pipeline and summarise each candidate's fit"
```

### Pulse Supervisor Integration

The pulse supervisor (`/pulse`) runs every 2 minutes and coordinates all dispatch. Runners are dispatched as workers:

```bash
# Dispatch is handled by the pulse supervisor automatically
# To manually dispatch a runner task:
opencode run --dir ~/Git/<repo> --agent Business --title "Task: Review Q1 expenses" \
  "/full-loop Review Q1 expense reports for anomalies" &

# The pulse supervisor handles priority ordering, slot management,
# and outcome observation — no separate coordinator needed.
```

## Example Runner Configurations

See `business/company-runners.md` for detailed runner AGENTS.md templates and
setup instructions for each company function.

## Cross-Function Workflows

Some tasks span multiple departments. Use convoys or chained dispatch:

### Example: New Hire Onboarding

```bash
# 1. hiring-coordinator confirms offer accepted
# 2. Dispatches to finance-reviewer for payroll setup
# 3. Dispatches to ops-monitor for account provisioning

# Create GitHub issues for each step, linked to a parent issue
gh issue create --repo <owner/repo> --title "Onboard: Confirm offer" --label "hiring"
gh issue create --repo <owner/repo> --title "Onboard: Setup payroll" --label "finance"
gh issue create --repo <owner/repo> --title "Onboard: Provision accounts" --label "ops"
# Pulse supervisor picks up each issue and routes to the appropriate agent
```

### Example: Monthly Financial Close

```bash
# Create GitHub issues for each step in the monthly close
gh issue create --repo <owner/repo> --title "Monthly close: Reconcile transactions" --label "finance"
gh issue create --repo <owner/repo> --title "Monthly close: Review expenses" --label "finance"
gh issue create --repo <owner/repo> --title "Monthly close: Generate P&L" --label "finance"
gh issue create --repo <owner/repo> --title "Monthly close: Send summary" --label "finance"
```

## Guardrails

Company runners inherit safety from `/full-loop` and worktree isolation:

- **Scope constraints**: Path and tool whitelists per runner via AGENTS.md
- **Audit logging**: Every action logged via git commits and PR history
- **Rollback**: Git worktree isolation for reversible changes
- **AI judgment**: `/full-loop` decides when to stop, retry, or escalate

### Sensitive Operations

Finance and legal runners should use dedicated worktrees and PR review gates:

```bash
# Dispatch via full-loop with PR review gate
Claude run --dir ~/Git/<repo> --agent Business --title "Process monthly invoices" \
  "/full-loop Process monthly invoices — review Q1 expense reports" &
```

## Pre-flight Questions

Before setting up or modifying company orchestration:

1. Which functions need autonomous agents vs. human-triggered workflows?
2. What is the escalation path when an agent encounters something outside its scope?
3. What budget and rate limits are appropriate per function?
4. Which operations require human approval checkpoints?
5. How will cross-function handoffs be tracked and audited?
