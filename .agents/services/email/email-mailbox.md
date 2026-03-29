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
- **Related**: `email-agent.md` (mission comms), `ses.md` (sending), `email-mailbox-search.md`, `email-testing.md`, `email-health-check.md`
- **Flag taxonomy**: Reminders | Tasks | Review | Filing | Ideas | Add-to-Contacts

<!-- AI-CONTEXT-END -->

## Category Assignment

Top-down; first match wins.

| Category | Assign when | IMAP folder |
|----------|-------------|-------------|
| **Junk** | Unsolicited / unknown sender, commercial intent | `Junk/` |
| **Promotions** | Unknown sender, bulk/marketing | `Promotions/` |
| **Updates** | Unknown sender, automated notification/status alert | `Updates/` |
| **Transactions** | Receipt, invoice, shipping, financial statement | `Transactions/Receipts/` or `Transactions/Invoices/` |
| **Primary** | Known sender, requires reply or personal/business conversation | `INBOX/` |

Other folders: `Archive/` · `Drafts/` · `Sent/` · `Trash/`. Gmail: labels only — category tabs inaccessible via IMAP; use Gmail API or JMAP. POP3: no folder concept; prefer IMAP/JMAP.

## Flagging

Orthogonal to categories; multiple flags allowed. If `PERMANENTFLAGS` lacks custom keywords, fall back to `\Flagged` + helper SQLite store. JMAP: `Email/set` with `"keywords": {"$task": true}`.

| Flag | Assign when | Clear when | IMAP keyword |
|------|-------------|------------|--------------|
| **Reminders** | Deadline or time-sensitive | Acted on / deadline passed | `$Reminder` |
| **Tasks** | Action required (reply, approve) | Action completed | `$Task` |
| **Review** | Contract, spec, legal doc | Decision made | `$Review` |
| **Filing** | Belongs in project/reference archive | Filed | `$Filing` |
| **Ideas** | Inspiration for future use | Captured elsewhere | `$Idea` |
| **Add-to-Contacts** | New contact to save | Contact saved | `$AddContact` |

## Shared Mailbox Workflows

Triage pattern: **CLAIM** → **ACT** → **RESOLVE** → **REVIEW** (sweep unclaimed; alert on SLA breach).

SLAs: `security@` 1h · `sales@` 2h · `support@` 4h · `info@`/`billing@` 24h · `accounts@` 48h

```bash
email-agent-helper.sh triage --mailbox support@ --strategy round-robin --assignees alice,bob,carol
email-agent-helper.sh triage --mailbox support@ --strategy priority --vip-domains "bigclient.com" --vip-assignee alice
```

## Transaction Detection and Forwarding

Detection order: (1) sender domain — `receipts@`, `billing@`, `invoices@`, `noreply@`; (2) subject — "Receipt for", "Invoice #", "Order confirmation"; (3) body — currency amounts, "Total:", PDF `*invoice*`/`*receipt*`; (4) structured data — `schema.org/Invoice` or `schema.org/Order`.

**Phishing check before forwarding to accounts@** — ALL must pass:

1. `spf=pass` AND `dkim=pass` in `Authentication-Results`
2. Sender domain matches expected vendor exactly (watch typosquatting)
3. All URLs point to expected vendor domain (watch redirects)
4. Attachment filenames match expected patterns (watch double extensions)
5. Amount within expected range for this vendor

```bash
email-agent-helper.sh forward-receipt --from inbox --to accounts@ --verify-phishing --attach-original
```

## Archiving

Archive when ALL true: replies sent, task complete, no follow-up within 7 days. Structure: `Archive/{year}/` · `Archive/Projects/{name}/` · `Archive/Clients/{name}/` · `Archive/Legal/` · `Archive/Financial/`

| Category | Retention |
|----------|-----------|
| Legal/contracts | 7+ years |
| Financial/tax | 7 years |
| Client correspondence | 3 years |
| Project archives | 1 year post-close |
| General | 1 year |
| Promotions | 30 days |
| Junk | 0 days (auto-delete) |

## Smart Mailboxes and Threading

**Threading**: reply in-thread when same topic, <30 days, same recipients. Start new thread when topic changed, >30 days, recipients changed, >20 messages, or new decision needed. IMAP: `In-Reply-To`/`References` + RFC 5256 `THREAD`. JMAP: native `Thread` objects.

| Smart Mailbox | Criteria |
|---------------|----------|
| **Flagged - Action Required** | Any taxonomy flag set |
| **Awaiting Reply** | Sent by me, no reply, <7 days |
| **VIP Inbox** | From VIP contacts |
| **This Week** | Received last 7 days, Primary |
| **Unread Important** | Unread AND (Primary OR VIP) |

```text
# IMAP search
SEARCH KEYWORD $Task OR KEYWORD $Reminder OR KEYWORD $Review
SEARCH FROM "me@example.com" UNANSWERED SINCE 01-Mar-2026
SEARCH TEXT "project proposal" SINCE 01-Jan-2026 BEFORE 01-Apr-2026
# JMAP FilterCondition
{ "operator": "AND", "conditions": [{ "inMailbox": "inbox-id" },
  { "operator": "OR", "conditions": [{ "hasKeyword": "$task" }, { "hasKeyword": "$reminder" }]}]}
```

## Sieve Rules

Server-side, pre-delivery (RFC 5228). Supported: Dovecot, Cyrus, Fastmail, Proton Mail.

```sieve
require ["fileinto", "imap4flags", "variables", "envelope"];
# Transactions
if address :domain :is "from" ["paypal.com","stripe.com","amazon.com","apple.com","google.com","xero.com"] {
    if header :contains "subject" ["receipt","invoice","payment","order confirmation","billing"] { fileinto "Transactions"; stop; }
}
# Updates
if anyof (header :contains "List-Unsubscribe" "", header :contains "X-Mailer" ["GitHub","GitLab","Jira"],
          header :contains "from" ["noreply@","notifications@","alerts@"]) {
    if not header :contains "subject" ["sale","offer","discount","deal","promo"] { fileinto "Updates"; stop; }
}
# Promotions
if anyof (header :contains "List-Unsubscribe" "", header :contains "Precedence" "bulk") {
    if header :contains "subject" ["sale","offer","discount","deal","promo","newsletter"] { fileinto "Promotions"; stop; }
}
# Flags
if header :contains "subject" ["deadline","due by","expires","urgent","action required"] { addflag "$Reminder"; }
if header :contains "subject" ["please review","approval needed","please confirm","rsvp"] { addflag "$Task"; }
if anyof (header :contains "subject" ["contract","agreement","proposal","terms"],
          header :contains "Content-Type" "application/pdf") { addflag "$Review"; }
# Shared mailbox routing
if envelope :domain :is "from" "bigclient.com" { fileinto "Assigned/alice"; addflag "$assigned-alice"; stop; }
if envelope :localpart :is "to" "security" { addflag "$urgent"; fileinto "Assigned/security-lead"; stop; }
fileinto "Unassigned";
```

Upload/activate: `sieve-connect --server mail.example.com --user admin --upload script.sieve --activate script.sieve`. Fastmail: Settings > Filters > Edit custom Sieve. Proton Mail: Settings > Filters > Add Sieve filter. Dovecot: `~/.dovecot.sieve` or ManageSieve.

## IMAP vs JMAP

Auto-detected from provider config; JMAP preferred when `jmap.url` configured. Both share the same SQLite metadata index.

| | IMAP | JMAP |
|-|------|------|
| **Use when** | IMAP-only server, simple ops, bandwidth-constrained | Fastmail, Cyrus 3.x, Apache James, Stalwart |
| **IDs** | Integer UIDs (`--uid`) | String IDs (`--email-id`) |
| **Keywords** | Check `PERMANENTFLAGS` | Always supported |
| **Threading** | RFC 5256 extension | Native `Thread` objects |
| **Push** | Poll only | SSE push + delta sync via state strings |

```bash
openssl s_client -connect mail.example.com:993 -quiet <<< "a1 CAPABILITY"  # IMAP caps
curl -s https://mail.example.com/.well-known/jmap | jq '.capabilities'      # JMAP caps
email-mailbox-helper.sh accounts --test
email-mailbox-helper.sh push fastmail --timeout 300 --types mail,contacts,calendars
```

## Troubleshooting

| Issue | Steps |
|-------|-------|
| **Messages not categorized** | Check Sieve active (`sieve-connect --list`), verify `require` extensions, test with `sieve-test`, check rule order (first `stop` wins) |
| **Flags not persisting** | Check `PERMANENTFLAGS` in IMAP SELECT; if custom keywords absent, use `\Flagged` + local DB; JMAP keywords always persist |
| **Shared mailbox access** | Verify ACL (`GETACL`), check namespace (`NAMESPACE`), ensure `lrswipcda` rights; JMAP: check `accountCapabilities` |
| **Search returns nothing** | Verify full-text indexing, check scope, try `UID SEARCH` for IMAP; verify `accountId` and `inMailbox` for JMAP |
