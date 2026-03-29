---
description: iMessage/BlueBubbles bot integration — BlueBubbles REST API (recommended), imsg CLI (send-only), macOS requirements, messaging features, access control, privacy/security assessment, and aidevops runner dispatch
mode: subagent
tools:
  read: true
  write: false
  edit: false
  bash: true
  glob: false
  grep: false
  webfetch: false
  task: false
---

# iMessage / BlueBubbles Bot Integration

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Platform**: macOS only (Messages.app required as relay)
- **BlueBubbles**: REST API + webhooks — DMs/groups/reactions/attachments/typing/read receipts. [Repo](https://github.com/BlueBubblesApp/bluebubbles-server) (Apache-2.0)
- **imsg**: Send-only CLI. [Repo](https://github.com/steipete/imsg) (MIT)
- **Encryption**: iMessage E2E (Apple-managed); BlueBubbles reads locally on Mac
- **vs SimpleX/Matrix/Signal**: Use iMessage to reach Apple users natively; SimpleX for max privacy; Matrix for team collab; Signal for secure 1:1

<!-- AI-CONTEXT-END -->

## Architecture

`iPhone/iPad/Mac → iMessage (E2E) → Apple Servers → Messages.app + BlueBubbles Server → REST API/Webhooks → Bot → aidevops dispatch`

Inbound: Messages.app decrypts to local SQLite → BlueBubbles detects via filesystem events → fires webhook → bot responds via REST API. imsg: send-only via AppleScript.

## BlueBubbles (Recommended)

**Requirements**: macOS 11+, Messages.app signed in, Full Disk Access + Accessibility, persistent GUI session. **Install**: Download DMG from [GitHub Releases](https://github.com/BlueBubblesApp/bluebubbles-server/releases) (Homebrew cask deprecated 2026-09-01). Right-click Open (Gatekeeper), grant Full Disk Access + Accessibility, set password, configure Cloudflare tunnel.

**Server config**: Port `1234` · Password (header only — query params are logged) · Proxy: Cloudflare · Poll: `1000ms` · **Headless**: `caffeinate -d` to prevent sleep; complete iCloud 2FA interactively first.

### REST API

```bash
BB="http://localhost:1234/api/v1"
AUTH='-H "Authorization: Bearer YOUR_PASSWORD"'

# Send text (use iMessage;+;chat123 for groups)
curl -X POST "$BB/message/text" -H "Content-Type: application/json" $AUTH \
  -d '{"chatGuid":"iMessage;-;+1234567890","message":"Hello!","method":"apple-script"}'

# Send attachment
curl -X POST "$BB/message/attachment" $AUTH \
  -F "chatGuid=iMessage;-;+1234567890" -F "attachment=@/path/to/file.png"

# Tapback
curl -X POST "$BB/message/react" -H "Content-Type: application/json" $AUTH \
  -d '{"chatGuid":"iMessage;-;+1234567890","selectedMessageGuid":"p:0/MSG-GUID","reaction":"love"}'

# Register webhook
curl -X POST "$BB/server/webhook" -H "Content-Type: application/json" \
  -d '{"url":"http://localhost:8080/webhook","password":"YOUR_PASSWORD"}'
```

**Other endpoints**: `GET /api/v1/chat/:guid/message` · `GET /api/v1/contact` · `GET /api/v1/server/info`

**Chat GUID**: `iMessage;-;+14155551234` (phone) · `iMessage;-;user@example.com` (email) · `iMessage;+;chat123456789` (group) · `SMS;-;+14155551234` (SMS)

**Reactions**: `love` `like` `dislike` `laugh` `emphasize` `question`

**Webhook events**: `new-message` · `updated-message` · `typing-indicator` · `read-receipt` · `group-name-change` · `participant-added/removed/left` · `chat-read-status-changed`

**`new-message` fields**: `data.guid` · `data.text` · `data.chatGuid` · `data.handle.address` · `data.isFromMe` · `data.hasAttachments`

**Supported**: text · attachments · tapbacks (6 types) · reply threading · edit/unsend detection · typing indicators (inbound) · read receipts · SMS fallback · group read (add/remove via AppleScript). **Not supported**: @mentions · stickers

## imsg CLI (Send-Only)

macOS 12+, Messages.app signed in, Accessibility permission. Use for notifications/alerts; BlueBubbles for interactive bots.

```bash
brew install steipete/tap/imsg
imsg send "+14155551234" "Hello!"
imsg send "user@example.com" "Hello via email"
imsg send --group "Family" "Hello family!"
imsg check "+14155551234"   # Check if recipient has iMessage
```

## macOS Host

**Options**: Mac mini (~$600+, recommended) · macOS VM on Apple Silicon (UTM/Parallels) · Cloud Mac (MacStadium/AWS EC2, $50–200/month)

```bash
caffeinate -d &; sudo pmset -a sleep 0   # Prevent sleep
# Auto-start Messages.app on login:
osascript -e 'tell application "System Events" to make login item at end with properties {path:"/System/Applications/Messages.app", hidden:true}'
```

**Keepalive** (`sh.aidevops.imessage-keepalive`):

```bash
#!/bin/bash
check_and_restart() {
  local app_name="$1"
  pgrep -x "$app_name" > /dev/null && return 0
  open -a "$app_name"; sleep 5
  pgrep -x "$app_name" > /dev/null || { echo "ERROR: Failed to restart $app_name"; return 1; }
  return 0
}
check_and_restart "Messages"; check_and_restart "BlueBubbles"
```

## Access Control

**API**: Bind to `127.0.0.1`; Cloudflare tunnel for remote; block port 1234 externally. Store password: `aidevops secret set BLUEBUBBLES_PASSWORD`. **Bot-level** (in bot process, not BlueBubbles): allowlist by phone/email · allowlist by group · command-level permissions · rate limiting · `prompt-guard-helper.sh` before passing to AI.

## Privacy and Security

**iMessage encryption**: E2E via RSA-OAEP/ECIES P-256 (iOS 13+)/PQ3 AES-256-CTR (iOS 17.4+); ECDSA P-256 signing; CKV key verification (iOS 17.2+, optional).

**Apple can see**: Metadata (who, when, IP), contact graph. **Cannot see**: Content; backups with ADP enabled.

**BlueBubbles**: Reads `~/Library/Messages/chat.db`. Mac compromise = full message access. Server compromise = attacker reads/sends as bot's Apple ID.

**Recommendations**: Enable ADP · Dedicated Apple ID · Bind to localhost + Cloudflare · Rotate password · Monitor host (FileVault, firewall) · Don't store sensitive data in iMessage.

## aidevops Integration

`iMessage User → Bot (webhook handler) → aidevops Runner → AI session → response`

**Bot pattern**: Listener on port 8080 → on `new-message`: verify allowlist, extract `text`+`chatGuid` → `runner-helper.sh` → reply via REST API.

**Matterbridge**: Not natively supported. Bridge via BlueBubbles API → custom adapter, or via Matrix. See `matterbridge.md`.

## Limitations

macOS only · Apple ID required · no official Apple API · Messages.app crashes need monitoring · macOS updates may break BlueBubbles · heavy automation may trigger Apple ID lockouts · no @mentions/bot profile/command menus · AppleScript + direct DB reads not Apple-sanctioned (use dedicated Apple ID; no spam)

## Troubleshooting

| Issue | Fix |
|-------|-----|
| Messages.app not running | `open -a Messages` |
| BlueBubbles can't read messages | Grant Full Disk Access (System Settings > Privacy & Security) |
| Send fails | Grant Accessibility permission to BlueBubbles |
| Mac sleeping | `caffeinate -d &` or `sudo pmset -a sleep 0` |
| API 401 | Check password in `Authorization: Bearer` header |
| Webhook not firing | Verify URL reachable; check BlueBubbles logs |
| iMessage not activating | Verify Apple ID signed in; check internet |
| SMS instead of iMessage | `imsg check <number>` |
| Apple ID locked | Wait 24h or contact Apple |
| macOS update broke BlueBubbles | Check GitHub releases for compatible version |

## Related

`simplex.md` · `matrix-bot.md` · `matterbridge.md` · `tools/security/opsec.md` · `tools/ai-assistants/headless-dispatch.md` · [BlueBubbles docs](https://docs.bluebubbles.app/) · [Apple iMessage security](https://support.apple.com/guide/security/imessage-security-overview-secd9764312f/web) · [imsg CLI](https://github.com/steipete/imsg)
