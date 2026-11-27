---
description: PayPal reporting - read-only Transaction Search export for bookkeeping reconciliation (multi-account)
mode: subagent
tools:
  read: true
  write: true
  edit: false
  bash: true
  glob: true
  grep: true
  webfetch: true
  task: false
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# PayPal - Reporting Export

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Helper**: `~/.aidevops/agents/scripts/paypal-helper.sh`
- **API**: REST Transaction Search `GET /v1/reporting/transactions` (max 31-day window, data available after about 3 hours) and `GET /v1/reporting/balances`
- **Auth**: OAuth client-credentials per account; read-only scopes only
- **Secrets**: `PAYPAL_<ALIAS>_CLIENT_ID`, `PAYPAL_<ALIAS>_SECRET` via `aidevops secret set NAME` (alias upper-cased, `-` becomes `_`)
- **Environment**: `PAYPAL_ENV=live` (default) or `sandbox`

```bash
paypal-helper.sh accounts
paypal-helper.sh transactions <alias> --since 2026-01-01 [--until 2026-03-31] --csv out.csv
paypal-helper.sh balances <alias> [--as-of 2026-03-31]
```

CSV columns: `date,id,description,gross,fee,net,balance,currency` (net = gross + fee; fee is negative; balance is the ending balance after the transaction).

<!-- AI-CONTEXT-END -->

## Setup (per PayPal business account)

1. Sign in at developer.paypal.com with the business account, then Apps & Credentials, switch to **Live**, and create an app.
2. Under the app's features, enable **Transaction Search**. The permission can take up to 9 hours to take effect; HTTP 403 before then is expected.
3. Store the credentials (never paste them into chat):

```bash
aidevops secret set PAYPAL_<ALIAS>_CLIENT_ID
aidevops secret set PAYPAL_<ALIAS>_SECRET
```

4. Check with `paypal-helper.sh accounts`.

## Behaviour

- The range is split into 30-day windows (API limit is 31 days), each paged at 500 records; overlapping boundary records are de-duplicated by transaction id.
- Only balance-affecting records are exported, matching what the PayPal activity CSV reconciles against.
- Missing credentials fail with setup guidance; secrets are passed to curl via stdin config and never printed or logged. API errors show only the PayPal error name and message.
- Free-text fields starting with `=`, `+`, `@` or `-` (non-numeric) are prefixed with `'` to prevent spreadsheet formula injection.

## Verification

Compare a 3-month export's row count and net total with the PayPal web Activity CSV for the same range:

```bash
paypal-helper.sh transactions main --since 2026-01-01 --until 2026-03-31 --csv q1.csv
```
