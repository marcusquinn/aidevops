---
description: Subscription audit - discover, track, and optimize recurring payments
mode: subagent
tools:
  read: true
  write: true
  edit: true
  bash: true
  glob: true
  grep: true
  webfetch: true
  task: true
---

# Subscription Audit

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Purpose**: Discover all active subscriptions, calculate total spend, identify savings
- **Command**: `/subscription-audit` or `@subscription-audit`
- **Data Sources**: Email receipts, bank statements (CSV), manual inventory

**Quick start**:

```bash
# Start interactive audit
subscription-audit-helper.sh audit

# Import bank statement
subscription-audit-helper.sh import bank-statement.csv

# Show current subscriptions
subscription-audit-helper.sh list

# Show monthly/annual totals
subscription-audit-helper.sh summary
```

<!-- AI-CONTEXT-END -->

## Audit Workflow

### Phase 1: Discovery

Identify all recurring charges from multiple sources:

#### Email Receipt Scanning

Search email for common subscription receipt patterns:

```bash
# Gmail search queries (via IMAP or Gmail API)
# Recurring payment receipts
"receipt" OR "invoice" OR "subscription" OR "renewal" OR "billing"

# Common SaaS senders
from:(noreply@github.com OR billing@stripe.com OR receipts@paddle.com)

# Subscription keywords
"your subscription" OR "monthly charge" OR "annual renewal" OR "auto-renewal"
```

#### Bank Statement Import

```bash
# Import CSV (auto-detects format for major banks)
subscription-audit-helper.sh import statement.csv

# Supported formats: Chase, Amex, Barclays, Monzo, Revolut, generic CSV
# Auto-detects recurring patterns (same merchant, similar amount, regular interval)
```

#### Manual Inventory

Common categories to check:

| Category | Examples |
|----------|----------|
| **Dev Tools** | GitHub, GitLab, JetBrains, Vercel, Netlify, Railway, Fly.io |
| **Cloud/Infra** | AWS, GCP, Azure, DigitalOcean, Hetzner, Cloudflare |
| **AI/ML** | OpenAI, Anthropic, Google AI, Replicate, HuggingFace |
| **Domains** | Namecheap, Cloudflare, GoDaddy, Porkbun |
| **Email** | Google Workspace, Fastmail, Proton, Mailgun, SendGrid |
| **Monitoring** | Datadog, Sentry, PagerDuty, UptimeRobot, BetterStack |
| **Security** | 1Password, Bitwarden, NordVPN, Tailscale |
| **Productivity** | Notion, Linear, Slack, Zoom, Figma, Miro |
| **Media** | Spotify, YouTube Premium, Netflix, Audible |
| **Storage** | iCloud, Dropbox, Backblaze, Wasabi |

### Phase 2: Analysis

```bash
# Generate analysis report
subscription-audit-helper.sh analyze
```

Output includes:
- **Monthly total**: Sum of all recurring charges
- **Annual projection**: Monthly * 12 + annual-only subscriptions
- **Category breakdown**: Spend per category
- **Unused detection**: Subscriptions with no recent login/API activity
- **Duplicate detection**: Multiple tools serving same purpose
- **Price increase alerts**: Charges that increased vs. last period

### Phase 3: Optimization

| Strategy | Savings Potential |
|----------|-------------------|
| Cancel unused subscriptions | 10-30% |
| Downgrade overprovisioned tiers | 5-15% |
| Switch to annual billing | 15-20% per service |
| Consolidate overlapping tools | 10-25% |
| Use open-source alternatives | Variable |
| Negotiate enterprise discounts | 10-40% |

### Open-Source Alternatives

| Paid Tool | Free Alternative |
|-----------|------------------|
| GitHub Copilot | Claude Code (free tier), Cody |
| Notion | Obsidian, Logseq |
| Slack | Mattermost, Zulip |
| Datadog | Grafana + Prometheus |
| PagerDuty | Grafana OnCall |
| 1Password | Bitwarden (self-hosted) |
| Vercel | Coolify (self-hosted) |
| Linear | Plane (self-hosted) |

## Report Format

```text
Subscription Audit Report
=========================
Generated: 2026-02-07
Period: Monthly

Active Subscriptions: 23
Monthly Total: $847.50
Annual Projection: $10,170.00

By Category:
  Cloud/Infra:    $312.00  (36.8%)
  Dev Tools:      $189.00  (22.3%)
  AI/ML:          $145.00  (17.1%)
  Productivity:    $89.50  (10.6%)
  Security:        $52.00   (6.1%)
  Other:           $60.00   (7.1%)

Recommendations:
1. [UNUSED] Datadog Pro - no dashboards viewed in 60 days ($99/mo)
2. [DUPLICATE] Both Sentry and BetterStack for error tracking ($38/mo overlap)
3. [DOWNGRADE] GitHub Team → Free (only 2 private repos) ($4/mo)
4. [ANNUAL] Switch Vercel to annual billing (save $36/yr)

Potential Monthly Savings: $141.00 (16.6%)
```

## Data Storage

Subscription data stored in SQLite at `~/.aidevops/.agent-workspace/work/subscriptions/subscriptions.db`.

Schema:
- `subscriptions` - Active subscriptions (name, category, amount, interval, provider)
- `audit_history` - Past audit snapshots for trend tracking
- `recommendations` - Generated recommendations with status (applied/dismissed)

## Related

- `accounts.md` - Financial operations agent
- `tools/credentials/api-key-setup.md` - API key management (related spend)
