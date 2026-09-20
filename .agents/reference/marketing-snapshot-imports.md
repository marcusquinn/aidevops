# Marketing snapshot imports

`marketing-snapshot-helper.py import` is offline-only. Supported kinds are `google-ads`, `meta`, `gsc`, `site`, `ai-capture`, and `community`. Google Ads accepts a headered CSV; all other kinds accept a JSON array (or `{ "rows": [...] }`).

Use `--dry-run` to emit a normalized evidence report without writes. Use `--output /absolute/private/path` only to create a new private artifact. Inputs are never changed. Raw cells remain inert evidence; malformed or conflicting rows are retained in `row_errors`. Empty conversions, costs, and censored query coverage remain unknown rather than becoming zero.
