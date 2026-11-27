---
description: Wise Business - read-only profiles, balances and statement export for bookkeeping reconciliation
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

# Wise Business - Statement Export

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Helper**: `~/.aidevops/agents/scripts/wise-helper.sh`
- **API**: `GET /v1/profiles`, `GET /v4/profiles/{id}/balances`, `GET /v1/profiles/{profileId}/balance-statements/{balanceId}/statement.json`
- **Auth**: read-only personal API token; optional RSA key pair for SCA statement signing
- **Secrets** (via `aidevops secret set NAME`; alias upper-cased, `-` becomes `_`): `WISE_<ALIAS>_TOKEN`, optional `WISE_<ALIAS>_PRIVATE_KEY`
- **Environment**: `WISE_ENV=live` (default) or `sandbox`

```bash
wise-helper.sh accounts                          # configured aliases
wise-helper.sh accounts <alias>                  # profiles + balances
wise-helper.sh transactions <alias> --since 2026-01-01 [--until 2026-03-31] [--currency EUR] [--profile ID] --csv out.csv
wise-helper.sh balance <alias> [--as-of 2026-03-31] [--currency EUR] [--profile ID]
```

CSV columns (shared with `paypal-helper.sh` and `revolut-helper.sh`): `date,id,description,gross,fee,net,balance,currency`. `fee` is negative, `net = gross + fee`, `balance` is the running balance in that currency. All currency balances of the profile are exported unless `--currency` is given.

<!-- AI-CONTEXT-END -->

## Setup

1. Wise Business > Settings > Integrations and tools > API tokens: create a token with **read-only** access.
2. Store it (hidden prompt; never paste into chat):

```bash
aidevops secret set WISE_<ALIAS>_TOKEN
```

3. Check with `wise-helper.sh accounts <alias>`. The business profile is used by default; pass `--profile <id>` to choose another.

### SCA (EU/UK PSD2)

On EU/UK profiles the statement endpoints can answer HTTP 403 with `x-2fa-approval-result: REJECTED` and a one-time token. The helper completes this automatically when a signing key is configured:

```bash
openssl genrsa -out wise-private.pem 2048
openssl rsa -pubout -in wise-private.pem -out wise-public.pem
```

Upload `wise-public.pem` under the same API token settings (public key), then store the private key and delete the file:

```bash
aidevops secret set WISE_<ALIAS>_PRIVATE_KEY --from-file wise-private.pem
```

The helper signs the one-time token with RSA-SHA256 (base64) and retries with `x-2fa-approval` and `X-Signature`. Without a key, the 403 is reported with this guidance.

## Behaviour

- Each balance (currency) is exported in 90-day statement windows (API maximum is longer); rows are de-duplicated by reference number and sorted by date.
- `balance --as-of` reports the statement closing balance (`endOfStatementBalance`) for that UTC day.
- Missing credentials exit non-zero with setup guidance. The token and signatures go to curl through a stdin config and are never printed; API errors show only the error code and message.
- Free-text fields starting with `=`, `+`, `@` or `-` (non-numeric) are prefixed with `'` to prevent spreadsheet formula injection.

## Verification

Compare a 3-month export with the Wise web statement CSV for the same currency and range (row count, net total printed per currency, closing balance):

```bash
wise-helper.sh transactions main --since 2026-01-01 --until 2026-03-31 --currency EUR --csv q1.csv
wise-helper.sh balance main --as-of 2026-03-31 --currency EUR
```

Assumption to confirm on first live run: `amount` excludes `totalFees`, so `net = amount - totalFees` matches the running balance movement.
