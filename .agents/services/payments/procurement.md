---
description: Autonomous procurement agent - virtual card management, budget enforcement, receipt capture, audit trail
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

# Procurement Agent - Autonomous Payment for Missions

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Purpose**: Enable missions to purchase domains, services, API credits autonomously within budget
- **Helper**: `scripts/procurement-helper.sh [command] [args]`
- **Config**: `configs/procurement-config.json` (from `.json.txt` template)
- **Credentials**: Vaultwarden for card details; `aidevops secret` for API keys
- **Audit**: All transactions logged to mission folder `receipts/` and git-tracked

**Key principle**: Every spend must have a mission ID, budget check, and receipt. No autonomous spend without pre-approved budget.

<!-- AI-CONTEXT-END -->

## Provider Recommendation

**Primary: Stripe Issuing** — already integrated (`services/payments/stripe.md`), synchronous authorization webhooks for real-time budget enforcement, MCC blocking, best-in-class API.

**Alternative: Revolut Business** — if already on Revolut or prefer native UK/EU banking.

| Criterion | Stripe Issuing | Revolut Business | Lithic |
|-----------|---------------|-----------------|--------|
| API quality | Excellent | Good | Excellent |
| Card creation | Instant | Near-instant | Instant |
| Spending controls | Per-card, per-interval, MCC blocking | Per-card limits | Most granular |
| Real-time auth | Synchronous webhooks | Webhooks | Synchronous |
| UK/EU availability | Via Issuing programme | Native | Via programme |
| Existing integration | Yes (`stripe.md`) | None | None |
| Pricing | 0.2% + 20p/txn (UK) | Included in plan | Per-card + per-txn |

### Provider Setup

**Stripe Issuing:**
1. Apply at https://dashboard.stripe.com/issuing — complete KYC/KYB
2. Fund the Issuing balance (pre-funded model)
3. Create a cardholder for the AI agent
4. `aidevops secret set STRIPE_ISSUING_SECRET_KEY`

**Revolut Business:**
1. Open account at https://business.revolut.com — enable API access
2. Generate API certificate and token
3. `aidevops secret set REVOLUT_API_TOKEN`

## Architecture

### Budget Enforcement Model

```text
Mission Budget ($500)
├── Milestone 1: Infrastructure ($200)
│   ├── Card: ic_domain_purchase ($50 limit, single-use)
│   ├── Card: ic_hosting_setup ($100 limit, monthly)
│   └── Card: ic_dns_services ($50 limit, single-use)
├── Milestone 2: API Credits ($200)
│   ├── Card: ic_openai_credits ($100 limit, all-time)
│   └── Card: ic_anthropic_credits ($100 limit, all-time)
└── Reserve: Contingency ($100)
    └── Requires manual approval to spend
```

- Each purchase gets a dedicated virtual card limited to the allocated amount
- Cards are frozen immediately after successful purchase
- Reserve (20% default) requires explicit human approval
- Budget exhaustion triggers mission pause + human notification

### Transaction Lifecycle

```text
1. Mission requests purchase
   ↓
2. Budget check (mission budget - spent - committed >= amount?)
   ↓ YES                          ↓ NO
3. Create virtual card            → Pause mission, notify human
   (amount-limited, MCC-locked)
   ↓
4. Store card in Vaultwarden
   (mission-scoped collection)
   ↓
5. Execute purchase
   (browser automation or API)
   ↓
6. Authorization webhook fires
   ↓ APPROVED                     ↓ DECLINED
7. Log transaction               → Retry or escalate
   ↓
8. Capture receipt
   (screenshot + API data)
   ↓
9. Freeze/close card
   ↓
10. Update mission budget ledger
    (git-tracked in mission.md)
```

### Audit Trail

```text
{mission-id}/receipts/
├── {timestamp}-{vendor}-{amount}.json    # Structured transaction data
├── {timestamp}-{vendor}-receipt.png      # Screenshot of receipt/confirmation
└── ledger.md                             # Running budget ledger (git-tracked)
```

**Ledger format:**

```markdown
## Budget Ledger

| Date | Vendor | Description | Card | Amount | Balance | Approved By |
|------|--------|-------------|------|--------|---------|-------------|
| 2026-03-01 | Cloudflare | Domain: example.com | ic_xxx | $12.00 | $488.00 | auto (within budget) |
| 2026-03-01 | Hetzner | VPS CX22 (monthly) | ic_yyy | $5.39 | $482.61 | auto (within budget) |
| 2026-03-02 | OpenAI | API credits top-up | ic_zzz | $100.00 | $382.61 | auto (within budget) |
```

## Helper Script Commands

```bash
# Card management
procurement-helper.sh create-card --mission M001 --vendor cloudflare \
  --amount 50.00 --currency GBP --description "Domain purchase"
procurement-helper.sh freeze-card --card ic_xxx
procurement-helper.sh close-card --card ic_xxx
procurement-helper.sh list-cards --mission M001

# Budget operations
procurement-helper.sh check-budget --mission M001
procurement-helper.sh allocate --mission M001 --milestone MS1 --amount 200.00
procurement-helper.sh spend --mission M001 --amount 12.00 --vendor cloudflare \
  --description "Domain: example.com" --card ic_xxx

# Receipt capture
procurement-helper.sh capture-receipt --mission M001 --card ic_xxx \
  --screenshot /path/to/receipt.png
procurement-helper.sh export-ledger --mission M001 --format csv

# Audit
procurement-helper.sh audit --mission M001
procurement-helper.sh reconcile --mission M001
```

## Vaultwarden Integration

Card credentials are stored in Vaultwarden, never in mission files, environment variables, or git.

```text
Vaultwarden Organization: "aidevops-missions"
├── Collection: "M001-crm-project"
│   ├── Card: ic_domain_purchase (card number, expiry, CVV)
│   ├── Card: ic_hosting_setup
│   └── Service: cloudflare-account (login credentials)
├── Collection: "M002-api-project"
│   └── Card: ic_openai_credits
```

`create-card` stores card details immediately via `bw` CLI. Retrieve from Vaultwarden when a purchase needs card details. See `tools/credentials/vaultwarden.md`.

## Spending Controls

### MCC Restrictions

```text
Allowed MCCs:
- 4816: Computer network services (hosting, cloud)
- 5045: Computers and peripherals
- 5734: Computer software stores
- 5817: Digital goods (API credits, SaaS)
- 5818: Digital goods (domains, certificates)
- 7372: Computer programming, data processing
- 7379: Computer maintenance and repair
```

### Approval Thresholds

| Amount | Approval |
|--------|----------|
| < $50 | Automatic (within mission budget) |
| $50 - $200 | Automatic with notification |
| $200 - $500 | Requires human confirmation |
| > $500 | Requires human confirmation + 24h cooling period |

Configurable in `configs/procurement-config.json`.

## Security

- **Card details**: Stored exclusively in Vaultwarden, never in git or logs
- **API keys**: Stored via `aidevops secret set` (gopass or credentials.sh)
- **Budget limits**: Enforced at card level (Stripe) AND application level (helper script)
- **Audit trail**: All transactions git-tracked in mission ledger
- **Card lifecycle**: Frozen immediately after use; closed when mission completes
- **Reserve funds**: 20% held back, requires human approval
- **MCC locking**: Cards restricted to relevant merchant categories
- **Webhook verification**: All Stripe webhooks verified with signing secret

## Configuration

See `configs/procurement-config.json.txt` for the template.

```json
{
  "provider": "stripe",
  "currency": "GBP",
  "approval_thresholds": {
    "auto": 50,
    "auto_with_notification": 200,
    "manual": 500
  },
  "reserve_percentage": 20,
  "allowed_mccs": [4816, 5045, 5734, 5817, 5818, 7372, 7379],
  "notification_channel": "matterbridge",
  "vaultwarden_org": "aidevops-missions"
}
```

## Integration with Mission System

The mission orchestrator invokes the procurement agent when a milestone requires purchases. Budget is allocated per milestone at scoping time. After purchase, the budget ledger is committed to git and the orchestrator continues.

**Mission state file:**

```markdown
## Resources
- [x] Domain: example.com ($12.00, card: ic_xxx, receipt: receipts/2026-03-01-cloudflare-12.00.json)
- [x] Hosting: Hetzner CX22 ($5.39/mo, card: ic_yyy, receipt: receipts/2026-03-01-hetzner-5.39.json)
- [ ] API: OpenAI credits ($100.00, pending)
```

## Related

- `services/payments/stripe.md` — Stripe payment processing (receiving payments)
- `tools/credentials/vaultwarden.md` — Credential storage for card details
- `scripts/commands/budget-analysis.md` — Budget feasibility analysis
- `tools/browser/browser-automation.md` — Browser automation for purchases requiring web UI
- `services/communications/matterbridge.md` — Notifications for approval requests
