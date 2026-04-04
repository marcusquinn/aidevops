<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Email Address Verification

Local email address verifier with SMTP RCPT TO probing, disposable domain detection, and catch-all detection.

**Script**: `scripts/email-verify-helper.sh`
**Task**: t1539 | **Complements**: Outscraper API (t1538) as offline/unlimited alternative

## Quick Start

```bash
email-verify-helper.sh verify user@example.com
email-verify-helper.sh verify user@example.com --quiet   # CSV output

# Bulk (one email per line, # comments allowed) — output CSV: email,score,check,details
# 1s delay between SMTP probes, progress every 10 emails, summary on completion
email-verify-helper.sh bulk input.txt output.csv

email-verify-helper.sh update-domains  # run on first use, then weekly/monthly
email-verify-helper.sh stats
```

## 6 Verification Checks

| # | Check | Method | Detects |
|---|-------|--------|---------|
| 1 | Syntax validation | RFC 5321 regex | Invalid format, length violations, consecutive dots |
| 2 | MX record lookup | `dig MX` + A fallback | Domains that cannot receive email |
| 3 | Disposable domain | SQLite FTS5 lookup | Temporary/throwaway email services (5k+ domains) |
| 4 | SMTP RCPT TO | Port 25 probe via `nc` | Non-existent mailboxes (550 response) |
| 5 | Full inbox | SMTP 452 response | Mailboxes that exist but cannot receive (full) |
| 6 | Catch-all detection | Random address probe | Domains that accept all addresses (unreliable verification) |

## Scoring

Scores match the FixBounce classification system:

| Score | Meaning | Action |
|-------|---------|--------|
| `deliverable` | All checks passed, mailbox confirmed | Safe to send |
| `risky` | Catch-all domain, full inbox, or warnings | Send with caution |
| `undeliverable` | Invalid syntax, no MX, disposable, or rejected | Do not send |
| `unknown` | SMTP blocked or inconclusive | Manual review needed |

## Disposable Domain Database

- **Source**: [disposable-email-domains](https://github.com/disposable-email-domains/disposable-email-domains) (MIT, 170k+ domains)
- **Storage**: `~/.aidevops/.agent-workspace/data/disposable-domains.db` (SQLite FTS5)
- **Lookup**: Exact match on domain + parent domain check (catches subdomains)

## Dependencies

| Tool | Required | Purpose |
|------|----------|---------|
| `dig` | Yes | MX record lookup |
| `sqlite3` | Yes | Disposable domain DB, stats |
| `nc` (netcat) | For SMTP | Plain SMTP RCPT TO probing |
| `openssl` | For SMTP | STARTTLS fallback |
| `curl` | For updates | Download disposable domain list |

## SMTP Probing Notes

- Port 25 with sequential SMTP conversation; falls back to openssl STARTTLS
- Many providers (Gmail, Outlook) block RCPT TO from unknown sources -- `unknown` result is expected
- Rate-limited: 1s delay between probes in bulk mode

## Architecture

```text
email-verify-helper.sh
  +-- check_syntax()          -- RFC 5321 regex validation
  +-- check_mx()              -- dig MX + A record lookup
  +-- check_disposable()      -- SQLite FTS5 lookup
  +-- smtp_probe()            -- nc/openssl SMTP conversation
  |     +-- check_rcpt_to()   -- RCPT TO response parsing (250/452/550)
  |     +-- check_catch_all() -- Random address probe
  +-- calculate_score()       -- Aggregate scoring engine
  +-- record_verification()   -- Stats: ~/.aidevops/.agent-workspace/data/email-verify-stats.db
```

## Related

- `email-health-check-helper.sh` -- DNS authentication (SPF, DKIM, DMARC)
- `email-delivery-test-helper.sh` -- Spam content analysis, inbox placement
- `email-test-suite-helper.sh` -- Design rendering tests
- Outscraper API (t1538) -- Cloud-based verification with higher accuracy
