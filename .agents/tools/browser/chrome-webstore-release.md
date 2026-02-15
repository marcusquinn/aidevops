---
name: chrome-webstore-release
description: Chrome Web Store release automation - OAuth setup, API publish workflow, version-triggered CI, status checking
model: sonnet
tools: [bash, read, write]
---

# Chrome Web Store Release Automation

This subagent guides you through setting up Chrome Web Store (CWS) release automation for Chrome extensions. It covers OAuth credential setup, API-based publishing, version-triggered CI workflows, and submission status checking.

## When to Use

- Setting up automated Chrome extension releases from scratch
- Implementing version-triggered publish workflows to avoid accidental publishes
- Configuring OAuth and refresh token for CWS API access
- Creating status-checker scripts to verify PUBLISHED/PENDING_REVIEW states
- Wiring secrets into local environment and CI (with optional `gh` automation)

## Quick Start

```bash
# Interactive credential setup
chrome-webstore-helper.sh setup

# Publish extension (build + zip + upload + publish)
chrome-webstore-helper.sh publish --manifest path/to/manifest.json

# Check submission status
chrome-webstore-helper.sh status

# Upload secrets to GitHub (requires gh CLI)
chrome-webstore-helper.sh upload-secrets
```

## Prerequisites

- Chrome extension with `manifest.json`
- Google Cloud project with Chrome Web Store API enabled
- Publisher account on Chrome Web Store Developer Dashboard
- `gh` CLI (optional, for automated secret upload)
- `jq` for JSON parsing

## Step 1: Project Discovery

Before credential setup, collect these inputs:

- **Manifest path**: Location of `manifest.json` containing extension version
- **Build command**: Command to build the extension (e.g., `npm run build`)
- **Zip command**: Command to package extension (e.g., `zip -r extension.zip dist/`)
- **Output path**: Path to packaged zip file
- **CI platform**: GitHub Actions (default), GitLab CI, etc.
- **Release policy**: Publish on version change, tags, or manual dispatch
- **Secret storage**: `.env`, `.env.local`, or other convention

Ask the user:

- "Do you want CI to publish only when version changes?" (recommended: yes)
- "Do you want me to wire GitHub secret upload via `gh`?" (if GitHub Actions)

## Step 2: Credential Walkthrough

### 2.1 Enable Chrome Web Store API

**User action** (manual):

1. Open: `https://console.cloud.google.com/apis/library/chromewebstore.googleapis.com`
2. Select your Google Cloud project
3. Click **Enable** for Chrome Web Store API

**Agent prompt**: "When Chrome Web Store API shows as Enabled, confirm and I will move to OAuth setup."

### 2.2 Configure OAuth Consent Screen

**User action** (manual):

1. Open: `https://console.cloud.google.com/apis/credentials/consent`
2. Choose **External** user type (for non-Workspace apps)
3. Fill in:
   - App name
   - Support email
   - Developer contact email
4. Save and continue through scopes (no custom scopes needed)
5. Add your Google account as a test user if app is in Testing mode
6. Save

**Agent guidance**: If user wants stable long-lived refresh token behavior, recommend moving consent screen to Production when ready.

### 2.3 Create OAuth Client

**User action** (manual):

1. Open: `https://console.cloud.google.com/apis/credentials`
2. Click **Create Credentials** → **OAuth client ID**
3. Choose application type: **Web application**
4. Add authorized redirect URI exactly:
   - `https://developers.google.com/oauthplayground`
5. Create client

**Capture values**:

- `CWS_CLIENT_ID`
- `CWS_CLIENT_SECRET`

**Agent prompt**: "Paste `CWS_CLIENT_ID` and `CWS_CLIENT_SECRET` when ready (I will treat them as secrets)."

### 2.4 Generate Refresh Token (OAuth Playground)

**User action** (manual):

1. Open: `https://developers.google.com/oauthplayground/`
2. Click the settings gear icon
3. Enable **Use your own OAuth credentials**
4. Paste `CWS_CLIENT_ID` and `CWS_CLIENT_SECRET`
5. In Step 1, enter scope:
   - `https://www.googleapis.com/auth/chromewebstore`
6. Click **Authorize APIs**
7. Sign in with the Google account that owns/publishes the extension
8. Click **Exchange authorization code for tokens**
9. Copy refresh token

**Capture value**:

- `CWS_REFRESH_TOKEN`

**Agent prompt**: "Paste `CWS_REFRESH_TOKEN` now. I will only place it in local secret storage/CI secrets."

### 2.5 Capture Store IDs

**User action** (manual):

1. Open Chrome Web Store Developer Dashboard
2. Copy extension item ID from URL or item details
3. Copy publisher ID from account details or URL

**Capture values**:

- `CWS_EXTENSION_ID` (extension item ID from store listing URL)
- `CWS_PUBLISHER_ID` (developer/publisher ID from account)

**Agent instruction**: If user is unsure, ask them to open the Chrome Web Store Developer Dashboard and copy IDs from item/account URLs or account details.

### 2.6 Credential Checklist

Do not proceed until all five exist:

- `CWS_CLIENT_ID`
- `CWS_CLIENT_SECRET`
- `CWS_REFRESH_TOKEN`
- `CWS_PUBLISHER_ID`
- `CWS_EXTENSION_ID`

## Step 3: Local Secret File and CI Secret Setup

### Local Secret Template

Create a local template file (no real values committed):

```env
CWS_CLIENT_ID=
CWS_CLIENT_SECRET=
CWS_REFRESH_TOKEN=
CWS_PUBLISHER_ID=
CWS_EXTENSION_ID=
```

Ensure real secret file path is gitignored (e.g., `.env`, `.env.local`).

### Recommended: aidevops Secret Storage

For encrypted secret storage:

```bash
aidevops secret set CWS_CLIENT_ID
aidevops secret set CWS_CLIENT_SECRET
aidevops secret set CWS_REFRESH_TOKEN
aidevops secret set CWS_PUBLISHER_ID
aidevops secret set CWS_EXTENSION_ID
```

Secrets are stored in gopass (GPG-encrypted) or `~/.config/aidevops/credentials.sh` (plaintext fallback, 600 permissions).

### GitHub Actions Secret Upload

If using GitHub Actions, ask user if `gh` automation is desired.

**Verify `gh` CLI**:

```bash
gh --version
gh auth status
```

If `gh` auth is missing, tell user to run: `gh auth login`

**Upload secrets**:

```bash
chrome-webstore-helper.sh upload-secrets
```

This command:

- Reads secret values from local env file or aidevops secret storage
- Validates all required keys are present
- Supports `--dry-run` to preview without uploading
- Masks values in dry-run output
- Uploads with `gh secret set ... --repo ...`
- Fails fast on missing keys/auth

**Manual fallback**: If user declines `gh`, provide manual secret entry checklist for repository settings.

## Step 4: Release Workflow Blueprint (Version-Triggered)

Design the CI workflow around this logic:

1. **Read local manifest version** from `manifest.json`
2. **Optionally compare** with a secondary version file and fail on mismatch
3. **Exchange refresh token for access token**:
   - `POST https://oauth2.googleapis.com/token`
4. **Fetch CWS status**:
   - `GET https://chromewebstore.googleapis.com/v2/publishers/<publisherId>/items/<extensionId>:fetchStatus`
5. **Extract current published version** from:
   - `publishedItemRevisionStatus.distributionChannels[0].crxVersion`
6. **If local version == published version**, skip publish (no-op)
7. **If version changed**:
   - Build package zip
   - Upload zip:
     - `POST https://chromewebstore.googleapis.com/upload/v2/publishers/<publisherId>/items/<extensionId>:upload`
   - Handle async upload state with polling when needed
   - Publish:
     - `POST https://chromewebstore.googleapis.com/v2/publishers/<publisherId>/items/<extensionId>:publish`

**Successful submission states**:

- `PENDING_REVIEW`
- `PUBLISHED`
- `PUBLISHED_TO_TESTERS`
- `STAGED`

### Example GitHub Actions Workflow

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

      - name: Setup Node.js
        uses: actions/setup-node@v4
        with:
          node-version: '20'

      - name: Install dependencies
        run: npm ci

      - name: Build extension
        run: npm run build

      - name: Publish to Chrome Web Store
        env:
          CWS_CLIENT_ID: ${{ secrets.CWS_CLIENT_ID }}
          CWS_CLIENT_SECRET: ${{ secrets.CWS_CLIENT_SECRET }}
          CWS_REFRESH_TOKEN: ${{ secrets.CWS_REFRESH_TOKEN }}
          CWS_PUBLISHER_ID: ${{ secrets.CWS_PUBLISHER_ID }}
          CWS_EXTENSION_ID: ${{ secrets.CWS_EXTENSION_ID }}
        run: |
          chrome-webstore-helper.sh publish --manifest src/manifest.json
```

## Step 5: Submission Status Checker

Create a script dedicated to "what is the latest submission state?".

**Required behavior**:

- Accepts env values (and optional `--env-file`)
- Optionally accepts `--manifest` for local version comparison
- Supports `--json` for machine-readable output
- Calls token endpoint + `fetchStatus`
- Outputs normalized fields:
  - `itemId`
  - `localVersion`
  - `publishedVersion`
  - `publishedState`
  - `submittedVersion`
  - `submittedState`
  - `upToDate`
  - `pendingReview`
- Exits non-zero on auth/API/input errors

**Helpful checks to include**:

- Flag version mismatch between manifest and package metadata
- Show whether uploaded version is pending review but not yet published
- Print concise human summary when `--json` is not used

**Example usage**:

```bash
# Check status with local manifest comparison
chrome-webstore-helper.sh status --manifest src/manifest.json

# JSON output for CI
chrome-webstore-helper.sh status --json
```

## Step 6: Guided Verification Flow

Run this with the user:

1. **Confirm status checker runs successfully** before release
2. **Bump extension version** (patch) in all version sources
3. **Push branch and trigger workflow**
4. **Confirm workflow** either:
   - Skips (if no version change), or
   - Uploads and submits publish
5. **Re-run status checker**:
   - Expect `PENDING_REVIEW` first in many cases
   - Later expect published channel to match local version

## Troubleshooting

### `invalid_grant` Error

**Cause**: Wrong/expired refresh token, wrong OAuth client, or wrong account

**Fix**:

- Regenerate refresh token via OAuth Playground
- Verify OAuth client ID and secret match
- Ensure refresh token was generated with the correct Google account

### `403` from CWS Endpoint

**Cause**: Account lacks publisher permissions for that extension

**Fix**:

- Verify publisher ID matches the account that owns the extension
- Check that the Google account has publisher access in Chrome Web Store Developer Dashboard

### Workflow No-Op

**Cause**: Local version equals published version by design

**Fix**: This is expected behavior. Bump version in `manifest.json` to trigger publish.

### Upload Failure

**Cause**: Invalid zip structure or manifest

**Fix**:

- Inspect API response for specific error
- Verify packaged zip structure matches Chrome extension requirements
- Validate `manifest.json` syntax and required fields

### Version Mismatch Guard Failure

**Cause**: Multiple version files out of sync

**Fix**: Align all declared version files (e.g., `manifest.json`, `package.json`) before publishing.

## API Reference

### Token Exchange

```bash
curl -X POST https://oauth2.googleapis.com/token \
  -d "client_id=$CWS_CLIENT_ID" \
  -d "client_secret=$CWS_CLIENT_SECRET" \
  -d "refresh_token=$CWS_REFRESH_TOKEN" \
  -d "grant_type=refresh_token"
```

### Fetch Status

```bash
curl -X GET \
  "https://chromewebstore.googleapis.com/v2/publishers/$CWS_PUBLISHER_ID/items/$CWS_EXTENSION_ID:fetchStatus" \
  -H "Authorization: Bearer $ACCESS_TOKEN"
```

### Upload Extension

```bash
curl -X POST \
  "https://chromewebstore.googleapis.com/upload/v2/publishers/$CWS_PUBLISHER_ID/items/$CWS_EXTENSION_ID:upload" \
  -H "Authorization: Bearer $ACCESS_TOKEN" \
  -H "Content-Type: application/zip" \
  --data-binary @extension.zip
```

### Publish Extension

```bash
curl -X POST \
  "https://chromewebstore.googleapis.com/v2/publishers/$CWS_PUBLISHER_ID/items/$CWS_EXTENSION_ID:publish" \
  -H "Authorization: Bearer $ACCESS_TOKEN"
```

## Useful Links

- Chrome Web Store API overview: `https://developer.chrome.com/docs/webstore/using-api`
- Publish endpoint: `https://developer.chrome.com/docs/webstore/publish`
- OAuth Playground: `https://developers.google.com/oauthplayground/`
- API enablement: `https://console.cloud.google.com/apis/library/chromewebstore.googleapis.com`
- Credentials page: `https://console.cloud.google.com/apis/credentials`

## Security Guardrails

- **Never commit credentials** to git
- **Never hardcode secrets** in workflow YAML
- **Never auto-publish every push** without version comparison
- **Keep setup instructions explicit** and user-confirmed at each manual step
- **Prefer repeatable helper scripts** over ad-hoc one-off commands
- **Use aidevops secret storage** for encrypted credential management

## Helper Script Reference

See `chrome-webstore-helper.sh` for implementation:

- `setup` - Interactive credential walkthrough
- `publish` - Build + zip + upload + publish via CWS API
- `status` - Fetch submission state
- `upload-secrets` - Upload secrets to GitHub via `gh` CLI

## Integration with aidevops

This subagent integrates with the aidevops framework:

- **Secret storage**: `aidevops secret set CWS_*` for encrypted credentials
- **CI integration**: GitHub Actions workflow templates
- **Helper script**: `chrome-webstore-helper.sh` in `.agents/scripts/`
- **Subagent index**: Entry in `subagent-index.toon` under `tools/browser/`

## Best Practices

1. **Version comparison**: Always compare local vs published version to avoid no-op publishes
2. **Dry-run first**: Test with `--dry-run` before actual publish
3. **Status checking**: Verify status before and after publish
4. **Secret masking**: Never log secret values in CI output
5. **Fail fast**: Exit early on missing credentials or API errors
6. **Idempotent**: Design workflows to be safely re-runnable
