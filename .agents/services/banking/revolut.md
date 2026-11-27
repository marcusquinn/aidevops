---
description: Revolut Business - read-only accounts, transactions and balance export for bookkeeping reconciliation
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

# Revolut Business - Statement Export

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Helper**: `~/.aidevops/agents/scripts/revolut-helper.sh`
- **API**: Business API `GET /accounts`, `GET /transactions?from&to&account&count` (max 1000 per page)
- **Auth**: OAuth with a signed JWT client assertion (RS256, uploaded public certificate); access tokens last about 40 minutes and are fetched per run from the refresh token. Read scope only.
- **Secrets** (via `aidevops secret set NAME`; alias upper-cased, `-` becomes `_`): `REVOLUT_<ALIAS>_CLIENT_ID`, `REVOLUT_<ALIAS>_ISS`, `REVOLUT_<ALIAS>_PRIVATE_KEY`, `REVOLUT_<ALIAS>_REFRESH_TOKEN`
- **Environment**: `REVOLUT_ENV=live` (default) or `sandbox`

```bash
revolut-helper.sh accounts                       # configured aliases
revolut-helper.sh accounts <alias>               # Revolut accounts + balances
revolut-helper.sh transactions <alias> --since 2026-01-01 [--until 2026-03-31] [--account ID] --csv out.csv
revolut-helper.sh balance <alias> [--as-of 2026-03-31] [--account ID]
revolut-helper.sh auth-code <alias> <code>       # one-time consent exchange
```

CSV columns (shared with `paypal-helper.sh` and `wise-helper.sh`): `date,id,description,gross,fee,net,balance,currency`. One row per completed transaction leg; `fee` is negative, `net = gross + fee`, `balance` is the account balance after the leg.

<!-- AI-CONTEXT-END -->

## One-time setup

1. Generate a key pair and a certificate (keep the private key out of the repo):

```bash
openssl genrsa -out privatekey.pem 2048
openssl req -new -x509 -key privatekey.pem -out publiccert.cer -days 1825
```

2. Revolut Business > Settings > APIs > Business API: add an API certificate, upload `publiccert.cer`, set the OAuth redirect URI (its domain is the JWT issuer, `ISS`), and enable **read-only** access. Copy the Client ID.
3. Store the secrets (hidden prompts; never paste into chat), then delete the key file:

```bash
aidevops secret set REVOLUT_<ALIAS>_CLIENT_ID
aidevops secret set REVOLUT_<ALIAS>_ISS
aidevops secret set REVOLUT_<ALIAS>_PRIVATE_KEY --from-file privatekey.pem
```

4. Open the consent URL shown for the API certificate, approve, and copy the `code` query parameter from the redirect (it expires in minutes). Then:

```bash
revolut-helper.sh auth-code <alias> <code>
```

This exchanges the code and stores `REVOLUT_<ALIAS>_REFRESH_TOKEN` in the secret store. If Revolut ever returns a different refresh token on a refresh, the helper stores the new one the same way, so tokens are never written to files.

## Behaviour

- Pages newest-first by moving `to` back to the oldest `created_at`; boundary overlaps are de-duplicated by leg id. Only `completed` legs are exported (pending, declined, failed and reverted are skipped).
- `balance --as-of` reports the running balance of the newest completed leg per account up to the date, within the newest 1000 legs; pass `--account` for quiet accounts.
- Missing credentials exit non-zero with setup guidance. Secrets go to curl through a stdin config and are never printed; API errors show only the error code and message.
- Free-text fields starting with `=`, `+`, `@` or `-` (non-numeric) are prefixed with `'` to prevent spreadsheet formula injection.

## Verification

Compare a 3-month export with the Revolut web statement CSV for the same account and range (row count, net total printed by the helper, closing balance):

```bash
revolut-helper.sh transactions main --since 2026-01-01 --until 2026-03-31 --account <id> --csv q1.csv
revolut-helper.sh balance main --as-of 2026-03-31 --account <id>
```

Assumption to confirm on first live run: `fee` on a leg is a positive charge not already included in `amount`.
