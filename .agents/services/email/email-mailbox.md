---
description: Email mailbox operations - organization, triage, flagging, shared mailboxes, archiving, Sieve rules, IMAP/JMAP adapter usage
mode: subagent
tools:
  read: true
  write: false
  edit: false
  bash: true
  glob: true
  grep: true
  webfetch: false
  task: true
---

# Email Mailbox Agent - Operations and Organization

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Purpose**: Intelligent mailbox organization, triage, flagging, and shared mailbox workflows
- **Protocols**: IMAP4rev1 (RFC 9051), JMAP (RFC 8621), ManageSieve (RFC 5804)
- **Helper**: `scripts/email-mailbox-helper.sh` (IMAP/JMAP mailbox operations, auto-detects protocol)
- **IMAP adapter**: `scripts/email_imap_adapter.py`
- **JMAP adapter**: `scripts/email_jmap_adapter.py` (RFC 8620/8621, push support)
- **Related**: `services/email/email-agent.md` (mission communication), `services/email/ses.md` (sending)

**Key principle**: Every mailbox action follows a decision tree. Consistent organization beats ad-hoc sorting.

**Category assignment**: Primary > Transactions > Updates > Promotions > Junk

**Flag taxonomy**: Reminders | Tasks | Review | Filing | Ideas | Add-to-Contacts

<!-- AI-CONTEXT-END -->

## Mailbox Organization

### Category Assignment Decision Tree

Assign every incoming message to exactly one category. Evaluate top-down; first match wins.

```text
Is the message unsolicited or from an unknown sender with commercial intent?
  YES --> Junk/Spam
  NO  --> continue

Is the sender in the contacts list or has prior conversation history?
  NO, and message is bulk/marketing --> Promotions
  NO, and message is automated notification --> Updates
  YES --> continue

Does the message require a direct reply or contain personal/business conversation?
  YES --> Primary
  NO  --> continue

Is the message a receipt, invoice, shipping notification, or financial statement?
  YES --> Transactions
  NO  --> continue

Is the message a status update, notification, or automated alert?
  YES --> Updates
  NO  --> Promotions (newsletters, marketing) or Primary (ambiguous from known senders)
```

### Category Definitions

| Category | Description | Examples |
|----------|-------------|---------|
| **Primary** | Direct human conversation requiring attention or reply | Client emails, colleague messages, personal correspondence |
| **Transactions** | Financial records and purchase confirmations | Receipts, invoices, shipping confirmations, bank statements |
| **Updates** | Automated notifications from services you use | CI/CD alerts, calendar reminders, app notifications, security alerts |
| **Promotions** | Marketing and bulk commercial email | Newsletters, sales offers, product announcements |
| **Junk/Spam** | Unsolicited, unwanted, or malicious email | Phishing attempts, unsolicited bulk, scams |

### IMAP Folder Structure

```text
INBOX/                      # Unsorted incoming (triage target)
Archive/                    # Completed conversations
Drafts/ | Sent/ | Trash/
Transactions/               # Receipts, invoices, financial
  Transactions/Receipts/    # Optional sub-folder for high volume
  Transactions/Invoices/
Updates/                    # Notifications, alerts
Promotions/                 # Newsletters, marketing
Junk/                       # Spam (auto-managed by server)
```

**Gmail**: Uses labels instead of IMAP folders. Category tabs (Primary, Social, Promotions, Updates, Forums) are not directly accessible via IMAP — use the Gmail API or JMAP for category-level operations.

**POP3**: No folder concept, downloads from INBOX only. Always prefer IMAP or JMAP for shared mailboxes or multi-device access.

## Flagging Taxonomy

Flags are orthogonal to categories. A message in any category can carry one or more flags.

| Flag | Meaning | Clear When |
|------|---------|------------|
| **Reminders** | Time-sensitive — needs attention by a specific date | Reminder acted on or deadline passed |
| **Tasks** | Requires a concrete action (reply, create, approve) | Action completed |
| **Review** | Read carefully — contract, proposal, technical doc, legal | Decision made |
| **Filing** | Archive to a specific project or reference folder | Filed |
| **Ideas** | Inspiration, interesting link, future reference | Captured elsewhere |
| **Add-to-Contacts** | New contact — save their details | Contact saved |

### Flag Assignment Decision Tree

```text
Does the message contain a deadline or time-sensitive request? --> flag: Reminders
Does the message ask you to DO something (reply, approve, create)? --> flag: Tasks
Does the message contain a document needing careful reading (contract, spec)? --> flag: Review
Does the message belong in a project archive or reference folder? --> flag: Filing
Does the message contain an idea or inspiration for future use? --> flag: Ideas
Is this from a new contact whose details should be saved? --> flag: Add-to-Contacts
```

### IMAP Flag Implementation

IMAP keyword mapping:

```text
$Reminder → Reminders  |  $Task → Tasks  |  $Review → Review
$Filing → Filing       |  $Idea → Ideas  |  $AddContact → Add-to-Contacts
```

Not all IMAP servers support custom keywords (check `PERMANENTFLAGS` response). Fallback: use `\Flagged` as generic "needs attention" and track taxonomy in the helper script's SQLite store.

**JMAP keywords**: Set via `Email/set` method: `"keywords": {"$task": true, "$reminder": true}`.

## Shared Mailbox Workflows

### Team Triage Pattern

```text
1. CLAIM: Assign yourself before acting
   - Move to sub-folder: support@/Assigned/alice/
   - Or set keyword: $assigned-alice

2. ACT: Handle the message (reply from shared address, CC if escalating)

3. RESOLVE: Mark as handled
   - Move to Archive/ or set keyword: $resolved

4. REVIEW: Periodic sweep of unclaimed messages
   - Messages in INBOX older than SLA threshold --> alert
   - Messages assigned but not resolved --> follow up
```

### Common Shared Addresses

| Address | Purpose | SLA |
|---------|---------|-----|
| `support@` | Customer support (round-robin) | 4h first response |
| `info@` | General inquiries | 24h |
| `sales@` | Sales inquiries | 2h |
| `billing@` | Payment issues | 24h |
| `security@` | Security reports | 1h |
| `accounts@` | Financial documents | 48h |

```bash
# Round-robin assignment for support@
email-agent-helper.sh triage --mailbox support@ --strategy round-robin \
  --assignees alice,bob,carol

# Priority-based: route VIP senders to senior staff
email-agent-helper.sh triage --mailbox support@ --strategy priority \
  --vip-domains "bigclient.com,enterprise.co" --vip-assignee alice
```

## Archiving Rules

Archive a message when ALL are true: all replies sent, associated task complete, no pending follow-up within 7 days. Otherwise flag instead of archiving.

### Archive Structure

```text
Archive/
  Archive/2026/              # Year-based for general correspondence
  Archive/Projects/acme/     # Project-based for ongoing work
  Archive/Clients/bigcorp/   # Client-based for business
  Archive/Legal/             # Contracts, agreements (7+ year retention)
  Archive/Financial/         # Tax-relevant (7-year retention)
```

### Retention Policy

| Category | Retention |
|----------|-----------|
| Legal/contracts | 7+ years |
| Financial/tax | 7 years |
| Client correspondence | 3 years |
| Project archives | 1 year after project close |
| General correspondence | 1 year |
| Promotions | 30 days |
| Junk | 0 days (auto-delete) |

## Threading Guidance

**Reply in existing thread when**: same topic, last message < 30 days old, same recipient set, continuing a conversation.

**Start a new thread when**: topic changed, > 30 days since last message, recipient set changed significantly, thread > 20 messages, introducing a new decision/request/deliverable.

**IMAP**: Use `In-Reply-To` and `References` headers. `THREAD` extension (RFC 5256) provides server-side threading.

**JMAP**: Native `Thread` objects. Use `Thread/get` and `Email/query` with `inThread` filter.

## Smart Mailbox Patterns

| Smart Mailbox | Criteria | Purpose |
|---------------|----------|---------|
| **Flagged - Action Required** | Any taxonomy flag set | Single view of all actionable items |
| **Awaiting Reply** | Sent by me, no reply, < 7 days old | Follow-up tracking |
| **VIP Inbox** | From contacts marked as VIP | Priority attention |
| **This Week** | Received in last 7 days, in Primary | Current conversation focus |
| **Unread Important** | Unread AND (Primary OR from VIP) | Triage starting point |

### IMAP Search Queries

```text
# Flagged action items
SEARCH KEYWORD $Task OR KEYWORD $Reminder OR KEYWORD $Review

# Awaiting reply (sent by me, no answer)
SEARCH FROM "me@example.com" UNANSWERED SINCE 01-Mar-2026

# This week's primary mail
SEARCH SINCE 09-Mar-2026 NOT KEYWORD $promotion NOT KEYWORD $update
```

### JMAP Filters

```json
{
  "operator": "AND",
  "conditions": [
    { "inMailbox": "inbox-id" },
    { "operator": "OR", "conditions": [
      { "hasKeyword": "$task" },
      { "hasKeyword": "$reminder" }
    ]}
  ]
}
```

## Transaction Receipt and Invoice Forwarding

### Detection Rules (evaluate in order)

```text
1. Sender domain match (high confidence):
   - receipts@, billing@, invoices@, noreply@ from known vendors
   - Domains: paypal.com, stripe.com, amazon.com, apple.com, etc.

2. Subject line patterns (medium confidence):
   - "Receipt for...", "Invoice #...", "Order confirmation"
   - "Payment received", "Subscription renewed"

3. Body content patterns (supporting evidence):
   - Currency amounts: $, EUR, GBP followed by digits
   - "Total:", "Amount:", "Subtotal:", "Tax:"
   - PDF attachments named *invoice*, *receipt*, *statement*

4. Structured data (high confidence):
   - schema.org/Invoice or schema.org/Order markup
```

### Phishing Verification Before Forwarding

**Never forward a transaction email to accounts@ without phishing verification.**

```text
ALL must pass:
1. SPF/DKIM/DMARC: Authentication-Results shows "spf=pass" AND "dkim=pass"
2. Sender domain: matches expected vendor domain exactly (watch typosquatting)
3. Link inspection: all URLs point to expected vendor domain (watch redirects)
4. Attachment safety: filenames match expected patterns (watch double extensions)
5. Amount reasonableness: within expected range for this vendor
```

```bash
# Auto-forward verified transaction emails to accounts@
email-agent-helper.sh forward-receipt --from inbox --to accounts@ \
  --verify-phishing --attach-original
```

## Sieve Rule Patterns

Sieve (RFC 5228) is server-side mail filtering supported by most IMAP servers (Dovecot, Cyrus, Fastmail, Proton Mail). Rules execute before delivery.

### Basic Category Sorting

```sieve
require ["fileinto", "imap4flags"];

# Transactions: known financial senders
if address :domain :is "from" [
    "paypal.com", "stripe.com", "amazon.com", "apple.com", "google.com", "xero.com"
] {
    if header :contains "subject" [
        "receipt", "invoice", "payment", "order confirmation", "subscription", "billing"
    ] {
        fileinto "Transactions";
        stop;
    }
}

# Updates: automated notifications
if anyof (
    header :contains "List-Unsubscribe" "",
    header :contains "X-Mailer" ["GitHub", "GitLab", "Jira"],
    header :contains "from" ["noreply@", "notifications@", "alerts@"]
) {
    if not header :contains "subject" ["sale", "offer", "discount", "deal", "promo"] {
        fileinto "Updates";
        stop;
    }
}

# Promotions: marketing and bulk
if anyof (
    header :contains "List-Unsubscribe" "",
    header :contains "Precedence" "bulk"
) {
    if header :contains "subject" [
        "sale", "offer", "discount", "deal", "promo", "newsletter", "weekly digest"
    ] {
        fileinto "Promotions";
        stop;
    }
}
# Everything else stays in INBOX (Primary)
```

### Flag Assignment via Sieve

```sieve
require ["fileinto", "imap4flags"];

# Deadlines → Reminders
if header :contains "subject" ["deadline", "due by", "expires", "urgent", "action required"] {
    addflag "$Reminder";
}

# Action requests → Tasks
if header :contains "subject" ["please review", "approval needed", "please confirm", "rsvp"] {
    addflag "$Task";
}

# Contracts/legal → Review
if anyof (
    header :contains "subject" ["contract", "agreement", "proposal", "terms"],
    header :contains "Content-Type" "application/pdf"
) {
    addflag "$Review";
}
```

### Shared Mailbox Sieve Rules

```sieve
require ["fileinto", "imap4flags", "variables", "envelope"];

# Auto-assign based on sender domain
if envelope :domain :is "from" "bigclient.com" {
    fileinto "Assigned/alice";
    addflag "$assigned-alice";
    stop;
}

# Escalate security reports
if envelope :localpart :is "to" "security" {
    addflag "$urgent";
    fileinto "Assigned/security-lead";
    stop;
}

fileinto "Unassigned";
```

### ManageSieve Deployment

```bash
sieve-connect --server mail.example.com --user admin \
  --upload script.sieve --activate script.sieve

# Fastmail: Settings > Filters > Edit custom Sieve
# Proton Mail: Settings > Filters > Add Sieve filter
# Dovecot: place in ~/.dovecot.sieve or use ManageSieve
```

## IMAP vs JMAP Adapter Selection

The helper auto-detects the best protocol from provider config. JMAP is preferred when the provider has a `jmap.url` configured (e.g., Fastmail). Both adapters share the same SQLite metadata index.

**Use IMAP when**: server only supports IMAP, simple operations (fetch/move/flag/delete), bandwidth-constrained, compatibility is priority.

**Use JMAP when**: server supports JMAP (Fastmail, Cyrus 3.x, Apache James, Stalwart), complex queries, batch operations, native threading, push notifications.

### Adapter Comparison

| Feature | IMAP | JMAP |
|---------|------|------|
| Protocol | Text-based, stateful TCP | JSON over HTTP, stateless |
| Push notifications | IDLE (one folder) or NOTIFY | EventSource SSE |
| Batch operations | One command at a time | Multiple method calls per request |
| Threading | Extension (RFC 5256), not universal | Native Thread objects |
| Search | SEARCH command, limited operators | Rich FilterCondition, server-side |
| Custom flags | PERMANENTFLAGS dependent | Keywords (always supported) |
| Offline sync | CONDSTORE/QRESYNC extensions | State strings for delta sync |
| Message IDs | Integer UIDs (`--uid`) | String IDs (`--email-id`) |

### Configuration

```bash
# Check server capabilities
openssl s_client -connect mail.example.com:993 -quiet <<< "a1 CAPABILITY"  # IMAP
curl -s https://mail.example.com/.well-known/jmap | jq '.capabilities'      # JMAP

# Test connectivity
email-mailbox-helper.sh accounts --test
```

### JMAP Push Notifications

```bash
# Listen for new mail events (5 minute timeout)
email-mailbox-helper.sh push fastmail --timeout 300

# Listen for all event types
email-mailbox-helper.sh push fastmail --types mail,contacts,calendars
# Output: {"event_type":"state","data":{"changed":{...}},"timestamp":"..."}
```

```bash
# Store JMAP token (Fastmail app password works for both IMAP and JMAP)
aidevops secret set email-jmap-fastmail
```

## Search Patterns

### IMAP Search

```text
SEARCH TEXT "project proposal"
SEARCH SINCE 01-Jan-2026 BEFORE 01-Apr-2026
SEARCH FROM "alice@example.com" KEYWORD $Task
SEARCH LARGER 5000000
SEARCH OR (FROM "alice@example.com" SUBJECT "report") (FROM "bob@example.com" SUBJECT "report")
```

### JMAP Search

```json
{
  "accountId": "account-id",
  "filter": {
    "operator": "AND",
    "conditions": [
      { "text": "project proposal" },
      { "after": "2026-01-01T00:00:00Z" },
      { "before": "2026-04-01T00:00:00Z" },
      { "from": "alice@example.com" },
      { "hasKeyword": "$task" }
    ]
  },
  "sort": [{ "property": "receivedAt", "isAscending": false }],
  "limit": 50
}
```

## Troubleshooting

| Issue | Steps |
|-------|-------|
| **Messages not categorized** | Check Sieve script is active (`sieve-connect --list`), verify `require` includes needed extensions, test with `sieve-test`, check rule order (first match wins with `stop`) |
| **Flags not persisting** | Check `PERMANENTFLAGS` in IMAP SELECT response; if custom keywords not listed, use `\Flagged` + local database; JMAP keywords always persist |
| **Shared mailbox access** | Verify ACL permissions (`GETACL`), check shared namespace (`NAMESPACE`), ensure `lrswipcda` rights; for JMAP check `accountCapabilities` |
| **Search returns no results** | Verify full-text indexing enabled, check search scope, try `UID SEARCH` for IMAP consistency, verify `accountId` and `inMailbox` for JMAP |

## Related

- `services/email/email-agent.md` — Mission communication agent (send/receive/extract)
- `services/email/email-mailbox-search.md` — OS-level mailbox search (Spotlight, notmuch, mu)
- `services/email/ses.md` — Amazon SES sending configuration
- `services/email/email-testing.md` — Email deliverability testing
- `services/email/email-health-check.md` — Email infrastructure health checks
- `services/communications/cross-channel-conversation-continuity.md` — Entity-aware continuity patterns
- `scripts/email-agent-helper.sh` — Helper script for mailbox operations
- `scripts/mailbox-search-helper.sh` — Spotlight/notmuch/mu search helper (t1522)
- `scripts/email-to-markdown.py` — Email parsing pipeline
- `scripts/email-thread-reconstruction.py` — Thread building from raw messages
