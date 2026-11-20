<!-- aidevops:brief-schema=v2 -->
# Approval-bound Google Ads account actions (validate-only plan, guarded apply, rollback)

## What

Add a remote Google Ads adapter to the marketing-actions contract. Only these action kinds are allowed:

- campaign negative keyword add
- ad-group negative keyword add
- keyword pause/enable
- switch a campaign to Maximize Clicks with a CPC ceiling
- change a campaign budget amount

The flow:

- `plan` reads the current state through GAQL, calls `googleAds:mutate` with `validateOnly: true`, and writes a digest-bound plan. The plan holds the full keyword text, before-state, inverse operations, config caps and a 24h expiry.
- `apply` requires the operator approval record from the prerequisite task. It re-reads state and refuses on drift, runs one atomic mutate with `partialFailure: false`, and writes a private receipt plus a JSONL audit line.
- `rollback` applies the recorded inverse operations under a fresh rollback approval, after its own drift check.

## Why

Parent #39489: triage and the official MCP are proposal-only, so owners apply approved negatives, bids and budgets by hand. `marketing_actions.py:28-41` marks these kinds `handoff_only`. This task makes them executable without weakening operator control.

## Tier

`tier:thinking`: spend-affecting writes to an external account.

## How

### Files to Modify

- `NEW: .agents/scripts/google_ads_actions.py`: kind registry, GAQL reads, operation builders, plan/apply/rollback, receipt and audit. Model the transport on `.agents/scripts/marketing_account_google.py:16-76`.
- `NEW: .agents/scripts/google-ads-action-helper.py`: CLI `plan --input --config --output`, `apply --plan --receipt-dir`, `rollback --receipt`.
- `EDIT: .agents/scripts/marketing_action_approval.py`: register the plan schema `aidevops.google-ads-action-plan/v1` with binding `customer_id`, plus a summary renderer.
- `NEW: .agents/scripts/tests/test-google-ads-actions.py`: fake-transport contract tests.
- `EDIT: .agents/workflows/marketing-actions.md`: Supported Surface and Google Ads section.
- `EDIT: .agents/marketing-sales/google-ads-triage.md:6-12`: pointer from proposals to the apply path.

Transport rules:

- Use stdlib `urllib` with a fixed `googleads.googleapis.com/v25/` prefix.
- Send `Authorization: Bearer` from `GOOGLE_ADS_ACCESS_TOKEN`, plus an optional `login-customer-id`.
- Never accept credentials as arguments or write them to output.
- Do not require a developer token: Google's developer-token policy page states tokens were sunset on 2026-09-09 and are ignored. Send the header only when `GOOGLE_ADS_DEVELOPER_TOKEN` is set.

### Complete Write Surface

- **Callers/readers:** the CLI only. Triage output (`google_ads_triage.py`) remains proposals, and operators hand-author the action input. `rg -n handoff_only .agents/scripts` shows that local marketing-actions keeps its own exclusions.
- **Writers/mutation paths:** Google Ads REST `customers/{cid}/googleAds:mutate` (the only write endpoint) and `googleAds:search` (reads). Locally: plan output (0600, new path) and the receipt directory (0700) holding `<digest>.json` and `audit.jsonl`.
- **Existing verification/tests:** `.agents/scripts/tests/test-marketing-actions.py` covers the shared approval module. The new `.agents/scripts/tests/test-google-ads-actions.py` uses a fake transport, so no network is used.
- **Schemas/config:** new `aidevops.google-ads-action-input/v1`, `-config/v1`, `-plan/v1` and `-receipt/v1`. The config holds `customer_allowlist`, `max_daily_budget_micros`, `max_cpc_bid_ceiling_micros` and `max_operations`.
- **Generated/deployed mirrors:** `setup.sh` copies `.agents/scripts/`; `rg -n google_ads_triage .agents/configs` finds no generated registry entries.
- **Migrations/backfills:** N/A. `rg -n "google-ads-action" .agents` finds no existing producer or consumer, and `.agents/scripts/marketing_actions.py` plan and receipt schemas are unchanged, so there is nothing to backfill.
- **Cleanup/rollback paths:** account changes reverse through receipt inverse operations via `rollback`. A code revert removes the adapter, and receipts and audit logs stay as private evidence.

### Implementation Steps

1. Define the kind registry. Each kind provides a GAQL before-state read, before/after matchers, a forward operation and an inverse operation. Resource names follow `customers/{cid}/campaigns/{id}`, `adGroupCriteria/{ag}~{crit}`, `campaignCriteria/{camp}~{crit}` and `campaignBudgets/{id}`. `updateMask` values use camelCase.
2. `plan`: validate the input and config (allowlist, caps, operation count), read the before-state, refuse no-op or unsupported rollback states, run the validate-only mutate, then write the digest-bound plan (0600, exclusive create).
3. `apply`: validate the plan digest and expiry, verify the operator approval with binding `customer_id`, take the receipt lock, handle replay and resume, check for drift, write the receipt as `applying`, run the mutate, then record resource names, mark the receipt `applied` and append the audit line.
4. `rollback`: verify the rollback approval bound to the receipt digest, confirm the live state is the after-state, validate and then send the inverse operations, mark the receipt `rolled_back` and append the audit line.
5. Add the docs and tests, then run the verification below.

### Hazards and Compatibility

- **Concurrency/atomicity:** one mutate with `partialFailure: false`, so all operations apply or none do. A non-blocking lock on the receipt directory prevents concurrent apply or rollback of the same plan.
- **Migration/rollback:** bidding rollback is only planned from `MANUAL_CPC`, `TARGET_SPEND` or `MAXIMIZE_CONVERSIONS`, with no portfolio strategy. Shared budgets are refused, so every planned change has a recorded inverse.
- **Mixed-version/backward compatibility:** these are new schemas. Local marketing-action plans keep their v1 schema and `handoff_only` exclusions unchanged.
- **Idempotency/retry:** an applied receipt replays as a no-op. Create operations refuse when an identical negative already exists, and a repeat rollback is a no-op.
- **Partial failure/recovery:** the receipt is written as `applying` before the mutate. On resume, if everything is in before-state, apply again. If everything is in after-state, mark it applied and recover created resource names by GAQL. Anything mixed is refused.

### Verification Before Dispatch

```bash
python3 .agents/scripts/tests/test-google-ads-actions.py
python3 .agents/scripts/tests/test-marketing-actions.py
ruff check .agents/scripts/google_ads_actions.py .agents/scripts/google-ads-action-helper.py .agents/scripts/marketing_action_approval.py
python3 .agents/scripts/google-ads-action-helper.py plan --input INPUT.json --config CONFIG.json --output PLAN.json
```

- **Surface mapping:**
  - The first test covers plan/apply/rollback, drift, caps, allowlist and approval denials (all acceptance criteria).
  - The second test covers the shared approval registry.
  - `ruff` covers the changed files.
  - The live `plan` command needs operator credentials and a test account; it proves Google accepts the payloads with validate-only.
- **Broad verification trigger:** Not required, because these are new files plus one registry entry.

### Files Scope

- `.agents/scripts/google_ads_actions.py`
- `.agents/scripts/google-ads-action-helper.py`
- `.agents/scripts/marketing_action_approval.py`
- `.agents/scripts/tests/test-google-ads-actions.py`
- `.agents/workflows/marketing-actions.md`
- `.agents/marketing-sales/google-ads-triage.md`

## Acceptance Criteria

- [ ] `plan` sends `validateOnly: true` and records the full operations, keyword text, before-state and inverse operations under `plan_digest`. `apply` with a valid approval sends one non-validate mutate and writes the receipt and audit line.
- [ ] Apply is refused with no write request for: a missing, stale or mismatched approval; an expired plan; a tampered digest; drifted state; a non-allowlisted customer; or values over the caps.
- [ ] Rollback restores the before-state only when the live state still equals the after-state, and a repeat rollback is a no-op.
