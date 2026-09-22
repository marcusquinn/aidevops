---
description: Plan bounded public Reddit engagement without direct posting
---

# Public engagement

`/public-engagement` creates evidence-backed **drafts only** by default. It never
creates accounts, schedules, credentials, votes, DMs, or direct provider calls.

```bash
python3 .agents/scripts/public-engagement-helper.py plan --input SCENARIOS.json --dry-run
```

An owner must separately activate an exact draft approval or valid policy grant.
The existing private outbox remains the sole execution boundary; use its receipts
to project local outcomes. Unknown receipts are unresolved and must not retry.
