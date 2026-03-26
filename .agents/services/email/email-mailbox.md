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

# Email Mailbox Agent

<!-- AI-CONTEXT-START -->

- **Protocols**: IMAP4rev1 (RFC 9051), JMAP (RFC 8621), ManageSieve (RFC 5804)
- **Helper**: `scripts/email-mailbox-helper.sh` (auto-detects protocol)
- **Adapters**: `scripts/email_imap_adapter.py`, `scripts/email_jmap_adapter.py`
- **Related**: `email-agent.md` (mission comms), `ses.md` (sending)
- **Category order**: Primary > Transactions > Updates > Promotions > Junk
- **Flag taxonomy**: Reminders | Tasks | Review | Filing | Ideas | Add-to-Contacts

<!-- AI-CONTEXT-END -->

## Category Assignment

Evaluate top-down; first match wins.

```text
Unsolicited / unknown sender with commercial intent? → Junk
Unknown sender, bulk/marketing? → Promotions
Unknown sender, automated notification? → Updates
Known sender, requires reply or personal/business conversation? → Primary
Receipt, invoice, shipping, financial statement? → Transactions
Status update, notification, automated alert? → Updates
Default → Promotions or Primary
```

| Category | Description |
|----------|-------------|
| **Primary** | Direct human conversation requiring attention |
| **Transactions** | Financial records — receipts, invoices, statements |
| **Updates** | Automated service notifications and alerts |
| **Promotions** | Marketing, newsletters, bulk commercial |
| **Junk** | Unsolicited, phishing, scams |

**IMAP folders**: `INBOX/` (triage) · `Archive/` · `Drafts/` · `Sent/` · `Trash/` · `Transactions/Receipts/` · `Transactions/Invoices/` · `Updates/` · `Promotions/` · `Junk/`

**Gmail**: labels only — category tabs not accessible via IMAP; use Gmail API or JMAP.
**POP3**: no folder concept; prefer IMAP/JMAP for shared or multi-device access.

## Flagging

Orthogonal to categories; multiple flags allowed.

| Flag | Assign when | Clear when | IMAP keyword |
|------|-------------|------------|--------------|
| **Reminders** | Deadline or time-sensitive | Acted on / deadline passed | `$Reminder` |
| **Tasks** | Action required (reply, approve) | Action completed | `$Task` |
| **Review** | Contract, spec, legal doc | Decision made | `$Review` |
| **Filing** | Belongs in project/reference archive | Filed | `$Filing` |
| **Ideas** | Inspiration for future use | Captured elsewhere | `$Idea` |
| **Add-to-Contacts** | New contact to save | Contact saved | `$AddContact` |

Check `PERMANENTFLAGS` — if custom keywords unsupported, use `\Flagged` + helper SQLite store.
JMAP: `Email/set` with `"keywords": {"$task": true, "$reminder": true}`.

## Shared Mailbox Workflows

Triage pattern: **CLAIM** (move to `Assigned/alice/` or set `$assigned-alice`) → **ACT** (reply from shared address) → **RESOLVE** (`Archive/` or `$resolved`) → **REVIEW** (sweep unclaimed; alert on SLA breach).

| Address | SLA | Address | SLA |
|---------|-----|---------|-----|
| `support@` | 4h | `billing@` | 24h |
| `info@` | 24h | `security@` | 1h |
| `sales@` | 2h | `accounts@` | 48h |

```bash
email-agent-helper.sh triage --mailbox support@ --strategy round-robin --assignees alice,bob,carol
email-agent-helper.sh triage --mailbox support@ --strategy priority --vip-domains "bigclient.com" --vip-assignee alice
```

## Archiving

Archive when ALL true: all replies sent, task complete, no follow-up within 7 days.

Structure: `Archive/2026/` (general) · `Archive/Projects/acme/` · `Archive/Clients/bigcorp/` · `Archive/Legal/` · `Archive/Financial/`

| Category | Retention |
|----------|-----------|
| Legal/contracts | 7+ years |
| Financial/tax | 7 years |
| Client correspondence | 3 years |
| Project archives | 1 year post-close |
| General | 1 year |
| Promotions | 30 days |
| Junk | 0 days (auto-delete) |

## Threading

**Reply in thread**: same topic, <30 days, same recipients.
**New thread**: topic changed, >30 days, recipients changed, >20 messages, new decision/deliverable.

IMAP: `In-Reply-To` + `References` headers; `THREAD` extension (RFC 5256).
JMAP: native `Thread` objects — `Thread/get`, `Email/query` with `inThread` filter.

## Smart Mailboxes

| Smart Mailbox | Criteria |
|---------------|----------|
| **Flagged - Action Required** | Any taxonomy flag set |
| **Awaiting Reply** | Sent by me, no reply, <7 days |
| **VIP Inbox** | From VIP contacts |
| **This Week** | Received last 7 days, Primary |
| **Unread Important** | Unread AND (Primary OR VIP) |

```text
# IMAP
SEARCH KEYWORD $Task OR KEYWORD $Reminder OR KEYWORD $Review
SEARCH FROM "me@example.com" UNANSWERED SINCE 01-Mar-2026
SEARCH TEXT "project proposal" SINCE 01-Jan-2026 BEFORE 01-Apr-2026
```

```json
{ "operator": "AND", "conditions": [
    { "inMailbox": "inbox-id" },
    { "operator": "OR", "conditions": [{ "hasKeyword": "$task" }, { "hasKeyword": "$reminder" }]}
]}
```

## Transaction Detection and Forwarding

Detection order: (1) sender domain — `receipts@`, `billing@`, `invoices@`, `noreply@` from known vendors; (2) subject — "Receipt for", "Invoice #", "Order confirmation", "Payment received"; (3) body — currency amounts, "Total:", PDF attachments named `*invoice*`/`*receipt*`; (4) structured data — `schema.org/Invoice` or `schema.org/Order`.

**Phishing check before forwarding to accounts@** — ALL must pass:
1. `Authentication-Results`: `spf=pass` AND `dkim=pass`
2. Sender domain matches expected vendor exactly (watch typosquatting)
3. All URLs point to expected vendor domain (watch redirects)
4. Attachment filenames match expected patterns (watch double extensions)
5. Amount within expected range for this vendor

```bash
email-agent-helper.sh forward-receipt --from inbox --to accounts@ --verify-phishing --attach-original
```

## Sieve Rules

Sieve (RFC 5228) — server-side, pre-delivery. Supported: Dovecot, Cyrus, Fastmail, Proton Mail.

```sieve
require ["fileinto", "imap4flags", "variables", "envelope"];

# Category sorting
if address :domain :is "from" ["paypal.com","stripe.com","amazon.com","apple.com","google.com","xero.com"] {
    if header :contains "subject" ["receipt","invoice","payment","order confirmation","subscription","billing"] {
        fileinto "Transactions"; stop;
    }
}
if anyof (
    header :contains "List-Unsubscribe" "",
    header :contains "X-Mailer" ["GitHub","GitLab","Jira"],
    header :contains "from" ["noreply@","notifications@","alerts@"]
) {
    if not header :contains "subject" ["sale","offer","discount","deal","promo"] {
        fileinto "Updates"; stop;
    }
}
if anyof (header :contains "List-Unsubscribe" "", header :contains "Precedence" "bulk") {
    if header :contains "subject" ["sale","offer","discount","deal","promo","newsletter","weekly digest"] {
        fileinto "Promotions"; stop;
    }
}
# Remainder → INBOX (Primary)

# Flag assignment
if header :contains "subject" ["deadline","due by","expires","urgent","action required"] { addflag "$Reminder"; }
if header :contains "subject" ["please review","approval needed","please confirm","rsvp"] { addflag "$Task"; }
if anyof (
    header :contains "subject" ["contract","agreement","proposal","terms"],
    header :contains "Content-Type" "application/pdf"
) { addflag "$Review"; }

# Shared mailbox routing
if envelope :domain :is "from" "bigclient.com" {
    fileinto "Assigned/alice"; addflag "$assigned-alice"; stop;
}
if envelope :localpart :is "to" "security" {
    addflag "$urgent"; fileinto "Assigned/security-lead"; stop;
}
fileinto "Unassigned";
```

```bash
sieve-connect --server mail.example.com --user admin --upload script.sieve --activate script.sieve
# Fastmail: Settings > Filters > Edit custom Sieve
# Proton Mail: Settings > Filters > Add Sieve filter  |  Dovecot: ~/.dovecot.sieve or ManageSieve
```

## IMAP vs JMAP

Auto-detected from provider config. JMAP preferred when `jmap.url` configured. Both share the same SQLite metadata index.

**Use IMAP**: server IMAP-only, simple ops, bandwidth-constrained, compatibility priority.
**Use JMAP**: Fastmail, Cyrus 3.x, Apache James, Stalwart — complex queries, batch ops, native threading, push.

Key differences: JMAP has native Thread objects, always-supported keywords, rich FilterCondition search, SSE push, and delta sync via state strings. IMAP uses integer UIDs (`--uid`); JMAP uses string IDs (`--email-id`).

```bash
openssl s_client -connect mail.example.com:993 -quiet <<< "a1 CAPABILITY"  # IMAP caps
curl -s https://mail.example.com/.well-known/jmap | jq '.capabilities'      # JMAP caps
email-mailbox-helper.sh accounts --test
email-mailbox-helper.sh push fastmail --timeout 300 --types mail,contacts,calendars
aidevops secret set email-jmap-fastmail
```

## Troubleshooting

| Issue | Steps |
|-------|-------|
| **Messages not categorized** | Check Sieve active (`sieve-connect --list`), verify `require` extensions, test with `sieve-test`, check rule order (first `stop` wins) |
| **Flags not persisting** | Check `PERMANENTFLAGS` in IMAP SELECT; if custom keywords absent, use `\Flagged` + local DB; JMAP keywords always persist |
| **Shared mailbox access** | Verify ACL (`GETACL`), check namespace (`NAMESPACE`), ensure `lrswipcda` rights; JMAP: check `accountCapabilities` |
| **Search returns nothing** | Verify full-text indexing, check scope, try `UID SEARCH` for IMAP; verify `accountId` and `inMailbox` for JMAP |

## Related

`email-agent.md` · `email-mailbox-search.md` · `ses.md` · `email-testing.md` · `email-health-check.md`
Scripts: `email-agent-helper.sh` · `mailbox-search-helper.sh` · `email-to-markdown.py` · `email-thread-reconstruction.py`
