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
- **Helper**: `scripts/email-agent-helper.sh` (mailbox operations via configured adapter)
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
  NO  --> continue

Is the message a newsletter, marketing email, or promotional offer?
  YES --> Promotions
  NO  --> Primary (default for ambiguous messages from known senders)
```

### Category Definitions

| Category | Description | Examples |
|----------|-------------|---------|
| **Primary** | Direct human conversation requiring attention or reply | Client emails, colleague messages, personal correspondence |
| **Transactions** | Financial records and purchase confirmations | Receipts, invoices, shipping confirmations, bank statements, subscription renewals |
| **Updates** | Automated notifications from services you use | CI/CD alerts, calendar reminders, app notifications, security alerts, account activity |
| **Promotions** | Marketing and bulk commercial email | Newsletters, sales offers, product announcements, event invitations from mailing lists |
| **Junk/Spam** | Unsolicited, unwanted, or malicious email | Phishing attempts, unsolicited bulk, scams, spoofed senders |

### IMAP Folder Structure

Map categories to IMAP folders. Most providers support these as standard or via custom folders.

```text
INBOX/                      # Unsorted incoming (triage target)
INBOX/Primary/              # Or just INBOX after triage
Archive/                    # Completed conversations
Drafts/
Sent/
Transactions/               # Receipts, invoices, financial
  Transactions/Receipts/    # Optional sub-folder for high volume
  Transactions/Invoices/
Updates/                    # Notifications, alerts
Promotions/                 # Newsletters, marketing
Junk/                       # Spam (auto-managed by server)
Trash/
```

**Gmail label mapping**: Gmail uses labels instead of IMAP folders. The IMAP interface exposes labels as folders under `[Gmail]/`. Custom labels appear as top-level IMAP folders. Category tabs (Primary, Social, Promotions, Updates, Forums) are not directly accessible via IMAP -- use the Gmail API or JMAP for category-level operations.

**POP3 limitations**: POP3 has no folder concept. It downloads from INBOX only. For shared mailboxes or multi-device access, always prefer IMAP or JMAP. POP3 is acceptable only for single-device archive-and-delete workflows.

## Flagging Taxonomy

Flags are orthogonal to categories. A message in any category can carry one or more flags. Use flags to track required actions, not to re-categorize.

### Flag Definitions

| Flag | Meaning | Action Required | Clear When |
|------|---------|-----------------|------------|
| **Reminders** | Time-sensitive -- needs attention by a specific date | Set a calendar reminder or follow-up | Reminder acted on or deadline passed |
| **Tasks** | Requires a concrete action (reply, create something, approve) | Complete the action | Action completed |
| **Review** | Read carefully -- contract, proposal, technical doc, legal | Read thoroughly and decide | Decision made |
| **Filing** | Archive to a specific project or reference folder | Move to the correct archive sub-folder | Filed |
| **Ideas** | Inspiration, interesting link, future reference | Capture in notes/bookmarks when convenient | Captured elsewhere |
| **Add-to-Contacts** | New contact -- save their details | Add to contacts/CRM | Contact saved |

### Flag Assignment Decision Tree

```text
Does the message contain a deadline, due date, or time-sensitive request?
  YES --> flag: Reminders
  (also check below for additional flags)

Does the message ask you to DO something (reply, approve, create, send, fix)?
  YES --> flag: Tasks

Does the message contain a document that needs careful reading (contract, proposal, spec)?
  YES --> flag: Review

Does the message belong in a project archive or reference folder?
  YES --> flag: Filing

Does the message contain an idea, link, or inspiration for future use?
  YES --> flag: Ideas

Is this from a new contact whose details should be saved?
  YES --> flag: Add-to-Contacts
```

### IMAP Flag Implementation

IMAP supports system flags (`\Flagged`, `\Seen`, `\Answered`, `\Draft`, `\Deleted`) and custom keywords. Map the taxonomy to IMAP keywords:

```text
IMAP keyword          Taxonomy flag
$Reminder             Reminders
$Task                 Tasks
$Review               Review
$Filing               Filing
$Idea                 Ideas
$AddContact           Add-to-Contacts
```

Not all IMAP servers support custom keywords (the `PERMANENTFLAGS` response indicates support). Fallback: use `\Flagged` as a generic "needs attention" flag and track the specific taxonomy in a local database or the helper script's SQLite store.

**JMAP keywords**: JMAP (RFC 8621) uses the same keyword mechanism but with better semantics. Set keywords via the `Email/set` method: `"keywords": {"$task": true, "$reminder": true}`.

## Shared Mailbox Workflows

### Team Triage Pattern

Shared mailboxes (e.g., `support@`, `info@`, `sales@`) need a triage workflow to prevent duplicate handling and dropped messages.

```text
1. CLAIM: Assign yourself to a message before acting on it
   - Move to your personal sub-folder: support@/Assigned/alice/
   - Or set a custom keyword: $assigned-alice
   - Or use IMAP ANNOTATE extension if supported

2. ACT: Handle the message (reply, forward, escalate)
   - Reply from the shared address (not personal)
   - CC relevant team members if escalating

3. RESOLVE: Mark as handled
   - Move to Archive/ with resolution note
   - Or set keyword: $resolved

4. REVIEW: Periodic sweep of unclaimed messages
   - Messages in INBOX older than SLA threshold --> alert
   - Messages assigned but not resolved --> follow up
```

### Common Shared Addresses

| Address | Purpose | Triage Owner | SLA |
|---------|---------|-------------|-----|
| `support@` | Customer support | Support team (round-robin) | 4h first response |
| `info@` | General inquiries | Office manager | 24h |
| `sales@` | Sales inquiries | Sales team lead | 2h |
| `billing@` | Payment issues | Accounts team | 24h |
| `security@` | Security reports | Security lead | 1h |
| `accounts@` | Financial documents | Accounts team | 48h |

### Assignment Routing

For automated assignment, use server-side Sieve rules (see below) or the helper script:

```bash
# Round-robin assignment for support@
email-agent-helper.sh triage --mailbox support@ --strategy round-robin \
  --assignees alice,bob,carol

# Priority-based: route VIP senders to senior staff
email-agent-helper.sh triage --mailbox support@ --strategy priority \
  --vip-domains "bigclient.com,enterprise.co" --vip-assignee alice
```

## Archiving Rules

### When to Archive

Archive a message from the inbox when ALL of these are true:

1. All required replies have been sent
2. Any associated task is complete (or tracked elsewhere)
3. No pending follow-up is expected within 7 days

If any condition is false, flag the message instead of archiving:

- Awaiting reply --> flag: Reminders (set follow-up date)
- Task incomplete --> flag: Tasks
- Needs careful reading first --> flag: Review

### Archive Structure

```text
Archive/
  Archive/2026/              # Year-based for general correspondence
  Archive/Projects/          # Project-based for ongoing work
    Archive/Projects/acme/
    Archive/Projects/website-redesign/
  Archive/Clients/           # Client-based for business
    Archive/Clients/bigcorp/
  Archive/Legal/             # Contracts, agreements (long retention)
  Archive/Financial/         # Tax-relevant (7-year retention)
```

### Retention Policy

| Category | Retention | Rationale |
|----------|-----------|-----------|
| Legal/contracts | 7+ years | Statutory requirements |
| Financial/tax | 7 years | Tax audit window |
| Client correspondence | 3 years | Business relationship lifecycle |
| Project archives | 1 year after project close | Reference period |
| General correspondence | 1 year | Diminishing relevance |
| Promotions | 30 days | No long-term value |
| Junk | 0 days (auto-delete) | No value |

## Threading Guidance

### Reply in Existing Thread When

- The topic is the same as the original message
- The last message in the thread is less than 30 days old
- The recipient set is the same (or a subset)
- You are continuing a conversation, not starting a new topic

### Start a New Thread When

- The topic has changed, even if the participants are the same
- More than 30 days have passed since the last message
- The recipient set has changed significantly
- The original thread has more than 20 messages (readability)
- You are introducing a new decision, request, or deliverable

### Threading Implementation

**IMAP threading**: Use `In-Reply-To` and `References` headers. The `THREAD` IMAP extension (RFC 5256) provides server-side threading via `REFERENCES` or `ORDEREDSUBJECT` algorithms.

**JMAP threading**: JMAP provides native `Thread` objects. Use `Thread/get` to retrieve thread structure and `Email/query` with `inThread` filter to find all messages in a thread.

```text
Decision: reply or new thread?

Is the topic the same as the original?
  NO  --> New thread
  YES --> continue

Is the last message older than 30 days?
  YES --> New thread (reference the old thread in the opening line)
  NO  --> continue

Has the recipient set changed significantly (>50% different)?
  YES --> New thread (CC relevant people from old thread)
  NO  --> Reply in thread
```

## Smart Mailbox Patterns

Smart mailboxes (virtual folders) are server-side saved searches or client-side filters that aggregate messages matching criteria without moving them.

### Recommended Smart Mailboxes

| Smart Mailbox | Criteria | Purpose |
|---------------|----------|---------|
| **Flagged - Action Required** | Any flag from taxonomy is set | Single view of all actionable items |
| **Awaiting Reply** | Sent by me, no reply received, < 7 days old | Follow-up tracking |
| **VIP Inbox** | From contacts marked as VIP | Priority attention |
| **This Week** | Received in last 7 days, in Primary | Current conversation focus |
| **Attachments** | Has attachments, received in last 30 days | Quick file finding |
| **Unread Important** | Unread AND (Primary OR from VIP) | Triage starting point |

### IMAP Search Queries

IMAP SEARCH (RFC 9051) supports these for smart mailbox implementation:

```text
# Flagged action items
SEARCH KEYWORD $Task OR KEYWORD $Reminder OR KEYWORD $Review

# Awaiting reply (sent by me, no answer)
SEARCH FROM "me@example.com" UNANSWERED SINCE 01-Mar-2026

# VIP inbox (multiple senders)
SEARCH OR FROM "ceo@bigclient.com" FROM "lead@partner.co"

# This week's primary mail
SEARCH SINCE 09-Mar-2026 NOT KEYWORD $promotion NOT KEYWORD $update

# Unread with attachments
SEARCH UNSEEN HEADER Content-Type "multipart/mixed"
```

### JMAP Filters

JMAP provides richer filtering via `FilterCondition` objects:

```json
{
  "inMailbox": "inbox-id",
  "after": "2026-03-09T00:00:00Z",
  "hasKeyword": "$task",
  "from": "vip@example.com",
  "hasAttachment": true
}
```

Combine with `FilterOperator` for complex queries:

```json
{
  "operator": "AND",
  "conditions": [
    { "inMailbox": "inbox-id" },
    {
      "operator": "OR",
      "conditions": [
        { "hasKeyword": "$task" },
        { "hasKeyword": "$reminder" }
      ]
    }
  ]
}
```

## Transaction Receipt and Invoice Forwarding

### Detection Rules

Identify transaction emails by matching against these patterns (evaluate in order):

```text
1. Sender domain match (high confidence):
   - receipts@, billing@, invoices@, noreply@ from known vendors
   - Domains: paypal.com, stripe.com, amazon.com, apple.com, etc.

2. Subject line patterns (medium confidence):
   - "Receipt for...", "Invoice #...", "Order confirmation"
   - "Payment received", "Subscription renewed"
   - "Your [purchase|order|payment|subscription]"

3. Body content patterns (supporting evidence):
   - Currency amounts: $, EUR, GBP followed by digits
   - "Total:", "Amount:", "Subtotal:", "Tax:"
   - Order/invoice/receipt numbers
   - PDF attachments named *invoice*, *receipt*, *statement*

4. Structured data (high confidence):
   - schema.org/Invoice or schema.org/Order markup
   - MIME type application/pdf with financial keywords in filename
```

### Phishing Verification Before Forwarding

**Never forward a transaction email to accounts@ without phishing verification.** Attackers craft fake invoices to trick payment processing.

```text
Phishing check (ALL must pass):

1. SPF/DKIM/DMARC: Authentication-Results header shows pass
   - Check: Authentication-Results header contains "spf=pass" AND "dkim=pass"
   - Fail action: quarantine, do NOT forward

2. Sender domain: matches the expected vendor domain exactly
   - Check: From header domain matches known vendor list
   - Watch for: typosquatting (amaz0n.com), subdomain tricks (amazon.com.evil.com)
   - Fail action: quarantine, flag for manual review

3. Link inspection: all URLs point to the expected vendor domain
   - Check: href domains in HTML body match From domain
   - Watch for: URL shorteners, redirects, mismatched display text vs href
   - Fail action: strip links, forward body text only

4. Attachment safety: PDFs and documents are from expected senders
   - Check: attachment filenames match expected patterns
   - Watch for: .exe, .scr, .js disguised as .pdf; double extensions
   - Fail action: strip attachments, note in forwarding message

5. Amount reasonableness: invoice amount is within expected range
   - Check: extracted amount against historical range for this vendor
   - Watch for: unusually large amounts, round numbers, urgency language
   - Fail action: flag for manual review before forwarding
```

### Forwarding Workflow

```bash
# Auto-forward verified transaction emails to accounts@
email-agent-helper.sh forward-receipt --from inbox --to accounts@ \
  --verify-phishing --attach-original

# Manual forward with override (when auto-detection misses)
email-agent-helper.sh forward-receipt --message-id <id> --to accounts@ \
  --category invoice --skip-detection
```

## Sieve Rule Patterns

Sieve (RFC 5228) is a server-side mail filtering language supported by most IMAP servers (Dovecot, Cyrus, Fastmail, Proton Mail, etc.). Rules execute before delivery, so they work even when no client is connected.

### Basic Category Sorting

```sieve
require ["fileinto", "imap4flags"];

# Transactions: known financial senders
if address :domain :is "from" [
    "paypal.com", "stripe.com", "amazon.com",
    "apple.com", "google.com", "xero.com"
] {
    if header :contains "subject" [
        "receipt", "invoice", "payment", "order confirmation",
        "subscription", "billing", "statement"
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
    if not header :contains "subject" [
        "sale", "offer", "discount", "deal", "promo"
    ] {
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
        "sale", "offer", "discount", "deal", "promo",
        "newsletter", "weekly digest", "monthly update"
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

# Flag messages with deadlines as Reminders
if header :contains "subject" [
    "deadline", "due by", "expires", "urgent",
    "action required", "response needed by"
] {
    addflag "$Reminder";
}

# Flag messages requesting action as Tasks
if header :contains "subject" [
    "please review", "approval needed", "action required",
    "please confirm", "sign and return", "rsvp"
] {
    addflag "$Task";
}

# Flag contracts and legal documents for Review
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

# Auto-assign based on sender domain (for support@ mailbox)
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

# Default: unassigned queue
fileinto "Unassigned";
```

### ManageSieve Deployment

Upload Sieve scripts via ManageSieve (RFC 5804):

```bash
# Using sieveshell (Cyrus) or sieve-connect
sieve-connect --server mail.example.com --user admin \
  --upload script.sieve --activate script.sieve

# Fastmail: upload via Settings > Filters > Edit custom Sieve
# Proton Mail: upload via Settings > Filters > Add Sieve filter
# Dovecot: place in ~/.dovecot.sieve or use ManageSieve
```

## IMAP vs JMAP Adapter Selection

### When to Use IMAP

- Server only supports IMAP (most self-hosted, older providers)
- Simple operations: fetch, move, flag, delete
- Bandwidth-constrained environments (IMAP IDLE is efficient for push)
- Compatibility is the priority

### When to Use JMAP

- Server supports JMAP (Fastmail, Cyrus 3.x, Apache James)
- Complex queries: multi-condition filters, server-side sorting
- Batch operations: update many messages in one request
- Bandwidth efficiency for bulk operations (binary JSON, delta sync)
- Native threading support needed

### Adapter Comparison

| Feature | IMAP | JMAP |
|---------|------|------|
| Protocol | Text-based, stateful TCP | JSON over HTTP, stateless |
| Push notifications | IDLE (one folder) or NOTIFY | Event source / push subscription |
| Batch operations | One command at a time | Multiple method calls per request |
| Threading | Extension (RFC 5256), not universal | Native Thread objects |
| Search | SEARCH command, limited operators | Rich FilterCondition, server-side |
| Folder management | CREATE/DELETE/RENAME | Mailbox/set method |
| Custom flags | PERMANENTFLAGS dependent | Keywords (always supported) |
| Offline sync | CONDSTORE/QRESYNC extensions | State strings for delta sync |
| Attachment handling | FETCH BODY sections | Blob download by ID |

### Configuration

```bash
# Check server capabilities
# IMAP
openssl s_client -connect mail.example.com:993 -quiet <<< "a1 CAPABILITY"

# JMAP
curl -s https://mail.example.com/.well-known/jmap | jq '.capabilities'
```

## Search Patterns

### IMAP Search

```text
# Full-text search (if server supports SEARCH=TEXT)
SEARCH TEXT "project proposal"

# Date range
SEARCH SINCE 01-Jan-2026 BEFORE 01-Apr-2026

# From specific sender with keyword
SEARCH FROM "alice@example.com" KEYWORD $Task

# Large messages (attachments)
SEARCH LARGER 5000000

# Combine with OR
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
  "position": 0,
  "limit": 50
}
```

## Troubleshooting

### Messages Not Categorized

1. Check Sieve script is active: `sieve-connect --list`
2. Verify Sieve `require` includes needed extensions
3. Test with `sieve-test` (Dovecot) or provider's test tool
4. Check rule order -- first matching rule wins with `stop`

### Flags Not Persisting

1. Check `PERMANENTFLAGS` in IMAP SELECT response
2. If custom keywords not listed, server does not support them
3. Fallback: use `\Flagged` + local database for taxonomy tracking
4. JMAP: keywords always persist -- check `Email/set` response for errors

### Shared Mailbox Access Issues

1. Verify ACL permissions: `GETACL` IMAP command
2. Check shared namespace: `NAMESPACE` command shows shared prefix
3. Ensure all team members have `lrswipcda` rights (or equivalent)
4. For JMAP: check `accountCapabilities` for shared account access

### Search Returns No Results

1. Verify full-text indexing is enabled on server
2. Check search scope (current folder vs all folders)
3. IMAP: try `UID SEARCH` instead of `SEARCH` for consistency
4. JMAP: verify `accountId` and `inMailbox` filter are correct

## Related

- `services/email/email-agent.md` -- Mission communication agent (send/receive/extract)
- `services/email/ses.md` -- Amazon SES sending configuration
- `services/email/email-testing.md` -- Email deliverability testing
- `services/email/email-health-check.md` -- Email infrastructure health checks
- `scripts/email-agent-helper.sh` -- Helper script for mailbox operations
- `scripts/email-to-markdown.py` -- Email parsing pipeline
- `scripts/email-thread-reconstruction.py` -- Thread building from raw messages
