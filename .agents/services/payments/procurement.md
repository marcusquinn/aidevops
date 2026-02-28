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

**Provider recommendation**: Stripe Issuing (primary) or Revolut Business (alternative).

- **Stripe Issuing**: Best API, granular spending controls, real-time authorization webhooks, developer-first. Requires Stripe Issuing programme approval.
- **Revolut Business**: Native UK/EU, good API, near-instant card creation. Better for teams already on Revolut.
- **Lithic**: Most granular controls, API-first, but US-focused and requires programme setup.

**Key principle**: Every spend must have a mission ID, budget check, and receipt. No autonomous spend without pre-approved budget.

<!-- AI-CONTEXT-END -->

## Provider Comparison

### Recommendation: Stripe Issuing (Primary)

**Why Stripe Issuing over alternatives:**

| Criterion | Stripe Issuing | Revolut Business | Privacy.com | Lithic |
|-----------|---------------|-----------------|-------------|--------|
| API quality | Excellent (REST, SDKs, webhooks) | Good (REST, OpenAPI) | Adequate | Excellent |
| Card creation | Instant via API | Near-instant | Instant | Instant |
| Spending controls | Per-card, per-interval, MCC blocking | Per-card limits | Per-card limits | Most granular |
| Real-time auth | Synchronous webhooks (approve/decline) | Webhooks | Webhooks | Synchronous |
| UK/EU availability | Via Issuing programme | Native | US only | Via programme |
| Receipt data | Transaction metadata + receipts API | Transaction data | Transaction metadata | Transaction data |
| Existing integration | Already in aidevops (`stripe.md`) | None | None | None |
| Pricing | 0.2% + 20p/txn (UK) | Included in plan | Free tier available | Per-card + per-txn |

**Decision**: Stripe Issuing is the primary recommendation because:

1. aidevops already has Stripe integration (`services/payments/stripe.md`)
2. Synchronous authorization webhooks enable real-time budget enforcement (approve/decline before charge)
3. Best-in-class API with comprehensive SDKs
4. MCC (Merchant Category Code) blocking prevents misuse
5. Single platform for both receiving payments (existing) and making payments (new)

**Alternative**: Revolut Business if the user already has a Revolut Business account or prefers native UK/EU banking. The helper script supports both providers via a provider abstraction.

### Provider Setup

#### Stripe Issuing Setup

1. Apply for Stripe Issuing access at https://dashboard.stripe.com/issuing
2. Complete KYC/KYB verification (business identity, directors, beneficial owners)
3. Fund the Issuing balance (pre-funded model)
4. Create a cardholder for the AI agent
5. Store API key: `aidevops secret set STRIPE_ISSUING_SECRET_KEY`

#### Revolut Business Setup

1. Open Revolut Business account at https://business.revolut.com
2. Enable API access in Business settings
3. Generate API certificate and token
4. Store credentials: `aidevops secret set REVOLUT_API_TOKEN`

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

**Rules:**

- Each mission has a total budget set at scoping time
- Each milestone gets a sub-budget allocated from the mission budget
- Each purchase gets a dedicated virtual card with a spending limit equal to or less than the allocated amount
- Cards are frozen immediately after successful purchase
- Reserve funds (20% default) require explicit human approval
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

Every transaction produces:

```text
{mission-id}/receipts/
├── {timestamp}-{vendor}-{amount}.json    # Structured transaction data
├── {timestamp}-{vendor}-receipt.png      # Screenshot of receipt/confirmation
└── ledger.md                             # Running budget ledger (git-tracked)
```

**Ledger format** (in `mission.md` or separate `ledger.md`):

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

Card credentials are stored in Vaultwarden, not in mission files or environment variables:

```text
Vaultwarden Organization: "aidevops-missions"
├── Collection: "M001-crm-project"
│   ├── Card: ic_domain_purchase (card number, expiry, CVV)
│   ├── Card: ic_hosting_setup
│   └── Service: cloudflare-account (login credentials)
├── Collection: "M002-api-project"
│   └── Card: ic_openai_credits
```

**Workflow:**

1. `procurement-helper.sh create-card` creates the card via Stripe API
2. Card details are immediately stored in Vaultwarden via `bw` CLI
3. When a purchase needs card details, retrieve from Vaultwarden
4. Card details are never logged, printed, or stored in git

See `tools/credentials/vaultwarden.md` for Vaultwarden CLI usage.

## Spending Controls

### MCC (Merchant Category Code) Restrictions

Lock cards to specific merchant categories to prevent misuse:

```text
Allowed MCCs for mission procurement:
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

These thresholds are configurable in `configs/procurement-config.json`.

## Security

- **Card details**: Stored exclusively in Vaultwarden, never in git or logs
- **API keys**: Stored via `aidevops secret set` (gopass or credentials.sh)
- **Budget limits**: Enforced at card level (Stripe) AND application level (helper script)
- **Audit trail**: All transactions git-tracked in mission ledger
- **Card lifecycle**: Cards frozen immediately after use; closed when mission completes
- **Reserve funds**: 20% of mission budget held back, requires human approval
- **MCC locking**: Cards restricted to relevant merchant categories
- **Webhook verification**: All Stripe webhooks verified with signing secret

## Configuration

### Config Template

See `configs/procurement-config.json.txt` for the template. Copy to `configs/procurement-config.json` and customise.

Key settings:

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

The procurement agent is invoked by the mission orchestrator when a milestone requires purchases:

1. Mission orchestrator identifies resource requirements during decomposition
2. Budget is allocated per milestone
3. When a feature needs a purchase, the orchestrator invokes the procurement agent
4. Procurement agent creates a card, executes the purchase, captures the receipt
5. Budget ledger is updated and committed to git
6. Mission orchestrator continues with the next feature

**Mission state file integration:**

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
