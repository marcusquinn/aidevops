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
- **Project pin**: `asc init --app-id <id>` (saves `.asc/project.json`, auto-used by all commands)
- **Verify before use**: `command -v asc >/dev/null || brew install tddworks/tap/asccli`
- **GitHub**: https://github.com/tddworks/asc-cli (MIT, Swift, 130+ commands, 100+ API endpoints)
- **Website**: https://asccli.app
- **Skills**: [Official](https://github.com/tddworks/asc-cli-skills) (27 skills) | [Community](https://github.com/rudrankriyam/app-store-connect-cli-skills) (22 workflow skills)
- **Web apps**: [Command Center](https://asccli.app/command-center) | [Console](https://asccli.app/console) | [Screenshot Studio](https://asccli.app/editor)
- **Requirements**: macOS 13+, App Store Connect API key

**CAEOAS design**: Every JSON response includes an `affordances` field with ready-to-run next commands encoding business rules. Always follow affordances instead of constructing commands manually.

<!-- AI-CONTEXT-END -->

## Install and Auth

```bash
brew install tddworks/tap/asccli

# Create API key at https://appstoreconnect.apple.com/access/integrations/api
asc auth login --key-id YOUR_KEY_ID --issuer-id YOUR_ISSUER_ID \
  --private-key-path ~/.asc/AuthKey_XXXXXX.p8 --name personal  # alias; default: "default"
asc auth check            # verify active credentials
asc apps list             # find your app ID
asc init --app-id <id>    # pin app — skip --app-id on future commands
```

**Multi-account**: `--name` to save, `asc auth use <name>` to switch. Credentials in `~/.asc/credentials.json` — never commit. Use `--private-key-path`, never pass key content as an argument.

## Project Context Resolution

`asc init` saves app context to `.asc/project.json`. Resolution order: (1) explicit `--app-id`, (2) `.asc/project.json`, (3) prompt user to run `asc apps list` then `asc init`.

## CAEOAS Affordances

```json
{
  "id": "v1",
  "state": "PREPARE_FOR_SUBMISSION",
  "affordances": {
    "listLocalizations": "asc version-localizations list --version-id v1",
    "submitForReview":   "asc versions submit --version-id v1"
  }
}
```

`submitForReview` only appears when `isEditable == true`. Always follow affordances — they encode business rules the CLI enforces.

## Command Groups

| Group | Key Commands | Purpose |
|-------|-------------|---------|
| **apps** | `list` | List all apps |
| **versions** | `list`, `create`, `set-build`, `check-readiness`, `submit` | App Store versions and submission |
| **builds** | `list`, `archive`, `upload`, `add-beta-group`, `update-beta-notes` | Build management and upload |
| **testflight** | `groups list`, `testers add/remove/import/export` | Beta distribution |
| **version-localizations** | `list`, `create`, `update` | What's New, description, keywords per locale |
| **app-infos** / **app-info-localizations** | `list`, `update`, `create`, `delete` | App name, subtitle, categories, age rating, per-locale metadata |
| **screenshots** / **screenshot-sets** | `list`, `upload`, `create` | Screenshot management and upload |
| **app-previews** / **app-preview-sets** | `list`, `upload`, `create` | Video preview management (.mp4, .mov, .m4v) |
| **app-shots** | `config`, `generate`, `translate` | AI-powered screenshot generation (Gemini) |
| **iap** / **subscriptions** / **subscription-groups** / **subscription-offers** | `list`, `create`, `submit`, `price-points` | In-app purchases, auto-renewable subscriptions, offers |
| **bundle-ids** / **certificates** / **profiles** / **devices** | `list`, `create`, `delete`, `register`, `revoke` | Code signing and provisioning |
| **reviews** / **review-responses** | `list`, `get`, `create`, `delete` | Customer reviews and developer responses |
| **game-center** | `detail`, `achievements`, `leaderboards` | Game Center management |
| **perf-metrics** / **diagnostics** | `list` | Performance metrics and diagnostic logs |
| **reports** | `sales-reports`, `finance-reports`, `analytics-reports` | Sales, financial, analytics reports |
| **users** / **user-invitations** | `list`, `update`, `remove`, `invite`, `cancel` | Team member management |
| **xcode-cloud** | `products`, `workflows`, `builds` | Xcode Cloud CI/CD |
| **iris** | `status`, `apps list/create` | Private API (browser cookie auth) |
| **plugins** | `list`, `install`, `run` | Custom event handlers |
| **tui** | (interactive) | Terminal UI browser |

**Discover**: `asc --help`, `asc <command> --help`. **Output**: `--output json` (default), `--output table`, `--output markdown`, `--pretty`.

## Key Workflows

### Release Flow (build to App Store review)

```bash
# 1. Archive and upload (or upload pre-built IPA)
asc builds archive --scheme MyApp --upload --app-id APP_ID --version 1.2.0 --build-number 55
# OR: asc builds upload --app-id APP_ID --file MyApp.ipa --version 1.2.0 --build-number 55

# 2. Distribute to TestFlight
GROUP_ID=$(asc testflight groups list --app-id APP_ID | jq -r '.data[0].id')
BUILD_ID=$(asc builds list --app-id APP_ID | jq -r '.data[0].id')
asc builds add-beta-group --build-id "$BUILD_ID" --beta-group-id "$GROUP_ID"

# 3. Link build to version, update What's New
VERSION_ID=$(asc versions list --app-id APP_ID | jq -r '.data[0].id')
asc versions set-build --version-id "$VERSION_ID" --build-id "$BUILD_ID"
LOC_ID=$(asc version-localizations list --version-id "$VERSION_ID" | jq -r '.data[0].id')
asc version-localizations update --localization-id "$LOC_ID" --whats-new "Bug fixes and improvements"

# 4. Pre-flight check and submit
asc versions check-readiness --version-id "$VERSION_ID"
asc versions submit --version-id "$VERSION_ID"
```

### TestFlight Distribution

```bash
asc testflight groups list --app-id APP_ID
asc testflight testers add --beta-group-id GROUP_ID --email user@example.com
asc testflight testers import --beta-group-id GROUP_ID --file testers.csv
asc builds update-beta-notes --build-id BUILD_ID --locale en-US --notes "What's new in beta"
```

### Code Signing Setup

```bash
asc bundle-ids create --name "My App" --identifier com.example.app --platform ios
asc certificates create --type IOS_DISTRIBUTION --csr-content "$(cat MyApp.certSigningRequest)"
asc profiles create --name "App Store Profile" --type IOS_APP_STORE \
  --bundle-id-id BID --certificate-ids CERT_ID
```

### Metadata and Localisation

```bash
asc app-info-localizations update --localization-id LOC_ID \
  --name "My App" --subtitle "Do things faster"
asc version-localizations update --localization-id LOC_ID \
  --whats-new "Bug fixes" --description "Full description here"
```

### AI Screenshot Generation

```bash
asc app-shots config --gemini-api-key KEY    # one-time setup
asc app-shots generate                        # iPhone 6.9" at 1320x2868
asc app-shots generate --device-type APP_IPHONE_67
asc app-shots translate --to zh --to ja       # localise all screens
```

## Web Apps

Since v0.1.57, web apps are hosted at asccli.app. Run `asc web-server` to start a local API bridge (`/api/run`) that the hosted apps connect to for CLI execution.

| App | URL | Purpose |
|-----|-----|---------|
| **Command Center** | https://asccli.app/command-center | Interactive ASC dashboard — apps, builds, TestFlight, screenshots, subscriptions, reviews |
| **Console** | https://asccli.app/console | CLI reference + embedded terminal, Cmd+K search |
| **Screenshot Studio** | https://asccli.app/editor | Visual screenshot builder with device bezels, text layers, gradient backgrounds |

```bash
asc web-server                    # default ports 8420/8421
asc web-server --port 18420       # custom port — binds N and N+1 (HTTP/HTTPS); leave gap of 2
```

## Agent Skills

| Pack | Install | Focus |
|------|---------|-------|
| **Official** (tddworks) | `asc skills install --all` | Per-command-group reference: flags, output schemas, error tables |
| **Community** (rudrankriyam) | `npx skills add rudrankriyam/app-store-connect-cli-skills` | Workflow orchestration: release flows, ASO audit, localization, RevenueCat sync, crash triage |

Skills are loaded on-demand when relevant tasks are detected — not pre-loaded into context.

## Optional: Blitz MCP Server

[Blitz](https://github.com/blitzdotdev/blitz-mac) is a native macOS app providing 30+ MCP tools for iOS development (simulator, ASC, build pipeline). Overlaps with XcodeBuildMCP and ios-simulator-mcp but adds ASC submission tools. Use as an alternative if you prefer a GUI-backed MCP server over the `asc` CLI.

```json
{ "mcpServers": { "blitz": { "command": "npx", "args": ["-y", "@blitzdev/blitz-mcp"] } } }
```

## Integration with aidevops Mobile Stack

| Tool | Role |
|------|------|
| **asc CLI** | App Store Connect API — publishing, metadata, TestFlight, subscriptions, reports |
| **XcodeBuildMCP** | Xcode project build/test/run (76 tools) |
| **ios-simulator-mcp** | Simulator interaction — UI testing, screenshots, accessibility |
| **Maestro** | Repeatable scripted E2E test flows |
| **RevenueCat** | Server-side subscription tracking, analytics |

**Lifecycle**: Build (xcodebuild-mcp) → Test (maestro + ios-simulator-mcp) → Upload (`asc builds archive --upload`) → TestFlight (`asc testflight`) → Metadata (`asc version-localizations`) → Screenshots (`asc app-shots generate` + `asc screenshots upload`) → Submit (`asc versions check-readiness` + `asc versions submit`) → Monitor (`asc reviews list`, `asc perf-metrics list`)

## Related

- `tools/mobile/app-dev.md` — Full mobile development lifecycle
- `tools/mobile/app-dev/publishing.md` — App Store submission checklists and compliance
- `tools/mobile/xcodebuild-mcp.md` — Xcode build/test/deploy MCP
- `tools/mobile/ios-simulator-mcp.md` — Simulator interaction MCP
- `services/payments/revenuecat.md` — Subscription management
- `services/hosting/local-hosting.md` — localdev for asc-web hosting
