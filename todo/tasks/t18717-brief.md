## Task

Align the Linkup docs with the credential naming convention: store the key as an account-scoped secret (`LINKUP_<ACCOUNT>_API_KEY`) instead of the bare `LINKUP_API_KEY`, and show how to inject it for curl and the Linkup CLI.

## Why

PR #34990 (GH#34989) told users to run `aidevops secret set LINKUP_API_KEY`. `tools/credentials/credential-inventory.md` "Naming new credentials" forbids storing the bare conventional variable, and `linkup` is not in `DEFAULT_ENV` (`scripts/credential_inventory_fields.py`), so `aidevops secret LINKUP_API_KEY -- ...` cannot resolve an account-scoped secret. A live test with an account-scoped key confirmed the API calls work (search $0.005, fetch $0.001, matching the doc) once the stored name is injected.

## How

- `.agents/tools/research/linkup.md`: Quick Reference auth line and Commands section use `LINKUP_<ACCOUNT>_API_KEY` with `--provider linkup --account <ref>`; CLI examples map the stored name to `LINKUP_API_KEY` inside `sh -c`; note the verified live test.
- `.agents/aidevops/onboarding.md`: Linkup row shows the account-scoped name.
- `.agents/tools/research/web-search-apis.md`: "Key env var" row clarifies these are the variables the SDKs/CLIs read; store per the naming convention.

## Files to modify

### Files Scope

- `.agents/tools/research/linkup.md`
- `.agents/tools/research/web-search-apis.md`
- `.agents/aidevops/onboarding.md`

## Acceptance

- No doc instructs storing bare `LINKUP_API_KEY`.
- curl and CLI examples work with an account-scoped stored secret.
- markdownlint clean on changed files.

## Verification

- `rg -n "secret set LINKUP_API_KEY" .agents/` returns nothing.
- `markdownlint-cli2` on changed files.
