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
- **Config template**: `configs/microsoft-graph-config.json.txt` → working: `configs/microsoft-graph-config.json` (gitignored)
- **Token cache**: `~/.aidevops/.agent-workspace/microsoft-graph/token-cache.json` (0600)
- **Auth flows**: Device flow (delegated, interactive) | Client credentials (app-only, headless)
- **API**: Microsoft Graph v1.0 — `https://graph.microsoft.com/v1.0`

**Graph API vs IMAP**: Prefer Graph for shared mailbox delegation, richer permissions, and programmatic access. IMAP is simpler for basic read/send but lacks delegation APIs.

<!-- AI-CONTEXT-END -->

## Setup

### 1. Register Azure AD App

```bash
open https://portal.azure.com/#view/Microsoft_AAD_RegisteredApps/ApplicationsListBlade
```

1. **New registration** — Name: `aidevops-graph-adapter`, Account type: `Single tenant`
2. **API permissions** → Microsoft Graph → Delegated: `Mail.ReadWrite`, `Mail.Send`, `Mail.ReadWrite.Shared`, `Mail.Send.Shared`, `MailboxSettings.ReadWrite`, `offline_access`
3. App-only flow: use **Application** permissions instead, then **Grant admin consent**
4. **Certificates & secrets** → New client secret (app-only only)
5. Note **Application (client) ID** and **Directory (tenant) ID** from Overview

### 2. Configure and Authenticate

```bash
cp .agents/configs/microsoft-graph-config.json.txt .agents/configs/microsoft-graph-config.json
# Edit: set tenant_id, client_id, shared_mailboxes. Do NOT put credentials in the config file.

# WARNING: Never paste secret values into AI chat. Run these in your terminal.
aidevops secret set MSGRAPH_CLIENT_ID
aidevops secret set MSGRAPH_TENANT_ID
aidevops secret set MSGRAPH_CLIENT_SECRET  # app-only flow only

microsoft-graph-helper.sh auth                       # Device flow (delegated — opens browser)
microsoft-graph-helper.sh auth --client-credentials  # App-only (headless)
```

## Authentication Flows

| Flow | Best for | Scopes |
|------|----------|--------|
| **Device flow** (delegated) | Interactive sessions, personal/shared mailboxes with user access | `Mail.ReadWrite Mail.Send Mail.ReadWrite.Shared Mail.Send.Shared MailboxSettings.ReadWrite offline_access` |
| **Client credentials** (app-only) | Headless automation, CI/CD, shared mailboxes without user context | `https://graph.microsoft.com/.default` |

**Client credentials**: no user interaction, no refresh token — re-authenticates on expiry. Requires admin consent. **Cannot access personal mailboxes.**

```bash
microsoft-graph-helper.sh token-status   # Check expiry and scopes (never shows values)
microsoft-graph-helper.sh token-refresh  # Force refresh (uses refresh token if available)
```

Token cache (0600) stores access token, refresh token, expiry, and scopes — never printed to output.

## Shared Mailbox Operations

The authenticated user must have been granted access via Exchange Admin Center or PowerShell before Graph API calls succeed.

```bash
# Read
microsoft-graph-helper.sh list-messages --mailbox support@company.com --folder Inbox --limit 50 --since 2026-03-01T00:00:00Z
microsoft-graph-helper.sh get-message   --mailbox support@company.com --id <message-id>

# Send (requires Mail.Send.Shared + SendAs or SendOnBehalf delegation)
microsoft-graph-helper.sh send  --mailbox support@company.com --to customer@example.com --subject "Re: ..." --body "..."
microsoft-graph-helper.sh send  --mailbox support@company.com --to customer@example.com --subject "Welcome" --body "<h1>...</h1>" --html
microsoft-graph-helper.sh reply --mailbox support@company.com --id <message-id> --body "..."

# Organise
microsoft-graph-helper.sh move   --mailbox support@company.com --id <id> --folder Archive
microsoft-graph-helper.sh flag   --mailbox support@company.com --id <id> --flag read|unread|flagged
microsoft-graph-helper.sh delete --mailbox support@company.com --id <message-id>

# Folders
microsoft-graph-helper.sh list-folders  --mailbox support@company.com
microsoft-graph-helper.sh create-folder --mailbox support@company.com --name "Resolved"
```

## Delegation Management

Graph API does not expose mailbox permission management — use Exchange Online PowerShell or Microsoft 365 Admin Center.

```bash
# Print PowerShell commands for granting/revoking access (roles: FullAccess | SendAs | SendOnBehalf)
microsoft-graph-helper.sh grant-access  --mailbox support@company.com --user alice@company.com --role FullAccess
microsoft-graph-helper.sh revoke-access --mailbox support@company.com --user alice@company.com
microsoft-graph-helper.sh permissions   --mailbox support@company.com  # auto-replies, timezone, delegate options
```

Execute the printed commands in Exchange Online PowerShell:

```powershell
Connect-ExchangeOnline -UserPrincipalName admin@company.com
Add-MailboxPermission    -Identity 'support@company.com' -User 'alice@company.com' -AccessRights FullAccess -AutoMapping $true
Add-RecipientPermission  -Identity 'support@company.com' -Trustee 'alice@company.com' -AccessRights SendAs
Set-Mailbox              -Identity 'support@company.com' -GrantSendOnBehalfTo 'alice@company.com'
```

## Status and Troubleshooting

```bash
microsoft-graph-helper.sh status  # Config, credential names, token status
```

| Error | Cause | Fix |
|-------|-------|-----|
| **401 Unauthorized** | Token expired or wrong scopes | `token-refresh` or `auth`; check Azure Portal > API permissions |
| **403 Forbidden** | No mailbox access, missing admin consent, or `Mail.ReadWrite.Shared` absent | Grant access via Exchange Admin Center; grant admin consent in Azure Portal |
| **404 Not Found** | Mailbox typo, case-sensitive folder name, or moved message (IDs change on move) | Verify UPN; use `list-folders` for exact names |
| **Token refresh fails** | Refresh token expired (90-day default for delegated), user revoked consent, or app deleted | Re-authenticate with `auth`; check Azure Portal |
| **Shared mailbox inaccessible** | Access propagation delay (up to 60 min), AutoMapping conflict, or wrong permission type for app-only | Wait; disable AutoMapping if needed; ensure application (not delegated) permissions for app-only |

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
- **Token cache**: (0600) — contains access and refresh tokens, treat as a credential file.
- **Client secret**: app-only flow only. Passed to curl via temp file (not command argument) to avoid process list exposure.
- **Delegation**: FullAccess grants full read/write/delete. Grant only the minimum required role.

## Related

- `services/email/email-mailbox.md` — Mailbox organisation, triage, Sieve rules (IMAP/JMAP)
- `services/email/email-agent.md` — Mission communication agent (send/receive/extract)
- `services/email/email-providers.md` — Provider comparison including Microsoft 365
- `scripts/microsoft-graph-helper.sh` — This adapter's helper script
