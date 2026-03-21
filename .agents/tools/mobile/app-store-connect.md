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

- **Purpose**: Programmatic App Store Connect management — builds, releases, TestFlight, metadata, subscriptions, screenshots, code signing, reports
- **Install**: `brew install tddworks/tap/asccli`
- **Auth**: `asc auth login --key-id KEY --issuer-id ISSUER --private-key-path ~/.asc/AuthKey.p8`
- **Project pin**: `asc init --app-id <id>` (saves to `.asc/project.json`, auto-used by all commands)
- **GitHub**: https://github.com/tddworks/asc-cli (MIT, Swift, 130+ commands, 100+ API endpoints)
- **Website**: https://asccli.app
- **Skills (official)**: https://github.com/tddworks/asc-cli-skills (27 skills)
- **Skills (community)**: https://github.com/rudrankriyam/app-store-connect-cli-skills (22 workflow skills)
- **Web apps**: Command Center (`/command-center`), Console (`/console`), Screenshot Studio (`/editor`)

**Key design**: CAEOAS (Commands As Engine Of Application State) — every JSON response includes an `affordances` field with ready-to-run next commands. Always follow affordances instead of constructing commands manually.

**Requirements**: macOS 13+, App Store Connect API key

<!-- AI-CONTEXT-END -->

## Install and Auth

```bash
brew install tddworks/tap/asccli

# Create API key at https://appstoreconnect.apple.com/access/integrations/api
asc auth login \
  --key-id YOUR_KEY_ID \
  --issuer-id YOUR_ISSUER_ID \
  --private-key-path ~/.asc/AuthKey_XXXXXX.p8 \
  --name personal        # optional alias; defaults to "default"

asc auth check            # verify active credentials
asc apps list             # find your app ID
asc init --app-id <id>    # pin app — skip --app-id on future commands
```

**Multi-account**: Save multiple accounts with `--name`, switch with `asc auth use <name>`. Credentials stored in `~/.asc/credentials.json`.

**Credential security**: The `asc auth login` command stores the private key PEM in `~/.asc/credentials.json`. Never commit this file. Never pass key content as a command argument — use `--private-key-path` to reference the file.

## Project Context Resolution

`asc init` saves app context to `.asc/project.json`. All commands that need `--app-id` check this file first.

**Resolution order**:

1. User provided `--app-id` explicitly — use it
2. `.asc/project.json` exists — read `appId` from it
3. Neither — run `asc apps list`, show results, ask user to pick or run `asc init`

## CAEOAS Affordances

Every JSON response includes an `affordances` field with state-aware next commands:

```json
{
  "id": "v1",
  "versionString": "2.1.0",
  "state": "PREPARE_FOR_SUBMISSION",
  "affordances": {
    "listLocalizations": "asc version-localizations list --version-id v1",
    "checkReadiness":    "asc versions check-readiness --version-id v1",
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
| **app-infos** | `list`, `update` | App name, subtitle, categories, age rating |
| **app-info-localizations** | `list`, `create`, `update`, `delete` | Per-locale app metadata |
| **screenshot-sets** | `list`, `create` | Screenshot set management |
| **screenshots** | `list`, `upload` | Screenshot image upload |
| **app-preview-sets** | `list`, `create` | Video preview management |
| **app-previews** | `list`, `upload` | Video preview upload (.mp4, .mov, .m4v) |
| **app-shots** | `config`, `generate`, `translate` | AI-powered screenshot generation (Gemini) |
| **iap** | `list`, `create`, `submit`, `price-points`, `prices` | In-app purchases |
| **subscriptions** | `list`, `create`, `submit` | Auto-renewable subscriptions |
| **subscription-groups** | `list`, `create` | Subscription groups |
| **subscription-offers** | `list`, `create` | Introductory and promotional offers |
| **bundle-ids** | `list`, `create`, `delete` | Bundle ID management |
| **certificates** | `list`, `create`, `revoke` | Signing certificates |
| **profiles** | `list`, `create`, `delete` | Provisioning profiles |
| **devices** | `list`, `register` | Device registration |
| **reviews** | `list`, `get` | Customer reviews |
| **review-responses** | `create`, `get`, `delete` | Developer responses to reviews |
| **game-center** | `detail`, `achievements`, `leaderboards` | Game Center management |
| **perf-metrics** | `list` | Performance metrics (launch, hang, memory) |
| **diagnostics** | `list` | Diagnostic signatures and logs |
| **reports** | `sales-reports`, `finance-reports`, `analytics-reports` | Sales, financial, analytics reports |
| **users** | `list`, `update`, `remove` | Team member management |
| **user-invitations** | `list`, `invite`, `cancel` | Team invitations |
| **xcode-cloud** | `products`, `workflows`, `builds` | Xcode Cloud CI/CD |
| **iris** | `status`, `apps list`, `apps create` | Private API (browser cookie auth) |
| **plugins** | `list`, `install`, `run` | Custom event handlers |
| **tui** | (interactive) | Terminal UI browser |

**Discover commands**: `asc --help`, `asc <command> --help`, `asc <command> <subcommand> --help`

**Output formats**: `--output json` (default), `--output table`, `--output markdown`, `--pretty`

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

# 3. Link build to version
VERSION_ID=$(asc versions list --app-id APP_ID | jq -r '.data[0].id')
asc versions set-build --version-id "$VERSION_ID" --build-id "$BUILD_ID"

# 4. Update What's New
LOC_ID=$(asc version-localizations list --version-id "$VERSION_ID" | jq -r '.data[0].id')
asc version-localizations update --localization-id "$LOC_ID" --whats-new "Bug fixes and improvements"

# 5. Pre-flight check and submit
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

## Web Apps (Local Hosting)

The `asc` CLI includes a web server (`asc web-server`) with two web apps. A third app (Screenshot Studio) lives in the homepage repo and is served separately.

| App | Server | Purpose |
|-----|--------|---------|
| **Command Center** | `asc web-server` | Interactive ASC dashboard — apps, builds, TestFlight, screenshots, subscriptions, reviews |
| **Console** | `asc web-server` | CLI reference + embedded terminal, Cmd+K search |
| **Screenshot Studio** | Static (separate) | Visual App Store screenshot builder with device bezels, text layers, gradient backgrounds |

**Live demos**: https://asccli.app/command-center, https://asccli.app/console, https://asccli.app/editor

### Setup (one-time)

The Homebrew bottle installs the `asc` binary but `asc web-server` extracts only `server.js` to a temp directory — the web app static files (HTML/CSS/JS) are not included. You must clone them separately:

```bash
# 1. Clone web app files (sparse — only the web apps, not the full repo)
mkdir -p ~/.asc/web
git clone --depth 1 --filter=blob:none --sparse \
  https://github.com/tddworks/asc-cli.git ~/.asc/web
git -C ~/.asc/web sparse-checkout set apps/asc-web homepage/editor homepage/static

# 2. Start asc web-server once to create the temp directory, then kill it
asc web-server --port 18420 &
ASC_PID=$!
sleep 2
kill "$ASC_PID" 2>/dev/null
wait "$ASC_PID" 2>/dev/null

# 3. Find the temp directory and symlink web app files into it
TEMP_DIR=$(find /private/var/folders /tmp -name "server.js" -path "*/asc-web-server/*" \
  -exec dirname {} \; 2>/dev/null | head -1)
if [[ -n "$TEMP_DIR" ]]; then
  ln -sf ~/.asc/web/apps/asc-web/command-center "$TEMP_DIR/command-center"
  ln -sf ~/.asc/web/apps/asc-web/console "$TEMP_DIR/console"
  ln -sf ~/.asc/web/apps/asc-web/shared "$TEMP_DIR/shared"
  echo "Symlinked web apps into $TEMP_DIR"
else
  echo "ERROR: Could not find asc-web-server temp directory"
fi
```

### Local hosting with localdev

Register two apps with localdev — one for the asc web-server (Command Center + Console), one for the Screenshot Studio (static):

```bash
# Register apps (one-time). Use ports with a gap of 3+ between them
# because asc web-server binds BOTH --port AND --port+1 (built-in HTTPS).
localdev-helper.sh add asc-web          # e.g. port 3109
localdev-helper.sh add asc-editor 3112  # skip 3110-3111 to avoid collision

# Add /etc/hosts entries (requires sudo — run in your terminal)
sudo sh -c 'echo "127.0.0.1 asc-web.local" >> /etc/hosts'
sudo sh -c 'echo "127.0.0.1 asc-editor.local" >> /etc/hosts'
```

Start the servers on their assigned localdev ports:

```bash
# Command Center + Console (asc web-server on localdev port)
ASC_PORT=$(jq -r '.apps["asc-web"].port' ~/.local-dev-proxy/ports.json)
nohup asc web-server --port "$ASC_PORT" > /tmp/asc-web.log 2>&1 &

# Screenshot Studio (static file server on localdev port)
EDITOR_PORT=$(jq -r '.apps["asc-editor"].port' ~/.local-dev-proxy/ports.json)
nohup npx -y http-server ~/.asc/web/homepage -p "$EDITOR_PORT" --silent > /tmp/asc-editor.log 2>&1 &
```

Access via HTTPS through Traefik:

| App | URL |
|-----|-----|
| **Command Center** | https://asc-web.local/command-center/ |
| **Console** | https://asc-web.local/console/ |
| **Screenshot Studio** | https://asc-editor.local/editor/ |

### Port collision warning

`asc web-server --port N` binds **two** ports: `N` (HTTP) and `N+1` (its own built-in HTTPS). When assigning localdev ports, leave a gap of at least 2 between asc-web and the next app to avoid `EADDRINUSE` errors. Traefik handles TLS termination for the `.local` domains — the built-in HTTPS on port N+1 is unused but still binds.

### Server details

The `asc web-server` runs a Node.js HTTP server. Routes: `/api/run` executes `asc` CLI commands (validated — blocks shell metacharacters), static files served for Command Center and Console. The Screenshot Studio is fully static and works without any backend — it only needs a file server.

## Agent Skills

Two complementary skills packs provide agent guidance:

| Pack | Install | Focus |
|------|---------|-------|
| **Official** (tddworks) | `asc skills install --all` | Per-command-group reference: exact flags, output schemas, error tables |
| **Community** (rudrankriyam) | `npx skills add rudrankriyam/app-store-connect-cli-skills` | Workflow orchestration: release flows, ASO audit, localization, RevenueCat sync, crash triage |

Skills are loaded on-demand by the agent when relevant tasks are detected — they are not pre-loaded into context.

## Optional: Blitz MCP Server

[Blitz](https://github.com/blitzdotdev/blitz-mac) is a native macOS app that provides 30+ MCP tools for iOS development (simulator management, App Store Connect, build pipeline). It includes an npm-installable MCP server:

```bash
# Install MCP server (requires Blitz macOS app running)
npx @blitzdev/blitz-mcp
```

**MCP config** (for Claude Code, Cursor, etc.):

```json
{
  "mcpServers": {
    "blitz": {
      "command": "npx",
      "args": ["-y", "@blitzdev/blitz-mcp"]
    }
  }
}
```

Blitz overlaps with our existing XcodeBuildMCP and ios-simulator-mcp but adds ASC submission tools. Use it as an alternative if you prefer a GUI-backed MCP server over the `asc` CLI.

## Integration with aidevops Mobile Stack

| Tool | Role | When to Use |
|------|------|-------------|
| **asc CLI** | App Store Connect API | Publishing, metadata, TestFlight, subscriptions, reports |
| **XcodeBuildMCP** | Build, test, deploy | Xcode project build/test/run (76 tools) |
| **ios-simulator-mcp** | Simulator interaction | UI testing, screenshots, accessibility |
| **Maestro** | E2E test flows | Repeatable scripted test flows |
| **RevenueCat** | Subscription management | Server-side subscription tracking, analytics |

### Typical Full Lifecycle

```text
1. Build         → xcodebuild-mcp (build_sim, test_sim)
2. Test          → maestro (E2E flows) + ios-simulator-mcp (ad-hoc QA)
3. Upload        → asc builds archive --upload (or asc builds upload)
4. TestFlight    → asc testflight (groups, testers, beta notes)
5. Metadata      → asc version-localizations, app-info-localizations
6. Screenshots   → asc app-shots generate + asc screenshots upload
7. Submit        → asc versions check-readiness + asc versions submit
8. Monitor       → asc reviews list, asc perf-metrics list
```

## Related

- `tools/mobile/app-dev.md` — Full mobile development lifecycle
- `tools/mobile/app-dev/publishing.md` — App Store submission checklists and compliance
- `tools/mobile/xcodebuild-mcp.md` — Xcode build/test/deploy MCP
- `tools/mobile/ios-simulator-mcp.md` — Simulator interaction MCP
- `services/payments/revenuecat.md` — Subscription management
- `services/hosting/local-hosting.md` — localdev for asc-web hosting
