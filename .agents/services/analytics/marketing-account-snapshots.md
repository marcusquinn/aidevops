<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2026 Marcus Quinn -->

# Read-only marketing account snapshots

`marketing-account-snapshot-helper.py` is an opt-in collector for account performance evidence.
It is not a campaign management tool. Export import through `marketing-snapshot-helper.py` remains
the credential-free fallback.

## Safe operation

Run a dry plan first; it makes no network request and never reads credentials:

```bash
python3 .agents/scripts/marketing-account-snapshot-helper.py collect \
  --provider google-ads --account-ref 123-456-7890 --from 2026-01-01 --to 2026-01-31 --dry-run
```

Live collection requires `--live`, a new absolute `--output` path, and provider credentials injected
through the approved secret tooling. Google requires `GOOGLE_ADS_ACCESS_TOKEN` and
`GOOGLE_ADS_DEVELOPER_TOKEN`; Meta requires `META_ACCESS_TOKEN`. Credentials are never accepted as
arguments or included in output.

## Coverage limits

Google uses a fixed performance GAQL query. Meta uses the fixed account insights view. Both adapters
allow only their fixed read endpoint, bound each response to 2 MB, collect at most one request, and
report partial coverage rather than inventing missing data. They do not create, edit, enable, pause,
or spend on advertising resources. Ad Library, audience data, and comments are intentionally outside
this collector's scope.
