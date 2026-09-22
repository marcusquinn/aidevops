# Disabled public-engagement routines

All examples are disabled by default. An operator must separately verify current
account and community rules, configure a valid owner grant, and enable a bounded
schedule. This template cannot create grants, credentials, accounts, or sends.

```yaml
name: public-engagement-draft-review
enabled: false
command: python3 .agents/scripts/public-engagement-helper.py plan --input SCENARIOS.json --dry-run
max_candidates: 10
fallback: manual_review
```

Only exact-approved batches or a current owner policy grant may reach the private
outbox. Stop on opt-out, moderation signal, uncertainty, revocation, or unknown receipt.
