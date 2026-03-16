---
description: Microsoft Graph API adapter for Outlook/365 shared mailboxes — OAuth2 flows, shared mailbox delegation, mail operations
mode: subagent
tools:
  read: true
  write: false
  edit: false
  bash: true
  glob: true
  grep: true
  webfetch: false
  task: true
---

# Microsoft Graph API Adapter — Outlook/365 Shared Mailboxes

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Helper**: `scripts/microsoft-graph-helper.sh`
- **Config template**: `configs/microsoft-graph-config.json.txt`
- **Working config**: `configs/microsoft-graph-config.json` (gitignored)
- **Token cache**: `~/.aidevops/.agent-workspace/microsoft-graph/token-cache.json` (0600)
- **Auth flows**: Device flow (delegated, interactive) | Client credentials (app-only, headless)
- **API**: Microsoft Graph v1.0 — `https://graph.microsoft.com/v1.0`

**When to use Graph API vs IMAP**: Graph API is preferred for Outlook/365 when you need shared mailbox delegation, richer permissions management, or programmatic access without IMAP credentials. IMAP is simpler for basic read/send but lacks delegation APIs.

<!-- AI-CONTEXT-END -->

## Setup

### 1. Register Azure AD App

```bash
# Open Azure Portal
open https://portal.azure.com/#view/Microsoft_AAD_RegisteredApps/ApplicationsListBlade
```

Steps:

1. **New registration** — Name: `aidevops-graph-adapter`, Account type: `Single tenant`
2. **API permissions** → Add a permission → Microsoft Graph → Delegated:
   - `Mail.ReadWrite`
   - `Mail.Send`
   - `Mail.ReadWrite.Shared`
   - `Mail.Send.Shared`
   - `MailboxSettings.ReadWrite`
   - `offline_access`
3. For app-only flow: add **Application** permissions instead, then **Grant admin consent**
4. **Certificates & secrets** → New client secret (app-only only)
5. Note the **Application (client) ID** and **Directory (tenant) ID** from Overview

### 2. Configure

```bash
# Copy config template
cp .agents/configs/microsoft-graph-config.json.txt .agents/configs/microsoft-graph-config.json

# Edit: set tenant_id, client_id, shared_mailboxes
# Do NOT put credentials in the config file
```

### 3. Store Credentials

```bash
# WARNING: Never paste secret values into AI chat. Run these in your terminal.
aidevops secret set MSGRAPH_CLIENT_ID
aidevops secret set MSGRAPH_TENANT_ID
aidevops secret set MSGRAPH_CLIENT_SECRET  # app-only flow only
```

### 4. Authenticate

```bash
# Interactive device flow (delegated — opens browser)
microsoft-graph-helper.sh auth

# App-only (headless, no user interaction)
microsoft-graph-helper.sh auth --client-credentials
```

## Authentication Flows

### Device Flow (Delegated)

Best for: interactive sessions, personal mailboxes, shared mailboxes where the user has been granted access.

```text
1. Script requests a device code from Azure AD
2. User opens the verification URL and enters the code
3. User signs in with their Microsoft 365 account
4. Script polls for the token and caches it
5. Refresh token enables silent re-authentication
```

Scopes granted: `Mail.ReadWrite Mail.Send Mail.ReadWrite.Shared Mail.Send.Shared MailboxSettings.ReadWrite offline_access`

### Client Credentials (App-Only)

Best for: headless automation, CI/CD, accessing shared mailboxes without a user context.

```text
1. App authenticates directly with client_id + client_secret
2. No user interaction required
3. No refresh token — app re-authenticates on expiry
4. Requires admin consent for application permissions
```

Scope: `https://graph.microsoft.com/.default` (all granted application permissions)

**Limitation**: Application permissions cannot access personal mailboxes. They can access shared mailboxes and any mailbox in the tenant with admin consent.

### Token Lifecycle

```bash
# Check token status (expiry, scopes — never shows values)
microsoft-graph-helper.sh token-status

# Force refresh (uses refresh token if available)
microsoft-graph-helper.sh token-refresh
```

Tokens are cached at `~/.aidevops/.agent-workspace/microsoft-graph/token-cache.json` with 0600 permissions. The cache stores the access token, refresh token, expiry time, and scopes — never printed to output.

## Shared Mailbox Operations

### Accessing a Shared Mailbox

The authenticated user must have been granted access to the shared mailbox via Exchange Admin Center or PowerShell before Graph API calls will succeed.

```bash
# List messages in shared mailbox
microsoft-graph-helper.sh list-messages --mailbox support@company.com

# With filters
microsoft-graph-helper.sh list-messages \
  --mailbox support@company.com \
  --folder Inbox \
  --limit 50 \
  --since 2026-03-01T00:00:00Z

# Get a specific message
microsoft-graph-helper.sh get-message \
  --mailbox support@company.com \
  --id <message-id>
```

### Sending from a Shared Mailbox

Requires `Mail.Send.Shared` permission and `SendAs` or `SendOnBehalf` delegation.

```bash
# Send as the shared mailbox
microsoft-graph-helper.sh send \
  --mailbox support@company.com \
  --to customer@example.com \
  --subject "Re: Your support request" \
  --body "Hello, thank you for contacting us..."

# Send HTML email
microsoft-graph-helper.sh send \
  --mailbox support@company.com \
  --to customer@example.com \
  --subject "Welcome" \
  --body "<h1>Welcome!</h1><p>Thank you for joining.</p>" \
  --html

# Reply to a message
microsoft-graph-helper.sh reply \
  --mailbox support@company.com \
  --id <message-id> \
  --body "Thank you for your message..."
```

### Organising Messages

```bash
# Move to a folder
microsoft-graph-helper.sh move \
  --mailbox support@company.com \
  --id <message-id> \
  --folder Archive

# Mark as read/unread
microsoft-graph-helper.sh flag --mailbox support@company.com --id <id> --flag read
microsoft-graph-helper.sh flag --mailbox support@company.com --id <id> --flag unread

# Flag for follow-up
microsoft-graph-helper.sh flag --mailbox support@company.com --id <id> --flag flagged

# Delete
microsoft-graph-helper.sh delete --mailbox support@company.com --id <message-id>
```

### Folder Management

```bash
# List folders with message counts
microsoft-graph-helper.sh list-folders --mailbox support@company.com

# Create a folder
microsoft-graph-helper.sh create-folder \
  --mailbox support@company.com \
  --name "Resolved"
```

## Delegation Management

### Granting Access (PowerShell)

Graph API does not expose mailbox permission management directly — use Exchange Online PowerShell or the Microsoft 365 Admin Center.

```bash
# Show PowerShell commands for granting access
microsoft-graph-helper.sh grant-access \
  --mailbox support@company.com \
  --user alice@company.com \
  --role FullAccess

# Roles: FullAccess | SendAs | SendOnBehalf
```

The helper prints the exact PowerShell commands to run. Execute them in Exchange Online PowerShell:

```powershell
# Connect
Connect-ExchangeOnline -UserPrincipalName admin@company.com

# Grant FullAccess (allows reading and managing the mailbox)
Add-MailboxPermission -Identity 'support@company.com' -User 'alice@company.com' -AccessRights FullAccess -AutoMapping $true

# Grant SendAs (allows sending as the shared mailbox address)
Add-RecipientPermission -Identity 'support@company.com' -Trustee 'alice@company.com' -AccessRights SendAs

# Grant SendOnBehalf (sends "on behalf of" — shows both addresses)
Set-Mailbox -Identity 'support@company.com' -GrantSendOnBehalfTo 'alice@company.com'
```

### Revoking Access

```bash
# Show PowerShell commands for revoking access
microsoft-graph-helper.sh revoke-access \
  --mailbox support@company.com \
  --user alice@company.com
```

### Checking Permissions

```bash
# Show mailbox settings (timezone, auto-reply, delegate options)
microsoft-graph-helper.sh permissions --mailbox support@company.com
```

## Mailbox Settings

```bash
# Show mailbox settings
microsoft-graph-helper.sh permissions --mailbox support@company.com
```

Returns: automatic replies status, timezone, language, delegate meeting message delivery options.

## Adapter Status

```bash
# Show full adapter status (config, credentials names, token status)
microsoft-graph-helper.sh status
```

## Troubleshooting

### 401 Unauthorized

- Token expired: run `microsoft-graph-helper.sh token-refresh` or `auth`
- Wrong scopes: re-authenticate with `auth` to get updated scopes
- App permissions not granted: check Azure Portal > App registrations > API permissions

### 403 Forbidden

- User does not have access to the shared mailbox — grant access via Exchange Admin Center
- Application permissions not admin-consented — go to Azure Portal > API permissions > Grant admin consent
- `Mail.ReadWrite.Shared` not included in permissions — re-register the app

### 404 Not Found

- Mailbox address typo — verify the exact UPN or email address
- Folder name case-sensitive — use `list-folders` to get exact names
- Message ID invalid — IDs are base64-encoded and change when messages are moved

### Token Refresh Fails

- Refresh token expired (default 90 days for delegated, no refresh for client credentials)
- User revoked consent — re-authenticate with `auth`
- App registration deleted or disabled — check Azure Portal

### Shared Mailbox Not Accessible

- Access propagation takes up to 60 minutes after granting
- AutoMapping may need to be disabled if the mailbox appears in Outlook but not via API
- For app-only flow: ensure application permissions (not delegated) are granted and admin-consented

## Graph API Reference

| Operation | Endpoint | Method |
|-----------|----------|--------|
| List messages | `/users/{mailbox}/mailFolders/{folder}/messages` | GET |
| Get message | `/users/{mailbox}/messages/{id}` | GET |
| Send message | `/users/{mailbox}/sendMail` | POST |
| Reply | `/users/{mailbox}/messages/{id}/reply` | POST |
| Move message | `/users/{mailbox}/messages/{id}/move` | POST |
| Update message | `/users/{mailbox}/messages/{id}` | PATCH |
| Delete message | `/users/{mailbox}/messages/{id}` | DELETE |
| List folders | `/users/{mailbox}/mailFolders` | GET |
| Create folder | `/users/{mailbox}/mailFolders` | POST |
| Mailbox settings | `/users/{mailbox}/mailboxSettings` | GET |
| List users | `/users` | GET |

Use `/me` instead of `/users/{mailbox}` for the authenticated user's own mailbox.

## Security Notes

- **Credentials**: stored via `aidevops secret set` (gopass) or `credentials.sh` (0600). Never in config files or conversation.
- **Token cache**: stored at `~/.aidevops/.agent-workspace/microsoft-graph/token-cache.json` (0600). Contains access and refresh tokens — treat as a credential file.
- **Client secret**: only required for app-only flow. Passed to curl via temp file (not command argument) to avoid process list exposure.
- **Refresh token**: passed to curl via temp file for the same reason.
- **Delegation**: FullAccess grants full read/write/delete on the shared mailbox. Grant only the minimum required role.

## Related

- `services/email/email-mailbox.md` — Mailbox organisation, triage, Sieve rules (IMAP/JMAP)
- `services/email/email-agent.md` — Mission communication agent (send/receive/extract)
- `services/email/email-providers.md` — Provider comparison including Microsoft 365
- `scripts/email-agent-helper.sh` — SES-based email agent helper
- `scripts/microsoft-graph-helper.sh` — This adapter's helper script
