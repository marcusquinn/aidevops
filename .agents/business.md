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
- **Pattern**: Named runners per function, coordinated via `coordinator-helper.sh`
- **Extends**: Parallel agents (t109), runner-helper.sh, coordinator-helper.sh

**Related Agents**:

- `accounts.md` - Financial operations (QuickFile)
- `sales.md` - Sales pipeline and CRM (FluentCRM)
- `marketing.md` - Marketing campaigns and lead generation
- `legal.md` - Legal compliance and contracts

**Key Scripts**:

- `scripts/runner-helper.sh` - Create and manage named agent instances
- `scripts/coordinator-helper.sh` - Cross-function task dispatch
- `scripts/objective-runner-helper.sh` - Long-running objectives with guardrails

<!-- AI-CONTEXT-END -->

## Company Agent Pattern

Inspired by the concept of AI agents managing company functions as autonomous departments,
each with clear responsibilities, communication channels, and escalation paths.

The pattern maps company departments to named runners that:

1. Have persistent identity and memory (via `runner-helper.sh`)
2. Communicate through the mailbox system (via `mail-helper.sh`)
3. Are coordinated by a stateless pulse loop (via `coordinator-helper.sh`)
4. Operate within safety guardrails (via `objective-runner-helper.sh`)

### Architecture

```text
coordinator-helper.sh (pulse every 2-5 min)
├── Reads agent status from SQLite
├── Processes worker status reports
├── Dispatches tasks to idle agents
└── Exits (stateless)

Named Runners (persistent identity):
├── hiring-coordinator   — Recruitment pipeline
├── finance-reviewer     — Expense/invoice review
├── ops-monitor          — Infrastructure and process monitoring
├── marketing-scheduler  — Campaign scheduling and analytics
└── support-triage       — Customer issue classification
```

### Communication Flow

```text
1. Task arrives (TODO.md, mailbox message, or cron trigger)
2. coordinator-helper.sh pulse picks it up
3. Dispatches to appropriate runner via mail-helper.sh
4. Runner executes with its AGENTS.md personality
5. Runner sends status_report back to coordinator
6. Coordinator archives report, dispatches next task
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

### Coordinator Integration

```bash
# Start the coordinator pulse (runs every 5 minutes via cron)
coordinator-helper.sh watch --interval 300

# Or install as a cron job
cron-helper.sh add "company-coordinator" \
  --schedule "*/5 * * * *" \
  --command "coordinator-helper.sh pulse"

# Manual dispatch to a specific runner
coordinator-helper.sh dispatch \
  --task "Review Q1 expense reports for anomalies" \
  --to finance-reviewer \
  --priority high

# Group related tasks into a convoy
coordinator-helper.sh convoy \
  --name "example-convoy" \
  --tasks "task-a,task-b,task-c"
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

coordinator-helper.sh convoy \
  --name "onboard-new-hire" \
  --tasks "confirm-offer,setup-payroll,provision-accounts"
```

### Example: Monthly Financial Close

```bash
coordinator-helper.sh convoy \
  --name "monthly-close" \
  --tasks "reconcile-transactions,review-expenses,generate-pnl,send-summary"
```

## Guardrails

Company runners inherit safety from `objective-runner-helper.sh`:

- **Budget limits**: Max token/cost per run (prevent runaway agents)
- **Scope constraints**: Path and tool whitelists per runner
- **Checkpoint reviews**: Periodic human approval for sensitive operations
- **Audit logging**: Every action logged with timestamps
- **Rollback**: Git worktree isolation for reversible changes

### Sensitive Operations

Finance and legal runners should always use checkpoint reviews:

```bash
objective-runner-helper.sh start "Process monthly invoices" \
  --runner finance-reviewer \
  --checkpoint-every 5 \
  --max-cost 2.00 \
  --allowed-tools "read,bash,quickfile"
```

## Pre-flight Questions

Before setting up or modifying company orchestration:

1. Which functions need autonomous agents vs. human-triggered workflows?
2. What is the escalation path when an agent encounters something outside its scope?
3. What budget and rate limits are appropriate per function?
4. Which operations require human approval checkpoints?
5. How will cross-function handoffs be tracked and audited?
