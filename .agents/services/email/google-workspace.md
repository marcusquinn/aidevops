---
description: Google Workspace CLI integration — Gmail, Calendar, Contacts via gws CLI
mode: subagent
tools:
  read: true
  write: false
  edit: false
  bash: true
  glob: false
  grep: true
  webfetch: false
  task: false
---

# Google Workspace — gws CLI Integration

<!-- AI-CONTEXT-START -->

## Quick Reference

- **CLI**: `gws` (`@googleworkspace/cli`, npm or Homebrew)
- **Install**: `npm install -g @googleworkspace/cli` or `brew install googleworkspace-cli`
- **Auth**: `gws auth setup` (interactive) | `GOOGLE_WORKSPACE_CLI_CREDENTIALS_FILE` (headless)
- **Config dir**: `~/.config/gws/`
- **Credentials**: `aidevops secret set GOOGLE_WORKSPACE_CLI_CREDENTIALS_FILE` (gopass) or `credentials.sh`
- **Skill import**: `npx skills add https://github.com/googleworkspace/cli/tree/main/skills/gws-gmail`

**Key commands:**

```bash
# Gmail
gws gmail +triage                          # unread inbox summary
gws gmail +send --to x@example.com --subject "Hello" --body "Hi"
gws gmail +reply --message-id MSG_ID --body "Thanks"
gws gmail +watch                           # stream new emails as NDJSON

# Calendar
gws calendar +agenda --today               # today's events
gws calendar +insert --summary "Standup" --start 2026-06-17T09:00:00Z --end 2026-06-17T09:30:00Z

# Contacts (People API)
gws people connections list --params '{"resourceName":"people/me","personFields":"names,emailAddresses"}'

# Introspect any method
gws schema gmail.users.messages.list
```

<!-- AI-CONTEXT-END -->

## Overview

`gws` is the official Google Workspace CLI (`googleworkspace/cli`, 20k+ stars). It reads Google's Discovery Service at runtime and builds its entire command surface dynamically — when Google adds an API endpoint, `gws` picks it up automatically. Every response is structured JSON, making it ideal for AI agent integration.

**Scope**: Gmail, Calendar, Drive, Sheets, Docs, Chat, Contacts (People API), and every other Workspace API.

---

## Installation

```bash
# npm (recommended — bundles pre-built native binaries, no Rust toolchain needed)
npm install -g @googleworkspace/cli

# Homebrew (macOS/Linux)
brew install googleworkspace-cli

# Pre-built binary — download from GitHub Releases
# https://github.com/googleworkspace/cli/releases

# Build from source (requires Rust)
cargo install --git https://github.com/googleworkspace/cli --locked
```

Verify:

```bash
gws --version
```

---

## Authentication

### Which method to use

| Situation | Method |
|-----------|--------|
| Local desktop with `gcloud` installed | `gws auth setup` (fastest) |
| Local desktop, no `gcloud` | Manual OAuth setup |
| CI / headless server | Export credentials file |
| Service account (server-to-server) | `GOOGLE_WORKSPACE_CLI_CREDENTIALS_FILE` |
| Another tool already mints tokens | `GOOGLE_WORKSPACE_CLI_TOKEN` |

### Interactive (local desktop)

```bash
gws auth setup    # one-time: creates GCP project, enables APIs, logs you in
gws auth login    # subsequent logins / scope changes
```

`gws auth setup` requires the `gcloud` CLI. Without it, use manual OAuth setup below.

> **Scope warning**: If your OAuth app is in testing mode (unverified), Google limits
> consent to ~25 scopes. The `recommended` preset includes 85+ scopes and will fail.
> Select individual services instead:
>
> ```bash
> gws auth login -s gmail,calendar,contacts
> ```

### Manual OAuth setup (no gcloud)

1. Open [Google Cloud Console](https://console.cloud.google.com/) in your target project
2. OAuth consent screen → App type: **External**, add yourself as a **Test user**
3. Credentials → Create OAuth client → Type: **Desktop app**
4. Download the client JSON → save to `~/.config/gws/client_secret.json`
5. Run `gws auth login`

### Headless / CI (export flow)

Complete interactive auth on a machine with a browser, then export:

```bash
# On the machine with a browser
gws auth export --unmasked > credentials.json

# Store securely — never commit this file
aidevops secret set GOOGLE_WORKSPACE_CLI_CREDENTIALS_FILE
# Enter the file path at the prompt, e.g. /path/to/credentials.json
```

On the headless machine:

```bash
export GOOGLE_WORKSPACE_CLI_CREDENTIALS_FILE=/path/to/credentials.json
gws gmail +triage   # just works
```

### Service account (server-to-server)

```bash
export GOOGLE_WORKSPACE_CLI_CREDENTIALS_FILE=/path/to/service-account.json
gws drive files list
```

### Auth precedence

| Priority | Source | Variable |
|----------|--------|----------|
| 1 | Access token | `GOOGLE_WORKSPACE_CLI_TOKEN` |
| 2 | Credentials file | `GOOGLE_WORKSPACE_CLI_CREDENTIALS_FILE` |
| 3 | Encrypted credentials | `gws auth login` |
| 4 | Plaintext credentials | `~/.config/gws/credentials.json` |

Variables can also be set in a `.env` file in the working directory.

---

## Gmail

### Triage (read unread inbox)

```bash
# Default: show 20 most recent unread messages
gws gmail +triage

# Limit and filter
gws gmail +triage --max 5 --query 'from:boss@example.com'

# Include label names
gws gmail +triage --labels

# JSON output for piping
gws gmail +triage --format json | jq '.[].subject'
```

`+triage` is read-only — it never modifies the mailbox.

### Send

```bash
gws gmail +send \
  --to alice@example.com \
  --subject "Hello" \
  --body "Hi Alice!"

# With CC/BCC
gws gmail +send \
  --to alice@example.com \
  --subject "Hello" \
  --body "Hi!" \
  --cc bob@example.com \
  --bcc archive@example.com

# HTML body
gws gmail +send \
  --to alice@example.com \
  --subject "Report" \
  --body "<b>See attached.</b>" \
  --html

# Preview without sending
gws gmail +send --to alice@example.com --subject "Test" --body "Hi" --dry-run
```

> **Write command** — confirm with the user before executing.

### Reply / Reply-all / Forward

```bash
# Reply (handles threading automatically)
gws gmail +reply --message-id MESSAGE_ID --body "Thanks!"

# Reply-all
gws gmail +reply-all --message-id MESSAGE_ID --body "Noted, thanks."

# Forward
gws gmail +forward --message-id MESSAGE_ID --to newrecipient@example.com
```

Get `MESSAGE_ID` from `+triage --format json | jq '.[0].id'`.

### Watch (stream new emails)

```bash
# Stream new emails as NDJSON — runs until interrupted
gws gmail +watch

# Pipe to a processor
gws gmail +watch | jq -r '"\(.from): \(.subject)"'
```

### Label management

Labels are Gmail's folder equivalent. Use the raw API for label operations:

```bash
# List all labels
gws gmail users labels list --params '{"userId":"me"}' | jq '.labels[] | {id,name}'

# Create a label
gws gmail users labels create \
  --params '{"userId":"me"}' \
  --json '{"name":"aidevops/processed","labelListVisibility":"labelShow","messageListVisibility":"show"}'

# Apply a label to a message
gws gmail users messages modify \
  --params '{"userId":"me","id":"MESSAGE_ID"}' \
  --json '{"addLabelIds":["LABEL_ID"]}'

# Archive (remove INBOX label)
gws gmail users messages modify \
  --params '{"userId":"me","id":"MESSAGE_ID"}' \
  --json '{"removeLabelIds":["INBOX"]}'
```

### Search messages (raw API)

```bash
# Search with Gmail query syntax
gws gmail users messages list \
  --params '{"userId":"me","q":"from:vendor@example.com subject:invoice","maxResults":10}' \
  | jq '.messages[].id'

# Get full message
gws gmail users messages get \
  --params '{"userId":"me","id":"MESSAGE_ID","format":"full"}' \
  | jq '.payload.headers[] | select(.name=="Subject") | .value'
```

---

## Calendar

### Agenda (view upcoming events)

```bash
# Default: next 7 days across all calendars
gws calendar +agenda

# Today only
gws calendar +agenda --today

# This week, table format
gws calendar +agenda --week --format table

# Next N days, filtered to one calendar
gws calendar +agenda --days 3 --calendar 'Work'

# Specific timezone override
gws calendar +agenda --today --timezone America/New_York
```

`+agenda` is read-only. Uses your Google account timezone by default.

### Create event

```bash
# Basic event (ISO 8601 / RFC3339 times)
gws calendar +insert \
  --summary "Standup" \
  --start "2026-06-17T09:00:00-07:00" \
  --end "2026-06-17T09:30:00-07:00"

# With location, description, and attendees
gws calendar +insert \
  --summary "Quarterly Review" \
  --start "2026-06-20T14:00:00Z" \
  --end "2026-06-20T15:00:00Z" \
  --location "Conference Room A" \
  --description "Q2 review meeting" \
  --attendee alice@example.com \
  --attendee bob@example.com

# Specific calendar (not primary)
gws calendar +insert \
  --calendar "team-calendar@group.calendar.google.com" \
  --summary "Sprint Planning" \
  --start "2026-06-18T10:00:00Z" \
  --end "2026-06-18T11:00:00Z"
```

> **Write command** — confirm with the user before executing.

### List / search events (raw API)

```bash
# Events in a time range
gws calendar events list \
  --params '{"calendarId":"primary","timeMin":"2026-06-01T00:00:00Z","timeMax":"2026-06-30T23:59:59Z","singleEvents":true,"orderBy":"startTime"}' \
  | jq '.items[] | {summary, start}'

# Free/busy query
gws calendar freebusy query \
  --json '{"timeMin":"2026-06-17T09:00:00Z","timeMax":"2026-06-17T17:00:00Z","items":[{"id":"primary"}]}'
```

### Workflow helpers

```bash
# Morning standup: today's meetings + open tasks
gws workflow +standup-report

# Prepare for next meeting: agenda, attendees, linked docs
gws workflow +meeting-prep

# Weekly digest: this week's meetings + unread email count
gws workflow +weekly-digest
```

---

## Contacts (People API)

`gws` exposes the People API under `gws people`. There are no `+helper` commands for contacts — use the raw Discovery surface.

```bash
# List connections (contacts) with names and email addresses
gws people connections list \
  --params '{"resourceName":"people/me","personFields":"names,emailAddresses","pageSize":100}' \
  | jq '.connections[] | {name: .names[0].displayName, email: .emailAddresses[0].value}'

# Search contacts
gws people searchContacts \
  --params '{"query":"alice","readMask":"names,emailAddresses"}' \
  | jq '.results[].person | {name: .names[0].displayName, email: .emailAddresses[0].value}'

# Get a specific contact
gws people people get \
  --params '{"resourceName":"people/PERSON_ID","personFields":"names,emailAddresses,phoneNumbers,organizations"}' \
  | jq '{name: .names[0].displayName, email: .emailAddresses[0].value}'

# Create a contact
gws people people createContact \
  --json '{"names":[{"givenName":"Alice","familyName":"Smith"}],"emailAddresses":[{"value":"alice@example.com"}]}'

# Update a contact
gws people people updateContact \
  --params '{"resourceName":"people/PERSON_ID","updatePersonFields":"emailAddresses"}' \
  --json '{"emailAddresses":[{"value":"newemail@example.com"}]}'
```

> **Write commands** (create/update) — confirm with the user before executing.

### Sync pattern (export contacts to local JSON)

```bash
# Dump all contacts to a local file for offline use
gws people connections list \
  --params '{"resourceName":"people/me","personFields":"names,emailAddresses,phoneNumbers","pageSize":1000}' \
  --page-all \
  > ~/.aidevops/.agent-workspace/work/contacts/google-contacts.ndjson

# Extract email→name mapping
jq -r '.connections[] | "\(.emailAddresses[0].value)\t\(.names[0].displayName)"' \
  ~/.aidevops/.agent-workspace/work/contacts/google-contacts.ndjson
```

---

## Environment Variables

All environment variables are optional and can be set in a `.env` file.

| Variable | Description |
|----------|-------------|
| `GOOGLE_WORKSPACE_CLI_TOKEN` | Pre-obtained OAuth2 access token (highest priority) |
| `GOOGLE_WORKSPACE_CLI_CREDENTIALS_FILE` | Path to OAuth credentials JSON (user or service account) |
| `GOOGLE_WORKSPACE_CLI_CLIENT_ID` | OAuth client ID (alternative to `client_secret.json`) |
| `GOOGLE_WORKSPACE_CLI_CLIENT_SECRET` | OAuth client secret (paired with `CLIENT_ID`) |
| `GOOGLE_WORKSPACE_CLI_CONFIG_DIR` | Override config directory (default: `~/.config/gws`) |
| `GOOGLE_WORKSPACE_CLI_SANITIZE_TEMPLATE` | Default Model Armor template for response sanitization |
| `GOOGLE_WORKSPACE_CLI_SANITIZE_MODE` | `warn` (default) or `block` |
| `GOOGLE_WORKSPACE_CLI_LOG` | Log level for stderr (e.g., `gws=debug`) |
| `GOOGLE_WORKSPACE_CLI_LOG_FILE` | Directory for JSON log files with daily rotation |
| `GOOGLE_WORKSPACE_PROJECT_ID` | GCP project ID override for quota/billing |

---

## Exit Codes

| Code | Meaning | Example cause |
|------|---------|---------------|
| `0` | Success | Command completed normally |
| `1` | API error | Google returned 4xx/5xx |
| `2` | Auth error | Credentials missing, expired, or invalid |
| `3` | Validation error | Bad arguments, unknown service, invalid flag |
| `4` | Discovery error | Could not fetch API schema |
| `5` | Internal error | Unexpected failure |

```bash
gws gmail +triage || echo "exit $?"
```

---

## Discovering Commands

`gws` builds its command surface dynamically from Google's Discovery Service. Use `--help` and `gws schema` to explore:

```bash
# List all services
gws --help

# List all resources and methods for a service
gws gmail --help
gws calendar --help
gws people --help

# Inspect a method's required params, types, and defaults
gws schema gmail.users.messages.list
gws schema calendar.events.insert
gws schema people.people.createContact
```

---

## Skill Import (OpenClaw / aidevops skills)

`gws` ships 100+ agent skills (`SKILL.md` files) — one per API plus higher-level helpers.

```bash
# Install all skills at once
npx skills add https://github.com/googleworkspace/cli

# Install only Gmail and Calendar skills
npx skills add https://github.com/googleworkspace/cli/tree/main/skills/gws-gmail
npx skills add https://github.com/googleworkspace/cli/tree/main/skills/gws-calendar

# OpenClaw: symlink all skills (stays in sync with repo)
ln -s "$(pwd)/skills/gws-"* ~/.openclaw/skills/
```

**Evaluation verdict**: The `gws` helper commands (`+triage`, `+send`, `+reply`, `+watch`, `+agenda`, `+insert`) are production-ready and directly useful for AI agent integration. The raw Discovery surface covers every Workspace API. Recommend importing `gws-gmail` and `gws-calendar` skills as the primary integration path. Contacts use the raw People API (no helper commands) — adequate for sync patterns but more verbose.

---

## Security Notes

- **Never commit** `~/.config/gws/credentials.json` or exported credentials files
- Store credentials via `aidevops secret set GOOGLE_WORKSPACE_CLI_CREDENTIALS_FILE`
- For headless/CI: use the export flow — credentials are AES-256-GCM encrypted at rest on the source machine
- **Write commands** (`+send`, `+reply`, `+forward`, `+insert`, `createContact`, `updateContact`) modify live data — always confirm with the user before executing
- **Model Armor**: use `--sanitize` flag or `GOOGLE_WORKSPACE_CLI_SANITIZE_TEMPLATE` to scan API responses for prompt injection before they reach the agent

```bash
# Sanitize Gmail response through Model Armor
gws gmail users messages get \
  --params '{"userId":"me","id":"MESSAGE_ID","format":"full"}' \
  --sanitize "projects/PROJECT/locations/LOCATION/templates/TEMPLATE"
```

---

## See Also

- `services/email/email-agent.md` — autonomous email agent (AWS SES-based)
- `services/email/ses.md` — Amazon SES provider guide
- `services/communications/google-chat.md` — Google Chat via `gws chat`
- [gws GitHub](https://github.com/googleworkspace/cli) — source, releases, full skills index
- [gws Skills Index](https://github.com/googleworkspace/cli/blob/main/docs/skills.md) — 100+ agent skills
