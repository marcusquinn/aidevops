---
name: chrome-webstore-release
description: Chrome Web Store release automation - OAuth setup, API publish workflow, version-triggered CI, status checking
model: sonnet
tools: [bash, read, write]
---

# Chrome Web Store Release Automation

## Quick Start

```bash
chrome-webstore-helper.sh setup           # Interactive credential setup
chrome-webstore-helper.sh publish --manifest path/to/manifest.json
chrome-webstore-helper.sh status
chrome-webstore-helper.sh upload-secrets  # Upload to GitHub via gh CLI
```

## Prerequisites

- Chrome extension with `manifest.json`
- Google Cloud project with Chrome Web Store API enabled
- Publisher account on Chrome Web Store Developer Dashboard
- `jq`, `gh` CLI (optional, for secret upload)

## Credential Setup

Collect before starting: manifest path, build command, zip command, output path, CI platform, release policy.

### 1. Enable Chrome Web Store API

`https://console.cloud.google.com/apis/library/chromewebstore.googleapis.com` → Enable

### 2. OAuth Consent Screen

`https://console.cloud.google.com/apis/credentials/consent` → External → fill app name + emails → add test user if in Testing mode. Move to Production for stable refresh tokens.

### 3. Create OAuth Client

`https://console.cloud.google.com/apis/credentials` → Create Credentials → OAuth client ID → Web application → add redirect URI: `https://developers.google.com/oauthplayground`

Capture: `CWS_CLIENT_ID`, `CWS_CLIENT_SECRET`

### 4. Generate Refresh Token

`https://developers.google.com/oauthplayground/` → settings gear → Use your own OAuth credentials → paste client ID/secret → scope: `https://www.googleapis.com/auth/chromewebstore` → Authorize APIs → sign in → Exchange authorization code for tokens

Capture: `CWS_REFRESH_TOKEN`

### 5. Store IDs

Chrome Web Store Developer Dashboard → copy extension item ID and publisher ID.

Capture: `CWS_EXTENSION_ID`, `CWS_PUBLISHER_ID`

### Credential Checklist

All five required before proceeding: `CWS_CLIENT_ID`, `CWS_CLIENT_SECRET`, `CWS_REFRESH_TOKEN`, `CWS_PUBLISHER_ID`, `CWS_EXTENSION_ID`

## Secret Storage

```bash
# aidevops encrypted storage (preferred)
aidevops secret set CWS_CLIENT_ID
aidevops secret set CWS_CLIENT_SECRET
aidevops secret set CWS_REFRESH_TOKEN
aidevops secret set CWS_PUBLISHER_ID
aidevops secret set CWS_EXTENSION_ID

# Upload to GitHub Actions
chrome-webstore-helper.sh upload-secrets  # reads local env, validates, uploads via gh secret set
```

Local template (no real values committed):

```env
CWS_CLIENT_ID=
CWS_CLIENT_SECRET=
CWS_REFRESH_TOKEN=
CWS_PUBLISHER_ID=
CWS_EXTENSION_ID=
```

## Release Workflow (Version-Triggered)

1. Read local version from `manifest.json`
2. Exchange refresh token: `POST https://oauth2.googleapis.com/token`
3. Fetch CWS status: `GET https://chromewebstore.googleapis.com/v2/publishers/<publisherId>/items/<extensionId>:fetchStatus`
4. Extract published version from `publishedItemRevisionStatus.distributionChannels[0].crxVersion`
5. If local == published → skip (no-op)
6. If version changed → build zip → upload → publish

Success states: `PENDING_REVIEW`, `PUBLISHED`, `PUBLISHED_TO_TESTERS`, `STAGED`

### GitHub Actions Workflow

```yaml
name: Chrome Web Store Release
on:
  push:
    branches: [main]
  workflow_dispatch:
jobs:
  release:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-node@v4
        with:
          node-version: '20'
      - run: npm ci
      - run: npm run build
      - name: Publish to Chrome Web Store
        env:
          CWS_CLIENT_ID: ${{ secrets.CWS_CLIENT_ID }}
          CWS_CLIENT_SECRET: ${{ secrets.CWS_CLIENT_SECRET }}
          CWS_REFRESH_TOKEN: ${{ secrets.CWS_REFRESH_TOKEN }}
          CWS_PUBLISHER_ID: ${{ secrets.CWS_PUBLISHER_ID }}
          CWS_EXTENSION_ID: ${{ secrets.CWS_EXTENSION_ID }}
        run: chrome-webstore-helper.sh publish --manifest src/manifest.json
```

## Status Checker

```bash
chrome-webstore-helper.sh status --manifest src/manifest.json
chrome-webstore-helper.sh status --json  # machine-readable
```

Outputs: `itemId`, `localVersion`, `publishedVersion`, `publishedState`, `upToDate`. Exits non-zero on auth/API errors.

## API Reference

```bash
# Token exchange
curl -X POST https://oauth2.googleapis.com/token \
  -d "client_id=$CWS_CLIENT_ID" \
  -d "client_secret=$CWS_CLIENT_SECRET" \
  -d "refresh_token=$CWS_REFRESH_TOKEN" \
  -d "grant_type=refresh_token"

# Fetch status
curl -X GET \
  "https://chromewebstore.googleapis.com/v2/publishers/$CWS_PUBLISHER_ID/items/$CWS_EXTENSION_ID:fetchStatus" \
  -H "Authorization: Bearer $ACCESS_TOKEN"

# Upload
curl -X POST \
  "https://chromewebstore.googleapis.com/upload/v2/publishers/$CWS_PUBLISHER_ID/items/$CWS_EXTENSION_ID:upload" \
  -H "Authorization: Bearer $ACCESS_TOKEN" \
  -H "Content-Type: application/zip" \
  --data-binary @extension.zip

# Publish
curl -X POST \
  "https://chromewebstore.googleapis.com/v2/publishers/$CWS_PUBLISHER_ID/items/$CWS_EXTENSION_ID:publish" \
  -H "Authorization: Bearer $ACCESS_TOKEN"
```

## Troubleshooting

| Error | Cause | Fix |
|-------|-------|-----|
| `invalid_grant` | Wrong/expired refresh token or wrong account | Regenerate via OAuth Playground; verify client ID/secret match |
| `403` from CWS | Account lacks publisher permissions | Verify publisher ID matches extension owner |
| Workflow no-op | Local version == published version | Bump version in `manifest.json` |
| Upload failure | Invalid zip or manifest | Check API response; validate zip structure and `manifest.json` |
| Version mismatch guard | Multiple version files out of sync | Align `manifest.json` and `package.json` before publishing |

## Security

- Never commit credentials to git or hardcode in workflow YAML
- Never auto-publish every push without version comparison
- Use `aidevops secret set` for encrypted credential management
- Use `--dry-run` to preview before actual publish

## Links

- API overview: `https://developer.chrome.com/docs/webstore/using-api`
- OAuth Playground: `https://developers.google.com/oauthplayground/`
- API enablement: `https://console.cloud.google.com/apis/library/chromewebstore.googleapis.com`
- Credentials: `https://console.cloud.google.com/apis/credentials`
