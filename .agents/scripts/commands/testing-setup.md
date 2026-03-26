---
description: Interactive per-repo testing environment setup — configure runtime testing with bundle-aware defaults
agent: Build+
mode: subagent
tools:
  read: true
  write: true
  edit: true
  bash: true
---

Configure runtime testing for the current project. Detects the project type via bundle-helper.sh, proposes sensible defaults, and writes `.aidevops/testing.json` — the per-repo testing config consumed by verify-brief.sh, full-loop's testing gate, and task-complete-helper.sh.

Arguments: $ARGUMENTS

## Purpose

Most AI-generated code is verified only by static analysis (lint, typecheck) and self-assessment. Runtime testing — actually starting the dev server, loading pages, checking API responses — catches an entire class of bugs that static checks miss: state machine errors, polling failures, auth flows, payment integrations, and race conditions.

This command bridges the gap between "tests pass" and "it actually works" by:

1. Detecting the project's runtime environment (npm, docker, localwp, etc.)
2. Asking targeted questions to configure dev server startup, smoke URLs, and stability checks
3. Writing a `.aidevops/testing.json` config that downstream tools consume
4. Optionally running a validation pass to confirm the config works

The config file is committed to the repo so every contributor and every dispatched worker uses the same testing setup.

## When to Use

- **First time**: Run `/testing-setup` in any project to create the initial config
- **After adding environments**: Run `/testing-setup --add` to add a new environment (e.g., adding Docker alongside npm)
- **After changing dev setup**: Run `/testing-setup --validate` to verify the existing config still works
- **Audit**: Run `/testing-setup --show` to display the current config without modifying it

## Workflow

### Step 0: Parse Arguments

```text
Default: Interactive setup (full onboarding flow)
Options:
  --show                 Display current testing.json without modifying
  --validate             Validate existing config (start env, run smoke checks)
  --add                  Add a new environment to existing config
  --reset                Remove existing config and start fresh
  --non-interactive      Use bundle defaults without prompting (for headless dispatch)
  --env <type>           Pre-select environment type (skip detection)
```

### Step 1: Detect Project Type

Use bundle-helper.sh to identify the project type and pre-populate defaults:

```bash
WORKTREE_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
AGENTS_DIR="${HOME}/.aidevops/agents"

# Detect bundle
BUNDLE_NAME=$("${AGENTS_DIR}/scripts/bundle-helper.sh" detect "$WORKTREE_ROOT" 2>/dev/null || echo "cli-tool")
BUNDLE_JSON=$("${AGENTS_DIR}/scripts/bundle-helper.sh" load "$BUNDLE_NAME" 2>/dev/null || echo "{}")

# Check for existing config
TESTING_CONFIG="${WORKTREE_ROOT}/.aidevops/testing.json"
if [[ -f "$TESTING_CONFIG" ]]; then
  echo "Existing testing config found at .aidevops/testing.json"
  echo "Use --reset to start fresh, --add to add an environment, or --validate to check it."
fi
```

Map bundles to likely runtime environments:

| Bundle | Primary Environment | Secondary |
|--------|-------------------|-----------|
| `web-app` | `npm` | `docker` |
| `content-site` | `localwp` or `docker` | `npm` |
| `cli-tool` | `binary` or `npm` | — |
| `library` | `npm` | — |
| `infrastructure` | `docker` | — |
| `agent` | `npm` | — |

### Step 2: Interactive Environment Selection

Present the detected environment with options to override:

```text
Detected project type: {bundle_name}
Suggested runtime environment: {primary_env}

Which runtime environment does this project use for development?

1. npm — Node.js dev server (npm run dev / npm start) (recommended)
2. docker — Docker Compose (docker compose up)
3. localwp — Local by WP (WordPress local development)
4. expo — Expo / React Native (expo start)
5. xcode — Xcode project (xcodebuild / simulator)
6. tauri — Tauri desktop app (cargo tauri dev)
7. binary — Compiled binary (go run / cargo run / custom)
8. manual — No automated startup (provide instructions for human verification)
9. none — This project has no runtime component (pure library, config-only)
```

If the user selects `none`, write a minimal config and exit:

```json
{
  "version": "1.0.0",
  "environments": [],
  "testing_level": "static-only",
  "notes": "No runtime component — static analysis and unit tests only"
}
```

### Step 3: Environment-Specific Questions

Each environment type has targeted questions. Ask sequentially, offering concrete options with one recommended.

#### npm Environment

**Q1: Dev server command**

```text
What command starts the dev server?

1. npm run dev (recommended — detected from package.json scripts)
2. npm start
3. npx next dev / npx vite / npx astro dev
4. Custom command (specify)
```

Detect from package.json if available:

```bash
if [[ -f "${WORKTREE_ROOT}/package.json" ]]; then
  # Check for common dev scripts
  DEV_SCRIPT=$(jq -r '.scripts.dev // empty' "${WORKTREE_ROOT}/package.json")
  START_SCRIPT=$(jq -r '.scripts.start // empty' "${WORKTREE_ROOT}/package.json")
fi
```

**Q2: Dev server port**

```text
What port does the dev server listen on?

1. 3000 (recommended — Next.js, Create React App default)
2. 5173 (Vite default)
3. 4321 (Astro default)
4. 8080
5. Custom port (specify)
```

**Q3: Ready signal**

```text
How do you know the dev server is ready?

1. HTTP 200 on localhost:{port} (recommended — poll until ready)
2. Specific text in stdout (e.g., "ready on", "listening on")
3. Specific URL returns expected content
4. Fixed delay (seconds) — least reliable, use as fallback
```

**Q4: Smoke URLs**

```text
Which URLs should be checked after startup to verify the app works?

1. Just the homepage: / (recommended for simple apps)
2. Homepage + API health: /, /api/health
3. Let me specify URLs
4. Skip smoke checks (not recommended)
```

#### docker Environment

**Q1: Compose file**

```text
Which Docker Compose file?

1. docker-compose.yml (recommended — detected in project root)
2. docker-compose.dev.yml
3. compose.yml
4. Custom path (specify)
```

**Q2: Service name**

```text
Which service is the main application?

1. {auto-detected from compose file} (recommended)
2. Let me specify
```

**Q3: Port mapping**

```text
What host port maps to the application?

1. {auto-detected from compose ports} (recommended)
2. Custom port (specify)
```

**Q4: Ready signal and smoke URLs** — same as npm Q3/Q4.

#### localwp Environment

**Q1: Site name**

```text
What is the Local WP site name?

1. {detected from project directory name} (recommended)
2. Let me specify
```

**Q2: Site URL**

```text
What is the local site URL?

1. http://{site-name}.local (recommended)
2. Custom URL (specify)
```

**Q3: Smoke URLs**

```text
Which pages should be checked after startup?

1. Homepage + wp-admin: /, /wp-admin/ (recommended)
2. Homepage only: /
3. Let me specify URLs
```

#### expo Environment

**Q1: Platform**

```text
Which platform to test?

1. web (recommended — easiest for automated checks)
2. ios (simulator)
3. android (emulator)
```

**Q2: Start command**

```text
Start command?

1. npx expo start --web (recommended)
2. npx expo start
3. Custom (specify)
```

#### xcode Environment

**Q1: Scheme**

```text
Which Xcode scheme to build?

1. {auto-detected from .xcodeproj} (recommended)
2. Let me specify
```

**Q2: Simulator**

```text
Which simulator?

1. iPhone 16 Pro (recommended)
2. iPad Pro
3. Custom (specify)
```

#### tauri Environment

**Q1: Start command**

```text
Start command?

1. cargo tauri dev (recommended)
2. npm run tauri dev
3. Custom (specify)
```

#### binary Environment

**Q1: Build command**

```text
Build command?

1. go build ./... (recommended — detected from go.mod)
2. cargo build
3. make build
4. Custom (specify)
```

**Q2: Run command**

```text
Run command (for smoke test)?

1. ./build-output --help (recommended — verify binary runs)
2. go run . --version
3. Custom (specify)
```

#### manual Environment

**Q1: Instructions**

```text
Describe how a human should verify this project works:

(Free text — stored in config for reference by workers and reviewers)
```

### Step 4: Testing Level Configuration

After environment setup, configure the testing level expectations:

```text
What level of runtime testing should be required for PRs in this project?

1. runtime-verified — Dev server started, smoke URLs checked, stability confirmed
   (recommended for web-app, content-site, infrastructure)
2. smoke-tested — Dev server started, basic health check passed
   (recommended for cli-tool, library with dev server)
3. unit-tested — Unit/integration tests pass, no runtime verification
   (recommended for library, pure packages)
4. self-assessed — Developer self-reports testing status
   (fallback when automated testing is not feasible)
```

Map bundle to recommended level:

| Bundle | Recommended Level |
|--------|------------------|
| `web-app` | `runtime-verified` |
| `content-site` | `runtime-verified` |
| `infrastructure` | `smoke-tested` |
| `cli-tool` | `smoke-tested` |
| `library` | `unit-tested` |
| `agent` | `unit-tested` |

### Step 5: Risk Escalation Patterns (Optional)

For `runtime-verified` and `smoke-tested` levels, ask about high-risk patterns that should trigger mandatory runtime testing even for changes that would normally skip it:

```text
Which code patterns should ALWAYS trigger runtime testing, regardless of change size?

1. Default set: auth, payment, polling, state machine, WebSocket, cron
   (recommended — covers the most common runtime-only bugs)
2. Custom set (specify patterns)
3. None — use testing level uniformly
```

The default risk patterns (stored in config):

```json
{
  "risk_patterns": [
    {"pattern": "auth|login|session|jwt|oauth", "reason": "Authentication flows require runtime verification"},
    {"pattern": "payment|stripe|billing|checkout", "reason": "Payment flows must be runtime-tested"},
    {"pattern": "poll|interval|setTimeout|setInterval|cron", "reason": "Polling/timing bugs are invisible to static analysis"},
    {"pattern": "state.*machine|fsm|transition|status.*change", "reason": "State machine transitions need runtime verification"},
    {"pattern": "websocket|socket\\.io|sse|realtime", "reason": "Real-time connections require runtime testing"},
    {"pattern": "migration|schema.*change|alter.*table", "reason": "Database migrations must be runtime-verified"}
  ]
}
```

### Step 6: Generate Config

Assemble the `.aidevops/testing.json` from interview answers:

```json
{
  "$schema": "https://aidevops.sh/schemas/testing.json",
  "version": "1.0.0",
  "project_type": "{bundle_name}",
  "testing_level": "{selected_level}",
  "environments": [
    {
      "name": "{env_type}",
      "start_command": "{command}",
      "ready_check": {
        "type": "http|stdout|delay",
        "target": "http://localhost:{port}",
        "timeout_seconds": 30,
        "poll_interval_seconds": 2
      },
      "smoke_urls": [
        {"path": "/", "expect_status": 200},
        {"path": "/api/health", "expect_status": 200}
      ],
      "stop_command": "{stop_command}",
      "env_vars": {}
    }
  ],
  "risk_patterns": [],
  "notes": ""
}
```

### Step 7: Write Config and Validate

```bash
TESTING_DIR="${WORKTREE_ROOT}/.aidevops"
TESTING_CONFIG="${TESTING_DIR}/testing.json"

# Create .aidevops directory if it doesn't exist
mkdir -p "$TESTING_DIR"

# Write the config (agent writes via Write tool)
# ... write testing.json ...

# Add to .gitignore check — testing.json should be committed
if [[ -f "${WORKTREE_ROOT}/.gitignore" ]]; then
  if grep -q 'testing.json' "${WORKTREE_ROOT}/.gitignore"; then
    echo "WARNING: .gitignore excludes testing.json — remove the exclusion so the config is shared"
  fi
fi
```

### Step 8: Optional Validation Pass

If `--validate` was passed or the user opts in:

```text
Config written to .aidevops/testing.json

Would you like to validate the config now?

1. Yes — start the dev environment and run smoke checks (recommended)
2. No — save config only (validate later with /testing-setup --validate)
```

If validating:

```bash
# This delegates to verify-brief.sh (t1660.4) when available
# For now, do a basic check:

# 1. Try starting the dev server
# 2. Poll the ready check endpoint
# 3. Hit each smoke URL
# 4. Report results
# 5. Stop the dev server

echo "Starting validation..."
# The actual validation logic lives in verify-brief.sh (t1660.4)
# This command just invokes it with the config
```

If verify-brief.sh is not yet available (t1660.4 not merged), perform a basic validation:

1. Check that the start command exists and is executable
2. For npm: verify the script exists in package.json
3. For docker: verify the compose file exists
4. For localwp: verify the site directory exists
5. Report what would be tested at runtime

### Step 9: Summary and Next Steps

```text
Testing setup complete for {project_name}

Config: .aidevops/testing.json
  Environment: {env_type}
  Testing level: {level}
  Smoke URLs: {count} configured
  Risk patterns: {count} active

Next steps:
  1. Commit .aidevops/testing.json to share with your team
  2. Run /testing-setup --validate to verify the config works
  3. PRs will now include structured testing evidence (t1660.6)
  4. The full-loop testing gate will enforce the configured level (t1660.7)
```

## Non-Interactive Mode

When `--non-interactive` is passed (headless dispatch, CI, or scripted setup):

1. Detect bundle via `bundle-helper.sh`
2. Use the bundle-to-environment mapping from Step 1
3. Auto-detect dev server command from package.json / docker-compose.yml / Makefile
4. Use default port, ready check, and smoke URLs for the detected environment
5. Set testing level to the bundle's recommended level
6. Write config without prompting
7. Run validation if `--validate` is also passed

```bash
# Example: headless setup for a Next.js project
/testing-setup --non-interactive --validate
# Detects: web-app bundle → npm env → npm run dev → port 3000 → runtime-verified
# Writes .aidevops/testing.json and validates
```

## Existing Config Handling

When `.aidevops/testing.json` already exists:

- **Default (no flags)**: Show current config summary and ask if the user wants to modify it
- **`--add`**: Keep existing environments, add a new one (e.g., adding Docker alongside npm)
- **`--validate`**: Validate without modifying
- **`--reset`**: Delete and start fresh (with confirmation)
- **`--show`**: Display current config in human-readable format

## Integration Points

This command creates the config file. Other t1660 subtasks consume it:

| Subtask | Consumes | Purpose |
|---------|----------|---------|
| t1660.2 | Schema definition | Validates testing.json structure |
| t1660.3 | `ready_check` config | browser-qa-helper.sh stability command |
| t1660.4 | Full config | verify-brief.sh runtime verification |
| t1660.5 | `testing_level` | task-complete-helper.sh --testing-level flag |
| t1660.6 | `testing_level` + results | PR template structured testing section |
| t1660.7 | Full config + `risk_patterns` | full-loop Step 3 runtime testing gate |

## Examples

```text
User: /testing-setup

AI: Detected project type: web-app (Next.js)
    Suggested runtime environment: npm

    Which runtime environment does this project use for development?
    1. npm — Node.js dev server (npm run dev / npm start) (recommended)
    2. docker — Docker Compose (docker compose up)
    ...

User: 1

AI: Dev server command?
    1. npm run dev (recommended — found in package.json)
    2. npm start
    ...

User: 1

AI: Dev server port?
    1. 3000 (recommended — Next.js default)
    ...

User: 1

AI: Ready signal?
    1. HTTP 200 on localhost:3000 (recommended)
    ...

User: 1

AI: Smoke URLs?
    1. Just the homepage: / (recommended)
    2. Homepage + API health: /, /api/health
    ...

User: 2

AI: Testing level for PRs?
    1. runtime-verified (recommended for web-app)
    ...

User: 1

AI: Risk escalation patterns?
    1. Default set: auth, payment, polling, state machine, WebSocket, cron (recommended)
    ...

User: 1

AI: Testing setup complete for my-nextjs-app

    Config: .aidevops/testing.json
      Environment: npm (npm run dev)
      Testing level: runtime-verified
      Smoke URLs: 2 configured (/, /api/health)
      Risk patterns: 6 active

    Next steps:
      1. Commit .aidevops/testing.json
      2. Run /testing-setup --validate to verify
```

```text
User: /testing-setup --non-interactive

AI: Auto-detected: web-app bundle → npm environment
    Dev server: npm run dev (from package.json)
    Port: 3000 (Next.js default)
    Testing level: runtime-verified

    Config written to .aidevops/testing.json
```

```text
User: /testing-setup --show

AI: Current testing config (.aidevops/testing.json):

    Project type: web-app
    Testing level: runtime-verified

    Environments:
      1. npm
         Start: npm run dev
         Ready: HTTP 200 on localhost:3000 (30s timeout)
         Smoke: / (200), /api/health (200)

    Risk patterns: 6 active
      - auth|login|session|jwt|oauth
      - payment|stripe|billing|checkout
      - poll|interval|setTimeout|setInterval|cron
      - state.*machine|fsm|transition|status.*change
      - websocket|socket.io|sse|realtime
      - migration|schema.*change|alter.*table
```

```text
User: /testing-setup --add

AI: Current environments: npm (npm run dev on :3000)

    Add another environment:
    1. docker — Docker Compose
    2. binary — Compiled binary
    ...

User: 1

AI: [Docker-specific questions...]

    Updated .aidevops/testing.json — now has 2 environments:
      1. npm (npm run dev on :3000)
      2. docker (docker compose up on :8080)
```

## Related

- `tools/build-agent/agent-testing.md` — Agent-level testing (different scope)
- `tools/browser/browser-qa.md` — Browser-based QA automation
- `workflows/plans.md` — Task planning integration
- `bundles/*.json` — Bundle definitions with quality gates
- `scripts/verify-brief.sh` — Runtime verification (t1660.4)
- `scripts/commands/full-loop.md` — Full development loop with testing gate (t1660.7)
