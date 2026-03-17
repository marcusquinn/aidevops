# Email Address Verification

Local email address verifier with SMTP RCPT TO probing, disposable domain detection, and catch-all detection.

**Script**: `scripts/email-verify-helper.sh`
**Task**: t1539 | **Complements**: Outscraper API (t1538) as offline/unlimited alternative

## Quick Start

```bash
# Verify a single email
email-verify-helper.sh verify user@example.com

# Quiet/CSV mode
email-verify-helper.sh verify user@example.com --quiet

# Bulk verify from file
email-verify-helper.sh bulk emails.txt results.csv

# Update disposable domain database (run on first use)
email-verify-helper.sh update-domains

# View statistics
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

- **Source**: [disposable-email-domains](https://github.com/disposable-email-domains/disposable-email-domains) (MIT, 3.2k stars, 170k+ domains)
- **Storage**: `~/.aidevops/.agent-workspace/data/disposable-domains.db` (SQLite with FTS5)
- **Update**: `email-verify-helper.sh update-domains` (downloads and rebuilds)
- **Lookup**: Exact match on domain + parent domain check (catches subdomains)

Run `update-domains` on first use and periodically (weekly/monthly) to stay current.

## Bulk Verification

```bash
# Input: one email per line, # comments allowed
email-verify-helper.sh bulk input.txt output.csv
```

Output CSV format: `email,score,check,details`

Features:

- 1-second delay between SMTP probes (rate limiting)
- Progress indicator every 10 emails
- Summary statistics on completion
- Results recorded to stats database

## Statistics

All verifications are recorded in `~/.aidevops/.agent-workspace/data/email-verify-stats.db`:

- Score breakdown (deliverable/risky/undeliverable/unknown percentages)
- Top domains verified
- Recent verification history

## Dependencies

| Tool | Required | Purpose |
|------|----------|---------|
| `dig` | Yes | MX record lookup |
| `sqlite3` | Yes | Disposable domain DB, stats |
| `nc` (netcat) | For SMTP | Plain SMTP RCPT TO probing |
| `openssl` | For SMTP | STARTTLS fallback |
| `curl` | For updates | Download disposable domain list |

## SMTP Probing Notes

- Uses port 25 (standard MX-to-MX delivery port)
- Sequential SMTP conversation with delays between commands
- Falls back to openssl STARTTLS if plain connection fails
- Many providers (Gmail, Outlook) block RCPT TO verification from unknown sources
- Results may be `unknown` when SMTP probing is blocked -- this is expected
- Rate-limited: 1-second delay between probes in bulk mode

## Architecture

```text
email-verify-helper.sh
  |
  +-- check_syntax()        -- RFC 5321 regex validation
  +-- check_mx()            -- dig MX + A record lookup
  +-- check_disposable()    -- SQLite FTS5 lookup
  +-- smtp_probe()          -- nc/openssl SMTP conversation
  |     +-- check_rcpt_to() -- RCPT TO response parsing (250/452/550)
  |     +-- check_catch_all() -- Random address probe
  +-- calculate_score()     -- Aggregate scoring engine
  +-- record_verification() -- Stats DB recording
```

## Related

- `email-health-check-helper.sh` -- DNS authentication (SPF, DKIM, DMARC)
- `email-delivery-test-helper.sh` -- Spam content analysis, inbox placement
- `email-test-suite-helper.sh` -- Design rendering tests
- Outscraper API (t1538) -- Cloud-based verification with higher accuracy
