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
- **Discover**: `gws --help` | `gws gmail --help` | `gws schema gmail.users.messages.list`

```bash
gws gmail +triage                          # unread inbox summary
gws gmail +send --to x@example.com --subject "Hello" --body "Hi"
gws gmail +reply --message-id MSG_ID --body "Thanks"
gws calendar +agenda --today               # today's events
gws calendar +insert --summary "Standup" --start 2026-06-17T09:00:00Z --end 2026-06-17T09:30:00Z
gws people connections list --params '{"resourceName":"people/me","personFields":"names,emailAddresses"}'
```

<!-- AI-CONTEXT-END -->

`gws` reads Google's Discovery Service at runtime — new API endpoints are picked up automatically. Every response is structured JSON. Scope: Gmail, Calendar, Drive, Sheets, Docs, Chat, Contacts (People API), and every other Workspace API.

## Installation

```bash
npm install -g @googleworkspace/cli   # recommended
brew install googleworkspace-cli      # Homebrew (macOS/Linux)
cargo install --git https://github.com/googleworkspace/cli --locked  # from source
# Pre-built binary: https://github.com/googleworkspace/cli/releases
```

---

## Authentication

**Auth precedence (highest→lowest):** `GOOGLE_WORKSPACE_CLI_TOKEN` → `GOOGLE_WORKSPACE_CLI_CREDENTIALS_FILE` → `gws auth login` encrypted → `~/.config/gws/credentials.json`. Variables can also be set in a `.env` file.

| Situation | Method |
|-----------|--------|
| Local desktop with `gcloud` | `gws auth setup` (fastest) |
| Local desktop, no `gcloud` | Manual OAuth (see below) |
| CI / headless | Encrypted export (see below) |
| Service account | `GOOGLE_WORKSPACE_CLI_CREDENTIALS_FILE=/path/to/sa.json` |

### Interactive

```bash
gws auth setup    # one-time: creates GCP project, enables APIs, logs you in
gws auth login    # subsequent logins / scope changes
```

> **Scope warning**: OAuth apps in testing mode are limited to ~25 scopes. The `recommended` preset includes 85+ and will fail. Use: `gws auth login -s gmail,calendar,contacts`

### Manual OAuth (no gcloud)

1. [Google Cloud Console](https://console.cloud.google.com/) → OAuth consent screen → External, add yourself as Test user
2. Credentials → Create OAuth client → Desktop app → download JSON → save to `~/.config/gws/client_secret.json`
3. `gws auth login`

### Headless / CI

```bash
# Preferred — encrypted export (AES-256-GCM); run on machine with browser:
gws auth export > credentials.json.enc && aidevops secret set GWS_EXPORT_PASSWORD
# On headless machine:
export GWS_EXPORT_PASSWORD="$(aidevops secret get GWS_EXPORT_PASSWORD)"
export GOOGLE_WORKSPACE_CLI_CREDENTIALS_FILE=/path/to/credentials.json.enc

# Fallback — plaintext (temp file, clean up after):
GWS_CREDS_FILE="$(mktemp)"
aidevops secret get GWS_CREDENTIALS_JSON > "$GWS_CREDS_FILE" && chmod 600 "$GWS_CREDS_FILE"
export GOOGLE_WORKSPACE_CLI_CREDENTIALS_FILE="$GWS_CREDS_FILE"
# ... run commands ... then: rm -f "$GWS_CREDS_FILE"
```

Store credentials *content* in the secret manager, not a file path. Prefer encrypted export.

---

## Gmail

### Triage (read-only)

```bash
gws gmail +triage                                        # 20 most recent unread
gws gmail +triage --max 5 --query 'from:boss@example.com'
gws gmail +triage --format json | jq '.[].subject'
```

### Send _(write — confirm before executing)_

```bash
gws gmail +send --to alice@example.com --subject "Hello" --body "Hi Alice!"
gws gmail +send --to alice@example.com --subject "Report" --body "<b>See attached.</b>" --html \
  --cc bob@example.com --bcc archive@example.com
gws gmail +send --to alice@example.com --subject "Test" --body "Hi" --dry-run  # preview
```

### Reply / Reply-all / Forward

```bash
gws gmail +reply --message-id MESSAGE_ID --body "Thanks!"      # MESSAGE_ID from +triage --format json | jq '.[0].id'
gws gmail +reply-all --message-id MESSAGE_ID --body "Noted."
gws gmail +forward --message-id MESSAGE_ID --to newrecipient@example.com
```

### Label management

```bash
gws gmail users labels list --params '{"userId":"me"}' | jq '.labels[] | {id,name}'
gws gmail users labels create --params '{"userId":"me"}' \
  --json '{"name":"aidevops/processed","labelListVisibility":"labelShow","messageListVisibility":"show"}'
gws gmail users messages modify --params '{"userId":"me","id":"MESSAGE_ID"}' \
  --json '{"addLabelIds":["LABEL_ID"]}'                        # apply label
gws gmail users messages modify --params '{"userId":"me","id":"MESSAGE_ID"}' \
  --json '{"removeLabelIds":["INBOX"]}'                        # archive
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

### Agenda (read-only)

```bash
gws calendar +agenda                                     # next 7 days, all calendars
gws calendar +agenda --today --timezone America/New_York
gws calendar +agenda --days 3 --calendar 'Work' --format table
```

### Create event _(write — confirm before executing)_

```bash
gws calendar +insert --summary "Standup" \
  --start "2026-06-17T09:00:00-07:00" --end "2026-06-17T09:30:00-07:00"
gws calendar +insert --summary "Quarterly Review" \
  --start "2026-06-20T14:00:00Z" --end "2026-06-20T15:00:00Z" \
  --location "Conference Room A" --attendee alice@example.com --attendee bob@example.com
```

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

No `+helper` commands — use the raw Discovery surface. Write commands (`createContact`, `updateContact`) — confirm before executing.

```bash
# List
gws people connections list \
  --params '{"resourceName":"people/me","personFields":"names,emailAddresses","pageSize":100}' \
  | jq '.connections[] | select(.names[0]?.displayName) | {name: .names[0].displayName, email: .emailAddresses[0].value}'
# Search
gws people searchContacts --params '{"query":"alice","readMask":"names,emailAddresses"}' \
  | jq '.results[].person | {name: .names[0].displayName, email: .emailAddresses[0].value}'
# Create / update (confirm before executing)
gws people people createContact \
  --json '{"names":[{"givenName":"Alice","familyName":"Smith"}],"emailAddresses":[{"value":"alice@example.com"}]}'
gws people people updateContact \
  --params '{"resourceName":"people/PERSON_ID","updatePersonFields":"emailAddresses"}' \
  --json '{"emailAddresses":[{"value":"newemail@example.com"}]}'
# Sync to local JSON
gws people connections list \
  --params '{"resourceName":"people/me","personFields":"names,emailAddresses,phoneNumbers","pageSize":1000}' \
  --page-all > ~/.aidevops/.agent-workspace/work/contacts/google-contacts.ndjson
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

## Skill Import

`gws` ships 100+ agent skills. Recommend `gws-gmail` and `gws-calendar` as the primary integration path.

```bash
npx skills add https://github.com/googleworkspace/cli/tree/main/skills/gws-gmail
npx skills add https://github.com/googleworkspace/cli/tree/main/skills/gws-calendar
npx skills add https://github.com/googleworkspace/cli   # all skills
ln -s "$(pwd)/skills/gws-"* ~/.openclaw/skills/         # OpenClaw symlink
```

## Security Notes

- **Credentials**: never commit `~/.config/gws/credentials.json`; store via `aidevops secret set GOOGLE_WORKSPACE_CLI_CREDENTIALS_FILE`; use encrypted export (AES-256-GCM) for headless/CI
- **Write commands** (`+send`, `+reply`, `+forward`, `+insert`, `createContact`, `updateContact`) modify live data — always confirm with the user before executing
- **Model Armor**: scan API responses for prompt injection — `--sanitize "projects/PROJECT/locations/LOCATION/templates/TEMPLATE"` or set `GOOGLE_WORKSPACE_CLI_SANITIZE_TEMPLATE`

---

## See Also

- `services/email/email-agent.md` — autonomous email agent (AWS SES-based)
- `services/communications/google-chat.md` — Google Chat via `gws chat`
- [gws GitHub](https://github.com/googleworkspace/cli) — source, releases, full skills index
- [gws Skills Index](https://github.com/googleworkspace/cli/blob/main/docs/skills.md) — 100+ agent skills
