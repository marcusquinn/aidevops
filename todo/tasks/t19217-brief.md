<!-- aidevops:brief-schema=v2 -->
# Google Ads readers: make the developer token optional (tokens sunset 2026-09-09)

## What

Both live Google Ads readers refuse to run without `GOOGLE_ADS_DEVELOPER_TOKEN`. Google's developer-token policy page (developers.google.com/google-ads/api/docs/api-policy/developer-token) states that developer tokens "were sunset on September 9, 2026" and are ignored by API servers. Operators without a token therefore cannot collect snapshots or demand metrics. The fix: require only the access token, and send the `developer-token` header only when one is configured.

## Why

Found while reviewing #39489: the reporter's validate-only mutates succeeded with an ADC access token and no developer token. Current docs confirm the sunset.

## Tier

`tier:simple`: two credential checks, two header builders and their docs.

## How

### Files to Modify

- `EDIT: .agents/scripts/marketing_account_google.py:48-61`: require only `access_token`, and build the headers dict without `developer-token` when the token is empty.
- `EDIT: .agents/scripts/domain_opportunity_google_ads.py:63-69,~259-268`: make `developer_token: str = ""` optional in `GoogleAdsCredentials.__post_init__`, and add the header only when set.
- `EDIT: .agents/scripts/tests/test-domain-opportunity-google-ads.py:125-140` and `.agents/scripts/tests/test-marketing-account-snapshots.py:34`: update the credential expectations.
- `EDIT: .agents/services/analytics/marketing-account-snapshots.md:19-22` and `.agents/seo/domain-opportunities.md:19`: describe the developer token as optional and legacy.

### Complete Write Surface

- **Callers/readers:** `.agents/scripts/marketing-account-snapshot-helper.py:53` and `.agents/scripts/domain-opportunity-google-ads.py:86` read the env var; both keep passing it through.
- **Writers/mutation paths:** N/A. Both adapters are read-only (`searchStream` and keyword historical metrics).
- **Existing verification/tests:** `.agents/scripts/tests/test-marketing-account-snapshots.py` and `.agents/scripts/tests/test-domain-opportunity-google-ads.py` cover the credential guards.
- **Schemas/config:** N/A. Credentials never enter stored evidence (`domain_opportunity_google_ads.py:60`).
- **Generated/deployed mirrors:** `setup.sh` copies `.agents/scripts/` unchanged; there is no generated output.
- **Migrations/backfills:** N/A because no stored data references the token. It is used only for request construction in `.agents/scripts/marketing_account_google.py` and `.agents/scripts/domain_opportunity_google_ads.py`.
- **Cleanup/rollback paths:** a revert of `.agents/scripts/marketing_account_google.py` and `.agents/scripts/domain_opportunity_google_ads.py` restores the old guard.

### Implementation Steps

1. In both adapters, change the guard to require only the access token (plus the customer for the domain sync).
2. Build the headers as `{"Authorization": ..., "Content-Type": ...}` and add `developer-token` only if it is non-empty.
3. Update the two tests and the two docs, then run the verification below.

### Hazards and Compatibility

- **Concurrency/atomicity:** N/A. These are stateless request builders.
- **Migration/rollback:** a revert restores the stricter guard; no data is involved.
- **Mixed-version/backward compatibility:** operators who still set the token keep sending it, which Google ignores.
- **Idempotency/retry:** unchanged. Retry logic in `domain_opportunity_google_ads.py` is untouched.
- **Partial failure/recovery:** unchanged. A missing access token still fails closed before any request.

### Verification Before Dispatch

```bash
python3 .agents/scripts/tests/test-marketing-account-snapshots.py
python3 .agents/scripts/tests/test-domain-opportunity-google-ads.py
ruff check .agents/scripts/marketing_account_google.py .agents/scripts/domain_opportunity_google_ads.py
```

- **Surface mapping:**
  - Each test file covers its adapter's guard and headers.
  - `ruff` covers the changed files.
- **Broad verification trigger:** Not required.

### Files Scope

- `.agents/scripts/marketing_account_google.py`
- `.agents/scripts/domain_opportunity_google_ads.py`
- `.agents/scripts/tests/test-domain-opportunity-google-ads.py`
- `.agents/scripts/tests/test-marketing-account-snapshots.py`
- `.agents/services/analytics/marketing-account-snapshots.md`
- `.agents/seo/domain-opportunities.md`

## Acceptance Criteria

- [ ] With only `GOOGLE_ADS_ACCESS_TOKEN` set, both adapters build a request with no `developer-token` header.
- [ ] With no access token, both adapters still refuse before any network call. With a developer token set, the header is still sent.

Ref #39489
