<!-- aidevops:brief-schema=v2 -->
<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2026 Marcus Quinn -->
# t18455: Optional read-only Google Ads and Meta account connectors

## Pre-flight

- [x] Memory recall: no relevant lessons in parent query.
- [x] Discovery pass: Google historical keyword metrics and external Meta CLI guidance exist, but account snapshot adapters were not found.
- [x] File refs verified: domain_opportunity_google_ads.py, capability registry/readiness and Meta tooling docs exist.
- [x] Tier: standard; implement read-only connectors inside existing readiness/secret policies, not a new authority boundary.
- [x] Seeded draft PR skipped: provider version verification belongs to implementation.

## Origin

2026-09-20 OpenCode interactive background request. Parent: t18444. blocked-by:t18447,t18451.

## What

Add optional explicit read-only Google Ads and Meta collection adapters producing t18446-compatible snapshots. Keep export import as the unconditional credential-free fallback; reuse existing GSC/analytics collectors instead of duplicating them.

## Why

Remove manual export overhead when the operator has separately authorized and configured provider access, without making implementation depend on private credentials.

## Tier

Selected tier: `tier:standard`; account/data authority and default-off policy are already decided.

## How

### Files to Modify

- `NEW: .agents/scripts/marketing-account-snapshot-helper.py` — read-only collection CLI.
- `NEW: .agents/scripts/marketing_account_google.py` — Google query/entity adapter.
- `NEW: .agents/scripts/marketing_account_meta.py` — Meta insights/creative adapter.
- `NEW: .agents/services/analytics/marketing-account-snapshots.md` — setup and coverage limits.
- `EDIT: .agents/configs/capability-registry.json` — narrow readiness entries if required, using its existing schema.
- `NEW: .agents/scripts/tests/test-marketing-account-snapshots.py` — mocked transport contract tests.

Reference `.agents/scripts/domain_opportunity_google_ads.py`, `.agents/marketing-sales/meta-ads-tooling-cli.md`, `.agents/seo/google-search-console.md`, `.agents/services/analytics/google-analytics.md` and `.agents/reference/secret-handling.md`. Verify installed SDK/CLI/API versions and primary-source exported fields before coding; do not guess version/error constants.

### Files Scope

- `.agents/scripts/marketing-account-snapshot-helper.py`
- `.agents/scripts/marketing_account_google.py`
- `.agents/scripts/marketing_account_meta.py`
- `.agents/services/analytics/marketing-account-snapshots.md`
- `.agents/configs/capability-registry.json`
- `.agents/reference/capability-registry.md`
- `.agents/scripts/tests/test-marketing-account-snapshots.py`
- `.agents/scripts/tests/fixtures/marketing-decisions/accounts-google.json`
- `.agents/scripts/tests/fixtures/marketing-decisions/accounts-meta.json`

### Complete Write Surface

- **Callers/readers:** `.agents/scripts/marketing-account-snapshot-helper.py` feeds importer/domain CLIs.
- **Writers/mutation paths:** `.agents/scripts/marketing_account_google.py` and `.agents/scripts/marketing_account_meta.py` write only private snapshots; provider APIs are read-only.
- **Tests/fixtures:** `.agents/scripts/tests/test-marketing-account-snapshots.py` with mocked Google/Meta pages/errors.
- **Schemas/config:** `.agents/configs/capability-registry.json` for readiness; normalized output uses predecessor schema.
- **Generated/deployed mirrors:** regenerate `.agents/reference/capability-registry.md` through the existing generator if registry changes; no deployed/config secret edits.
- **Migrations/backfills:** N/A because this opt-in collector neither migrates accounts nor replaces existing GSC/GA4 collectors.
- **Cleanup/rollback paths:** revert new adapters and `.agents/configs/capability-registry.json` entries; preserve collected evidence/exports.

### Implementation Steps

1. Provide `collect --provider google-ads|meta --account-ref ID --from DATE --to DATE --dry-run`; dry-run validates scope and prints no secrets and makes no network calls. Live collection requires explicit live intent, readiness, permitted account, date bounds, row/request budget and secret injection through existing tooling.
2. Google reads available search-term/performance data plus keywords/ad groups, RSA assets/final URLs, negative lists, recommendations and disapproval evidence. Meta reads authorized owned creatives/insights/comments where scopes allow; Ad Library access/coverage is separate and unavailable when not authorized.
3. Bound pagination, rate limits, retries, timeout/response sizes and account isolation. Never follow arbitrary returned URLs with credentials; protect endpoint/redirect behavior. Honor 429 cooldowns; no authentication retry storm or scope expansion.
4. Output coverage/omission/permission information, preserve currencies/timezones/conversion lag, redact unnecessary personal data and reuse normalization. Never call mutate endpoints, create campaigns, hide comments, enable pixel/conversion tracking or spend money.

### Hazards and Compatibility

- **Concurrency/atomicity:** account-scoped request budgets and atomic snapshot writes; no shared secret state.
- **Migration/rollback:** additive provider capability entries only; no account/server/config migration.
- **Mixed-version/backward compatibility:** pin observed API contracts and fail unsupported versions/fields to partial/unavailable, not invented zeros.
- **Idempotency/retry:** read requests are bounded; deduplicate paginated records and retain original request scope.
- **Partial failure/recovery:** record partial coverage and resume tokens privately; auth/permission failures fall back to local export instructions without invoking another provider.

### Verification Before Dispatch

```bash
python3 .agents/scripts/marketing-account-snapshot-helper.py --help
python3 .agents/scripts/tests/test-marketing-account-snapshots.py
python3 .agents/scripts/capability-readiness-helper.py --help
.agents/scripts/linters-local.sh --changed
```

- **Surface mapping:** execute dry-run with synthetic account refs; mocked tests prove pagination/429/denied scopes, allowed endpoints and no mutate calls; existing registry validation/generation checks apply if changed. Reuse repository tests, no new harness.
- **Recoverability:** checkpoint after focused verification; live access remains unverified without separate operator authority. Keep implementation criteria achievable with mocked transports and preserve a blocker rather than requesting secrets in chat.

## Acceptance Criteria

- [ ] Both account adapters produce normalized snapshots from recorded/mock transport fixtures, with pagination and partial coverage represented.
- [ ] Dry-run and denied/unconfigured routes make no network call; secrets never appear in argv/output/artifacts and mutation endpoints are unreachable.
- [ ] Existing GSC/GA4/historical keyword clients remain usable and no provider account, subscription or production setting is changed by implementation.
