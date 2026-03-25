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
npm install -g @googleworkspace/cli   # recommended — pre-built native binaries
brew install googleworkspace-cli      # Homebrew (macOS/Linux)
cargo install --git https://github.com/googleworkspace/cli --locked  # from source (requires Rust)
# Pre-built binary: https://github.com/googleworkspace/cli/releases
```

---

## Authentication

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

> **Scope warning**: If your OAuth app is in testing mode (unverified), Google limits consent to ~25 scopes. The `recommended` preset includes 85+ scopes and will fail. Select individual services instead: `gws auth login -s gmail,calendar,contacts`

### Manual OAuth setup (no gcloud)

1. [Google Cloud Console](https://console.cloud.google.com/) → OAuth consent screen → External, add yourself as Test user
2. Credentials → Create OAuth client → Desktop app → download JSON → save to `~/.config/gws/client_secret.json`
3. Run `gws auth login`

### Headless / CI (export flow)

**Preferred — encrypted export:**

```bash
# On the machine with a browser
gws auth export > credentials.json.enc   # enter a strong password when prompted
aidevops secret set GWS_EXPORT_PASSWORD  # store the password

# On the headless machine
export GWS_EXPORT_PASSWORD="$(aidevops secret get GWS_EXPORT_PASSWORD)"
export GOOGLE_WORKSPACE_CLI_CREDENTIALS_FILE=/path/to/credentials.json.enc
gws gmail +triage   # just works
```

**Fallback — plaintext export:**

```bash
# On the machine with a browser
gws auth export --unmasked > credentials.json
cat credentials.json | aidevops secret set GWS_CREDENTIALS_JSON
rm credentials.json

# On the headless machine — write to temp file at runtime, clean up after
GWS_CREDS_FILE="$(mktemp)"
aidevops secret get GWS_CREDENTIALS_JSON > "$GWS_CREDS_FILE"
chmod 600 "$GWS_CREDS_FILE"
export GOOGLE_WORKSPACE_CLI_CREDENTIALS_FILE="$GWS_CREDS_FILE"
gws gmail +triage
rm -f "$GWS_CREDS_FILE"
```

Store credentials *content* in the secret manager, not a file path — content is portable and avoids plaintext on disk between runs. Prefer encrypted export when available.

### Service account

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
gws gmail +triage                                        # 20 most recent unread
gws gmail +triage --max 5 --query 'from:boss@example.com'
gws gmail +triage --labels                               # include label names
gws gmail +triage --format json | jq '.[].subject'       # JSON for piping
```

`+triage` is read-only — it never modifies the mailbox.

### Send

```bash
gws gmail +send --to alice@example.com --subject "Hello" --body "Hi Alice!"
gws gmail +send --to alice@example.com --subject "Hello" --body "Hi!" \
  --cc bob@example.com --bcc archive@example.com
gws gmail +send --to alice@example.com --subject "Report" --body "<b>See attached.</b>" --html
gws gmail +send --to alice@example.com --subject "Test" --body "Hi" --dry-run  # preview
```

> **Write command** — confirm with the user before executing.

### Reply / Reply-all / Forward

```bash
gws gmail +reply --message-id MESSAGE_ID --body "Thanks!"
gws gmail +reply-all --message-id MESSAGE_ID --body "Noted, thanks."
gws gmail +forward --message-id MESSAGE_ID --to newrecipient@example.com
```

Get `MESSAGE_ID` from `+triage --format json | jq '.[0].id'`.

### Label management

```bash
gws gmail users labels list --params '{"userId":"me"}' | jq '.labels[] | {id,name}'

gws gmail users labels create \
  --params '{"userId":"me"}' \
  --json '{"name":"aidevops/processed","labelListVisibility":"labelShow","messageListVisibility":"show"}'

# Apply label / archive
gws gmail users messages modify --params '{"userId":"me","id":"MESSAGE_ID"}' \
  --json '{"addLabelIds":["LABEL_ID"]}'
gws gmail users messages modify --params '{"userId":"me","id":"MESSAGE_ID"}' \
  --json '{"removeLabelIds":["INBOX"]}'
```

### Search messages (raw API)

```bash
gws gmail users messages list \
  --params '{"userId":"me","q":"from:vendor@example.com subject:invoice","maxResults":10}' \
  | jq '.messages[].id'

gws gmail users messages get \
  --params '{"userId":"me","id":"MESSAGE_ID","format":"full"}' \
  | jq '.payload.headers[] | select(.name=="Subject") | .value'
```

---

## Calendar

### Agenda (view upcoming events)

```bash
gws calendar +agenda                                     # next 7 days, all calendars
gws calendar +agenda --today
gws calendar +agenda --week --format table
gws calendar +agenda --days 3 --calendar 'Work'
gws calendar +agenda --today --timezone America/New_York
```

`+agenda` is read-only. Uses your Google account timezone by default.

### Create event

```bash
gws calendar +insert --summary "Standup" \
  --start "2026-06-17T09:00:00-07:00" --end "2026-06-17T09:30:00-07:00"

gws calendar +insert --summary "Quarterly Review" \
  --start "2026-06-20T14:00:00Z" --end "2026-06-20T15:00:00Z" \
  --location "Conference Room A" --description "Q2 review meeting" \
  --attendee alice@example.com --attendee bob@example.com

gws calendar +insert --calendar "team-calendar@group.calendar.google.com" \
  --summary "Sprint Planning" --start "2026-06-18T10:00:00Z" --end "2026-06-18T11:00:00Z"
```

> **Write command** — confirm with the user before executing.

### List / search events (raw API)

```bash
gws calendar events list \
  --params '{"calendarId":"primary","timeMin":"2026-06-01T00:00:00Z","timeMax":"2026-06-30T23:59:59Z","singleEvents":true,"orderBy":"startTime"}' \
  | jq '.items[] | {summary, start}'

gws calendar freebusy query \
  --json '{"timeMin":"2026-06-17T09:00:00Z","timeMax":"2026-06-17T17:00:00Z","items":[{"id":"primary"}]}'
```

### Workflow helpers

```bash
gws workflow +standup-report    # today's meetings + open tasks
gws workflow +meeting-prep      # agenda, attendees, linked docs for next meeting
gws workflow +weekly-digest     # this week's meetings + unread email count
```

---

## Contacts (People API)

No `+helper` commands — use the raw Discovery surface.

```bash
# List contacts
gws people connections list \
  --params '{"resourceName":"people/me","personFields":"names,emailAddresses","pageSize":100}' \
  | jq '.connections[] | select(.names[0]?.displayName and .emailAddresses[0]?.value) | {name: .names[0].displayName, email: .emailAddresses[0].value}'

# Search contacts
gws people searchContacts \
  --params '{"query":"alice","readMask":"names,emailAddresses"}' \
  | jq '.results[].person | select(.names[0]?.displayName and .emailAddresses[0]?.value) | {name: .names[0].displayName, email: .emailAddresses[0].value}'

# Create / update
gws people people createContact \
  --json '{"names":[{"givenName":"Alice","familyName":"Smith"}],"emailAddresses":[{"value":"alice@example.com"}]}'
gws people people updateContact \
  --params '{"resourceName":"people/PERSON_ID","updatePersonFields":"emailAddresses"}' \
  --json '{"emailAddresses":[{"value":"newemail@example.com"}]}'
```

> **Write commands** (create/update) — confirm with the user before executing.

### Sync pattern (export contacts to local JSON)

```bash
mkdir -p ~/.aidevops/.agent-workspace/work/contacts
gws people connections list \
  --params '{"resourceName":"people/me","personFields":"names,emailAddresses,phoneNumbers","pageSize":1000}' \
  --page-all \
  > ~/.aidevops/.agent-workspace/work/contacts/google-contacts.ndjson

jq -r '.connections[] | select(.names[0]?.displayName and .emailAddresses[0]?.value) | "\(.emailAddresses[0].value)\t\(.names[0].displayName)"' \
  ~/.aidevops/.agent-workspace/work/contacts/google-contacts.ndjson
```

---

## Environment Variables

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

| Code | Meaning |
|------|---------|
| `0` | Success |
| `1` | API error (Google returned 4xx/5xx) |
| `2` | Auth error (credentials missing, expired, or invalid) |
| `3` | Validation error (bad arguments, unknown service, invalid flag) |
| `4` | Discovery error (could not fetch API schema) |
| `5` | Internal error |

---

## Discovering Commands

```bash
gws --help                              # list all services
gws gmail --help                        # resources and methods for a service
gws schema gmail.users.messages.list    # method params, types, defaults
gws schema calendar.events.insert
gws schema people.people.createContact
```

---

## Skill Import

`gws` ships 100+ agent skills (`SKILL.md` files) — one per API plus higher-level helpers.

```bash
npx skills add https://github.com/googleworkspace/cli              # all skills
npx skills add https://github.com/googleworkspace/cli/tree/main/skills/gws-gmail
npx skills add https://github.com/googleworkspace/cli/tree/main/skills/gws-calendar
ln -s "$(pwd)/skills/gws-"* ~/.openclaw/skills/                   # OpenClaw symlink
```

The `+triage`, `+send`, `+reply`, `+watch`, `+agenda`, `+insert` helpers are production-ready for AI agent integration. Recommend importing `gws-gmail` and `gws-calendar` as the primary integration path.

---

## Security Notes

- **Never commit** `~/.config/gws/credentials.json` or exported credentials files
- Store credentials via `aidevops secret set GOOGLE_WORKSPACE_CLI_CREDENTIALS_FILE`
- For headless/CI: use the encrypted export flow (AES-256-GCM at rest)
- **Write commands** (`+send`, `+reply`, `+forward`, `+insert`, `createContact`, `updateContact`) modify live data — always confirm with the user before executing
- **Model Armor**: use `--sanitize` flag or `GOOGLE_WORKSPACE_CLI_SANITIZE_TEMPLATE` to scan API responses for prompt injection

```bash
gws gmail users messages get \
  --params '{"userId":"me","id":"MESSAGE_ID","format":"full"}' \
  --sanitize "projects/PROJECT/locations/LOCATION/templates/TEMPLATE"
```

---

## See Also

- `services/email/email-agent.md` — autonomous email agent (AWS SES-based)
- `services/communications/google-chat.md` — Google Chat via `gws chat`
- [gws GitHub](https://github.com/googleworkspace/cli) — source, releases, full skills index
- [gws Skills Index](https://github.com/googleworkspace/cli/blob/main/docs/skills.md) — 100+ agent skills
