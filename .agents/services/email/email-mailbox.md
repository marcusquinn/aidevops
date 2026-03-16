---
description: Email mailbox operations guide for categorization, triage, shared inboxes, and receipt routing
mode: subagent
tools:
  read: true
  write: false
  edit: false
  bash: true
  grep: true
  webfetch: false
---

# Email Mailbox Operations Guide

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Purpose**: Standardize mailbox organization, triage, and shared mailbox behavior
- **Category set**: Primary, Transactions, Updates, Promotions, Junk/Spam
- **Flag taxonomy**: Reminders, Tasks, Review, Filing, Ideas, Add-to-Contacts
- **Archive rule**: Archive once replied/completed; flag if follow-up is still required
- **Threading rule**: Stay in-thread for same topic; start new thread for topic change or stale thread (>30 days)
- **Shared mailbox model**: Intake -> classify -> assign owner -> resolve -> archive
- **Receipt handling**: Forward verified invoices/receipts to `accounts@` only after phishing checks
- **Filtering**: Prefer server-side Sieve for deterministic auto-sorting when available

<!-- AI-CONTEXT-END -->

Use this guide when handling inbound and outbound mailboxes to maintain consistent outcomes across personal and shared inboxes.

## Mailbox Organization Model

Treat category and flags as independent dimensions:

- **Category** answers: "What kind of message is this?"
- **Flag** answers: "What action does this require?"

This prevents action state from being lost when category changes.

### Categories

| Category | Use when | Typical signals |
|---|---|---|
| **Primary** | Human conversation or high-priority direct communication | Person-to-person exchange, direct ask, non-bulk language |
| **Transactions** | Receipts, invoices, confirmations, alerts with account relevance | Order IDs, invoice numbers, payment notifications |
| **Updates** | Product, project, account, or service updates not requiring immediate action | Changelog notices, status updates, release notes |
| **Promotions** | Marketing campaigns and sales outreach | Discount language, campaign templates, mailing-list markers |
| **Junk/Spam** | Untrusted, malicious, irrelevant, or low-quality mail | Phishing indicators, spoofing, obvious unsolicited bulk spam |

## Category Assignment Decision Tree

1. If sender or content is malicious/suspicious -> **Junk/Spam**
2. Else if it is a payment, receipt, invoice, order, renewal, billing, or account transaction -> **Transactions**
3. Else if it is direct human communication needing relationship continuity -> **Primary**
4. Else if it is informative lifecycle communication (status/change/update) -> **Updates**
5. Else if it is sales/marketing/newsletter content -> **Promotions**
6. Else default -> **Primary** (conservative fallback)

## Flagging Taxonomy

Apply exactly one primary flag per message. Add a second flag only when necessary (for example, `Tasks + Review`).

| Flag | Meaning | Trigger |
|---|---|---|
| **Reminders** | Time-sensitive follow-up needed later | Meeting follow-up, date-bound response, waiting on external event |
| **Tasks** | Concrete action required by owner/team | Request to do work, approval needed, deliverable requested |
| **Review** | Careful reading/analysis before action | Contract changes, policy updates, technical proposals |
| **Filing** | Keep for records, no active work | Closed thread with reference value |
| **Ideas** | Potential future initiative | Product/marketing ideas, exploratory suggestions |
| **Add-to-Contacts** | New useful sender identity should be captured | New vendor or stakeholder with future relevance |

### Flagging Rules

- If immediate action is required, prefer **Tasks** over **Reminders**
- If action depends on date/time, prefer **Reminders**
- If no action is required but record should be retained, use **Filing**
- If uncertain between **Tasks** and **Review**, choose **Review** first, then convert to **Tasks** after assessment

## Shared Mailbox Workflows

For mailboxes like `support@`, `sales@`, `accounts@`, `info@`, use explicit ownership handoff.

### Shared Inbox Lifecycle

1. **Intake**: New message arrives in shared mailbox
2. **Classify**: Assign category and flag
3. **Assign**: Set accountable owner (person or queue)
4. **Act**: Reply or execute requested work
5. **Resolve**: Confirm done, remove active ownership
6. **Archive**: Archive thread once no pending actions remain

### Assignment Policy

- Always assign exactly one owner for every active thread
- If multiple teams are involved, keep one driver and list collaborators in notes
- Reassign on role mismatch within same business day
- If unowned for >24h, escalate to triage lead

### Common Address Patterns

- `support@`: incident/help requests; prioritize SLA and response latency
- `sales@`: qualification, demos, partnerships; preserve thread continuity
- `accounts@`: invoices, receipts, billing disputes; enforce verification checks
- `info@`: general intake; route quickly to correct mailbox or owner

## Archive vs Flag Decision Tree

Archive now if all are true:

- Reply sent (if reply required)
- Requested work complete
- No follow-up date pending

Otherwise, do not archive yet:

- Apply flag (**Tasks**, **Reminders**, or **Review**)
- Keep in active queue until completion criteria are met

## Threading Guidance

Reply in existing thread when:

- Topic is unchanged
- Participants are materially the same
- Last relevant message is <= 30 days old

Start a new thread when:

- Topic changes significantly
- You need a distinct subject for discoverability
- Prior thread is stale (>30 days) and context reset is helpful
- Prior thread has excessive branching that risks confusion

When creating a new thread, include one-line context linking to prior conversation where useful.

## Smart Mailboxes / Sub-Mailboxes

Create focused views for high-value workflows:

- **By contact**: key partners, critical vendors, legal/accounting contacts
- **By project**: active initiatives needing cross-functional coordination
- **By domain**: `@bank`, `@processor`, `@client`, `@vendor`
- **By urgency**: pending replies, due this week, overdue follow-ups

Prefer non-destructive views (labels/virtual folders/searches) before creating physical folder sprawl.

## Receipt and Invoice Forwarding to `accounts@`

Forward only after validation.

### Validation Checklist

1. Sender/domain matches known vendor or verified new sender
2. Message content aligns with expected transaction context
3. Links/attachments pass phishing checks
4. No urgent credential/payment redirection anomalies

If checks pass:

- Forward to `accounts@` with original thread context retained
- Add a concise note: amount/date/vendor/action expected (if any)

If checks fail:

- Move to **Junk/Spam** or **Review** (depending on certainty)
- Do not forward financial artifacts until validated

## Phishing Protection Heuristics

Treat message as suspicious when one or more are present:

- Display-name/domain mismatch
- Urgent financial pressure with unusual destination changes
- Lookalike domains or unexpected link hosts
- Attachment type mismatched to normal billing behavior
- Reply-to address differs materially from sender domain

When suspicious, escalate to manual verification via trusted channel before action.

## Sieve Rule Patterns (Server-Side Sorting)

Use Sieve on compatible IMAP servers (Dovecot, Cyrus, Fastmail, Proton Bridge-compatible workflows where applicable).

Example patterns:

```sieve
require ["fileinto", "imap4flags", "regex"];

# Transactions
if anyof(
  address :domain :is "from" "stripe.com",
  address :domain :is "from" "paypal.com",
  header :regex "Subject" "(invoice|receipt|payment|statement)"
) {
  fileinto "Transactions";
  stop;
}

# Promotions
if anyof(
  exists "List-Unsubscribe",
  header :contains "Precedence" "bulk"
) {
  fileinto "Promotions";
  stop;
}
```

Keep Sieve deterministic; use explicit vendor/domain rules for financial workflows.

## IMAP Folders vs Gmail Labels

- **IMAP folders**: usually one-message-one-folder semantics (moves can remove from source folder)
- **Gmail labels**: multi-label model; one message can appear in multiple views simultaneously

Operational implication:

- In IMAP, avoid over-moving messages if you need parallel views
- In Gmail, rely on labels + search views for category/action separation

## POP Considerations for Shared Mailboxes

Avoid POP for collaborative inboxes whenever possible.

- POP commonly downloads to one client and can remove server copy
- POP has weak support for shared state (read/unread, assignment, synchronized folder actions)
- Shared workflows (triage, assignment, auditing) require IMAP or platform-native shared mailbox features

If POP is unavoidable:

- Disable server-delete behavior
- Use one dedicated ingestion client only
- Mirror to a central system for team visibility

## Related

- `services/email/email-agent.md`
- `services/email/ses.md`
- `services/email/email-testing.md`
