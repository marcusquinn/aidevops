---
description: App Store Connect CLI (asc) - manage iOS/macOS apps, builds, TestFlight, metadata, subscriptions, screenshots, and submissions from terminal
mode: subagent
tools:
  read: true
  write: true
  edit: true
  bash: true
  glob: true
  grep: true
  webfetch: false
  task: false
---

# App Store Connect CLI — asc

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Install**: `brew install tddworks/tap/asccli` (NOT `brew install asc` — different package)
- **Auth**: `asc auth login --key-id KEY --issuer-id ISSUER --private-key-path ~/.asc/AuthKey.p8`
- **API key**: Create at https://appstoreconnect.apple.com/access/integrations/api
- **Project pin**: `asc init --app-id <id>` (saves `.asc/project.json`, auto-used by all commands)
- **Verify**: `asc auth check` | **Multi-account**: `asc auth use <name>`
- **Context resolution**: explicit `--app-id` > `.asc/project.json` > prompt user to `asc init` (CI must use `--app-id` or pre-run `asc init`)
- **GitHub**: https://github.com/tddworks/asc-cli (MIT, Swift, 130+ commands)
- **Website**: https://asccli.app | **Web apps**: [Command Center](https://asccli.app/command-center), [Console](https://asccli.app/console), [Screenshot Studio](https://asccli.app/editor)
- **Skills**: [Official](https://github.com/tddworks/asc-cli-skills) (27 skills) | [Community](https://github.com/rudrankriyam/app-store-connect-cli-skills) (22 workflow skills)
- **Requirements**: macOS 13+, App Store Connect API key, `jq` (workflow scripts use `jq -r`)

**Dependency check**: Before any `asc` command:
```bash
command -v asc >/dev/null || { brew install tddworks/tap/asccli || exit 1; }
command -v jq >/dev/null || { brew install jq || exit 1; }
```

**Credential security**: `asc auth login` stores the private key PEM in `~/.asc/credentials.json`. Never commit this file. Use `--private-key-path` — never pass key content as an argument.

**CAEOAS**: Every JSON response includes an `affordances` field with state-aware next commands. Always follow affordances instead of constructing commands manually — they encode business rules the CLI enforces. Example: `submitForReview` only appears when `isEditable == true`.

<!-- AI-CONTEXT-END -->

## Command Groups

| Group | Commands | Purpose |
|-------|----------|---------|
| **versions** | `list`, `create`, `set-build`, `check-readiness`, `submit` | Versions and submission |
| **builds** | `list`, `archive`, `upload`, `add-beta-group`, `update-beta-notes` | Build management |
| **testflight** | `groups list`, `testers add/remove/import/export` | Beta distribution |
| **version-localizations** | `list`, `create`, `update` | What's New, description, keywords per locale |
| **app-infos** / **app-info-localizations** | `list`, `update`, `create`, `delete` | App name, subtitle, categories, per-locale metadata |
| **screenshot-sets** / **screenshots** / **app-preview-sets** / **app-previews** | `list`, `create`, `upload` | Screenshots and video previews |
| **app-shots** | `config`, `generate`, `translate` | AI screenshot generation (Gemini) |
| **iap** | `list`, `create`, `submit`, `price-points`, `prices` | In-app purchases |
| **subscriptions** / **subscription-groups** / **subscription-offers** | `list`, `create`, `submit` | Auto-renewable subscriptions, groups, offers |
| **bundle-ids** / **certificates** / **profiles** / **devices** | `list`, `create`, `delete`, `register`, `revoke` | Code signing and provisioning |
| **reviews** / **review-responses** | `list`, `get`, `create`, `delete` | Customer reviews and responses |
| **reports** | `sales-reports`, `finance-reports`, `analytics-reports` | Sales, financial, analytics |
| **users** / **user-invitations** | `list`, `update`, `remove`, `invite`, `cancel` | Team management |
| **xcode-cloud** | `products`, `workflows`, `builds` | Xcode Cloud CI/CD |
| **Other** | `apps list`, `game-center`, `perf-metrics`, `diagnostics`, `iris`, `plugins`, `tui` | Apps, Game Center, performance, private API, plugins, TUI |

**Discover**: `asc --help`, `asc <cmd> --help` | **Output**: `--output json` (default), `--output table`, `--output markdown`, `--pretty`

## Key Workflows

### Release Flow

```bash
# 1. Archive and upload (or upload pre-built IPA)
asc builds archive --scheme MyApp --upload --app-id APP_ID --version 1.2.0 --build-number 55
# OR: asc builds upload --app-id APP_ID --file MyApp.ipa --version 1.2.0 --build-number 55

# 2. TestFlight distribution
GROUP_ID=$(asc testflight groups list --app-id APP_ID | jq -r '.data[0].id')
BUILD_ID=$(asc builds list --app-id APP_ID | jq -r '.data[0].id')
asc builds add-beta-group --build-id "$BUILD_ID" --beta-group-id "$GROUP_ID"

# 3. Link build to version, update What's New, submit
VERSION_ID=$(asc versions list --app-id APP_ID | jq -r '.data[0].id')
asc versions set-build --version-id "$VERSION_ID" --build-id "$BUILD_ID"
LOC_ID=$(asc version-localizations list --version-id "$VERSION_ID" | jq -r '.data[0].id')
asc version-localizations update --localization-id "$LOC_ID" --whats-new "Bug fixes and improvements"
asc versions check-readiness --version-id "$VERSION_ID"
asc versions submit --version-id "$VERSION_ID"
```

### Other Workflows

```bash
# TestFlight — add testers, import CSV, set beta notes
asc testflight testers add --beta-group-id GROUP_ID --email user@example.com
asc testflight testers import --beta-group-id GROUP_ID --file testers.csv
asc builds update-beta-notes --build-id BUILD_ID --locale en-US --notes "What's new in beta"
# Code signing — bundle ID, certificate, provisioning profile
asc bundle-ids create --name "My App" --identifier com.example.app --platform ios
asc certificates create --type IOS_DISTRIBUTION --csr-content "$(cat MyApp.certSigningRequest)"
asc profiles create --name "App Store Profile" --type IOS_APP_STORE --bundle-id-id BID --certificate-ids CERT_ID
# Metadata and AI screenshots
asc app-info-localizations update --localization-id LOC_ID --name "My App" --subtitle "Do things faster"
asc app-shots config --gemini-api-key KEY && asc app-shots generate
asc app-shots translate --to zh --to ja
```

## Web Apps and Local API Bridge

Run `asc web-server` to start the local API bridge (ports 8420 HTTP, 8421 HTTPS). Web apps at asccli.app connect to it for CLI execution. `--port N` binds **two** ports (N and N+1) — leave a gap of 2+.

## Agent Skills

Install on-demand (not pre-loaded): **Official** `asc skills install --all` (per-command reference) | **Community** `npx skills add rudrankriyam/app-store-connect-cli-skills` (workflow orchestration: releases, ASO, localization, RevenueCat, crash triage).

## Blitz MCP Server (Optional)

[Blitz](https://github.com/blitzdotdev/blitz-mac) — native macOS app with 30+ MCP tools for iOS dev. Overlaps with XcodeBuildMCP/ios-simulator-mcp but adds ASC submission. MCP config: `{ "mcpServers": { "blitz": { "command": "npx", "args": ["-y", "@blitzdev/blitz-mcp"] } } }`

## Mobile Stack Integration

| Tool | Role |
|------|------|
| **asc CLI** | App Store Connect API — publishing, metadata, TestFlight, subscriptions, reports |
| **XcodeBuildMCP** | Xcode build/test/deploy (76 tools) |
| **ios-simulator-mcp** | Simulator UI testing, screenshots, accessibility |
| **Maestro** | Repeatable E2E test flows |
| **RevenueCat** | Server-side subscription tracking, analytics |

## Related

- `tools/mobile/app-dev.md` — Mobile dev lifecycle | `tools/mobile/app-dev/publishing.md` — Submission checklists
- `tools/mobile/xcodebuild-mcp.md` — Xcode MCP | `tools/mobile/ios-simulator-mcp.md` — Simulator MCP
- `services/payments/revenuecat.md` — Subscriptions | `services/hosting/local-hosting.md` — asc-web hosting
