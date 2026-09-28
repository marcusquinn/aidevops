<!-- aidevops:brief-schema=v2 -->

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->
# t18522: GSC export token lacks webmasters scope; use documented gsc-credentials.json

## Origin

- **Created:** 2026-09-28
- **Session:** opencode interactive (Build+)
- **Created by:** ai-interactive
- **Parent task:** none (found while importing GSC data into the aidevops keywords registry)
- **Conversation context:** `seo-export-helper.sh gsc aidevops.sh --days 90` with `GOOGLE_APPLICATION_CREDENTIALS` pointing at the documented service-account file failed with "Request had insufficient authentication scopes". Minting a token with `gcloud auth application-default print-access-token --scopes=https://www.googleapis.com/auth/webmasters.readonly` and passing it as `GSC_ACCESS_TOKEN` exported 266 rows successfully.

## What

The GSC exporter obtains a `webmasters.readonly`-scoped token from a service-account or user ADC file, and falls back to the documented `~/.config/aidevops/gsc-credentials.json` when `GOOGLE_APPLICATION_CREDENTIALS` is unset.

## Why

`get_access_token` calls `gcloud auth application-default print-access-token` without `--scopes`, which yields a cloud-platform token the Search Console API rejects for service accounts. `seo/google-search-console.md` documents `~/.config/aidevops/gsc-credentials.json` as the credential location, but the exporter never reads it, so `/seo-export gsc` fails on a correctly configured install.

## How (Approach)

### Files to Modify

- `EDIT: .agents/scripts/seo-export-gsc.sh:40-60` — `get_access_token`: default `GOOGLE_APPLICATION_CREDENTIALS` to `$CONFIG_DIR/gsc-credentials.json` when unset and the file exists; request the token with `--scopes=https://www.googleapis.com/auth/webmasters.readonly`.
- `EDIT: .agents/scripts/seo-export-gsc.sh:64-114` — `resolve_quota_project` uses the same resolved credential path.
- `EDIT: .agents/scripts/seo-export-gsc.sh:310-320` — help text lists the default path.
- `EDIT: .agents/seo/seo-export.md:37-44` — GSC row names `~/.config/aidevops/gsc-credentials.json` as the default.
- `EDIT: .agents/scripts/tests/test-seo-export-gsc-quota-project.sh` — extend only if its existing stubs cover `get_access_token`; assert the scope flag and default path.

### Complete Write Surface

- **Callers/readers:** `gsc_request` (line ~117) and the site-listing path (line ~229) call `get_access_token`; `seo-export-helper.sh gsc` dispatches to this script. `rg -n "get_access_token" .agents/scripts/seo-export-gsc.sh` lists all uses.
- **Writers/mutation paths:** N/A because the exporter only writes TOON export files under `~/.aidevops/.agent-workspace/work/seo-data/`, which is unchanged.
- **Existing verification/tests:** `.agents/scripts/tests/test-seo-export-gsc-quota-project.sh` (quota-project resolution); the live path `seo-export-helper.sh gsc <domain> --days 7`.
- **Schemas/config:** `GOOGLE_APPLICATION_CREDENTIALS`, `GSC_ACCESS_TOKEN`, `GSC_QUOTA_PROJECT` env/credentials keys; precedence unchanged except the new default path.
- **Generated/deployed mirrors:** `~/.aidevops/agents/scripts/seo-export-gsc.sh` via `setup.sh`.
- **Migrations/backfills:** N/A because no stored data or config format changes.
- **Cleanup/rollback paths:** N/A because nothing is persisted; reverting `.agents/scripts/seo-export-gsc.sh` restores prior behaviour.

### Implementation Steps

1. In `get_access_token`, after sourcing `credentials.sh` and checking `GSC_ACCESS_TOKEN`, resolve the credential file:

```bash
local cred_file="${GOOGLE_APPLICATION_CREDENTIALS:-}"
if [[ -z "$cred_file" && -f "$CONFIG_DIR/gsc-credentials.json" ]]; then
	cred_file="$CONFIG_DIR/gsc-credentials.json"
fi
# then: GOOGLE_APPLICATION_CREDENTIALS="$cred_file" gcloud auth application-default \
#   print-access-token --scopes=https://www.googleapis.com/auth/webmasters.readonly
```

2. Apply the same resolved path in `resolve_quota_project` (factor a small `_gsc_credential_file` helper to avoid duplication).
3. Update help text and `seo/seo-export.md`.
4. Run shellcheck, the existing test, then a live export.

### Hazards and Compatibility

- **Concurrency/atomicity:** N/A because token minting is a read-only subprocess per run.
- **Migration/rollback:** explicit `GOOGLE_APPLICATION_CREDENTIALS` and `GSC_ACCESS_TOKEN` keep precedence, so existing setups behave the same; revert is safe.
- **Mixed-version/backward compatibility:** `--scopes` is supported by current gcloud for service-account and user ADC; if an old gcloud rejects it, the error surfaces as today's "credentials not configured" path — keep the stderr hint.
- **Idempotency/retry:** each run mints a fresh short-lived token; safe to retry.
- **Partial failure/recovery:** token failure aborts before any export file is written, as today.

### Complexity Impact

- **Target function:** `get_access_token` in `.agents/scripts/seo-export-gsc.sh`
- **Current line count:** 21 lines (threshold: 100)
- **Estimated growth:** +8 lines
- **Projected post-change:** ~29 lines
- **Action required:** None

### Verification Before Dispatch

```bash
shellcheck .agents/scripts/seo-export-gsc.sh
bash .agents/scripts/tests/test-seo-export-gsc-quota-project.sh
~/.aidevops/agents/scripts/seo-export-helper.sh gsc <verified-domain> --days 7   # with only ~/.config/aidevops/gsc-credentials.json present
.agents/scripts/linters-local.sh --changed
```

- **Surface mapping:** shellcheck and the existing test cover the edited functions and quota-project precedence; the live export proves the scope fix and default path (acceptance 1-2); changed-file lint covers the doc edit.
- **Broad verification trigger:** Not required.

### Files Scope

- .agents/scripts/seo-export-gsc.sh
- .agents/seo/seo-export.md
- .agents/scripts/tests/test-seo-export-gsc-quota-project.sh

## Acceptance Criteria

- [ ] With only `~/.config/aidevops/gsc-credentials.json` (service account), `/seo-export gsc <domain>` exports rows without extra env vars.
- [ ] Tokens are requested with the `webmasters.readonly` scope; `GSC_ACCESS_TOKEN` still wins when set.
- [ ] Existing quota-project test passes.
- [ ] No token values are printed.
