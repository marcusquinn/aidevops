<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2026 Marcus Quinn -->

# Marketing-decision routines (disabled by default)

These are opt-in operator templates, not installed schedules. They never activate a provider, mutate an account, spend money, publish content, or create cron/launchd entries.

## Weekly evidence review

```yaml
enabled: false
owner: OPERATOR_REQUIRED
account_scope: OPAQUE_ACCOUNT_ID
site_scope: OPAQUE_SITE_ID
collection: offline imports only
batch_review: one bounded agent review per collected batch
maximum_requests: 0
maximum_tokens: 0
maximum_cost_usd: 0
maximum_runtime_minutes: 15
freshness: require a changed source digest or new performance window
action_mode: report_and_dry_run_only
stop_conditions: [missing_scope, stale_evidence, unknown_provider_readiness, budget_exceeded]
```

## Monthly calibration review

```yaml
enabled: false
owner: OPERATOR_REQUIRED
account_scope: OPAQUE_ACCOUNT_ID
site_scope: OPAQUE_SITE_ID
collection: first-party conversion evidence before broad citation polling
batch_review: one bounded agent review per batch
maximum_requests: 0
maximum_tokens: 0
maximum_cost_usd: 0
maximum_runtime_minutes: 30
freshness: invalidate when scope, rubric, model, or performance window changes
action_mode: report_and_dry_run_only
stop_conditions: [missing_labels, calibration_gap, unknown_economics, provider_not_ready]
```
