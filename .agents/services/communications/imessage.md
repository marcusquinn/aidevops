---
description: iMessage/BlueBubbles bot integration — REST API, imsg CLI, macOS setup, access control, privacy, aidevops dispatch
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

- **Platform**: macOS only; Messages.app is the relay
- **BlueBubbles**: Recommended for bots — REST API + webhooks for DMs, groups, reactions, attachments, typing, and read receipts. [Repo](https://github.com/BlueBubblesApp/bluebubbles-server) (Apache-2.0)
- **imsg**: Send-only CLI for alerts/one-way notifications. [Repo](https://github.com/steipete/imsg) (MIT)
- **Security model**: iMessage stays Apple-managed E2E; BlueBubbles reads decrypted messages locally on the Mac
- **Trade-off**: Use iMessage to reach Apple users natively; SimpleX for max privacy; Matrix for team chat; Signal for secure 1:1

<!-- AI-CONTEXT-END -->

## Architecture

`iPhone/iPad/Mac → iMessage (E2E) → Apple Servers → Messages.app + BlueBubbles Server → REST API/Webhooks → Bot → aidevops dispatch`

Messages.app decrypts into local SQLite (`~/Library/Messages/chat.db`), BlueBubbles watches filesystem events, then emits webhook events the bot answers via REST API. `imsg` is send-only via AppleScript.

## BlueBubbles (Recommended)

- **Requirements**: macOS 11+, Messages.app signed in, Full Disk Access, Accessibility, persistent GUI session
- **Install**: Download DMG from [GitHub Releases](https://github.com/BlueBubblesApp/bluebubbles-server/releases) (Homebrew cask deprecated 2026-09-01), drag to `/Applications`, right-click Open, grant permissions, set password, configure Cloudflare tunnel
- **Server config**: Port `1234`; send password in headers only (query params are logged); proxy through Cloudflare; poll `1000ms`; for headless hosts use `caffeinate -d`; complete iCloud 2FA interactively first

### REST API

```bash
BB="http://localhost:1234/api/v1"; AUTH='-H "Authorization: Bearer YOUR_PASSWORD"'
curl -X POST "$BB/message/text" -H "Content-Type: application/json" $AUTH \
  -d '{"chatGuid":"iMessage;-;+1234567890","message":"Hello!","method":"apple-script"}'
curl -X POST "$BB/message/attachment" $AUTH \
  -F "chatGuid=iMessage;-;+1234567890" -F "attachment=@/path/to/file.png"
curl -X POST "$BB/message/react" -H "Content-Type: application/json" $AUTH \
  -d '{"chatGuid":"iMessage;-;+1234567890","selectedMessageGuid":"p:0/MSG-GUID","reaction":"love"}'
curl -X POST "$BB/server/webhook" -H "Content-Type: application/json" \
  -d '{"url":"http://localhost:8080/webhook","password":"YOUR_PASSWORD"}'
```

**Endpoints**

- **Useful reads**: `GET /api/v1/chat/:guid/message` · `GET /api/v1/contact` · `GET /api/v1/server/info`
- **Chat GUIDs**: `iMessage;-;+14155551234` (phone) · `iMessage;-;user@example.com` (email) · `iMessage;+;chat123456789` (group) · `SMS;-;+14155551234` (SMS)
- **Reactions**: `love` `like` `dislike` `laugh` `emphasize` `question`
- **Webhook events**: `new-message` · `updated-message` · `typing-indicator` · `read-receipt` · `group-name-change` · `participant-added/removed/left` · `chat-read-status-changed`
- **Key `new-message` fields**: `data.guid` · `data.text` · `data.chatGuid` · `data.handle.address` · `data.isFromMe` · `data.hasAttachments`
- **Supported**: text, attachments, tapbacks (6 types), reply threading, edit/unsend detection, inbound typing indicators, read receipts, SMS fallback, group add/remove via AppleScript
- **Not supported**: `@mentions`, stickers

## imsg CLI (Send-Only)

macOS 12+, Messages.app signed in, Accessibility permission. Good for alerts; use BlueBubbles for interactive bots.

```bash
brew install steipete/tap/imsg
imsg send "+14155551234" "Hello!"
imsg send "user@example.com" "Hello!"
imsg send --group "Family" "Hello!"
imsg check "+14155551234"
```

## macOS Host

- **Options**: Mac mini (~$600+, recommended) · macOS VM on Apple Silicon (UTM/Parallels) · Cloud Mac (MacStadium/AWS EC2, $50–200/month)
- **Prevent sleep**: `caffeinate -d &` or `sudo pmset -a sleep 0`
- **Keepalive** (`sh.aidevops.imessage-keepalive`): restart Messages.app and BlueBubbles if missing

```bash
check_and_restart() {
  pgrep -x "$1" > /dev/null && return 0
  open -a "$1"; sleep 5
  pgrep -x "$1" > /dev/null || { echo "ERROR: Failed to restart $1"; return 1; }
}
check_and_restart "Messages"; check_and_restart "BlueBubbles"
```

## Access Control

- **API**: Bind to `127.0.0.1`; Cloudflare tunnel for remote; block port 1234 externally
- **Secret**: `aidevops secret set BLUEBUBBLES_PASSWORD`
- **Bot-level** (in bot process, not BlueBubbles): allowlist by phone/email, allowlist by group, command-level permissions, rate limiting, and `prompt-guard-helper.sh` before handing content to AI

## Privacy and Security

- **iMessage encryption**: E2E. Classic uses RSA-OAEP; iOS 13+ uses ECIES P-256; iOS 17.4+ PQ3 uses AES-256-CTR + ML-KEM-1024. ECDSA P-256 signing; optional CKV key verification on iOS 17.2+. Apple still sees metadata (who, when, IP, contact graph), not message content when ADP is enabled.
- **BlueBubbles risk**: If the Mac is compromised, all messages are exposed; if the server is compromised, an attacker can read/send as the bot Apple ID.
- **Recommendations**: Enable ADP, use a dedicated Apple ID, bind to localhost + Cloudflare, rotate password, monitor host hardening (FileVault, firewall), avoid storing sensitive data in iMessage

## aidevops Integration

`iMessage User → Bot (webhook handler) → aidevops Runner → AI session → response`

- **Bot pattern**: Listener on port 8080 → on `new-message`: verify allowlist, extract `text` + `chatGuid`, call `runner-helper.sh`, reply via REST API
- **Matterbridge**: Not native; bridge through the BlueBubbles API with a custom adapter, or route through Matrix (`matterbridge.md`)

## Limitations

- macOS only; Apple ID required; no official Apple API
- Messages.app crashes need monitoring; macOS updates may break BlueBubbles
- Heavy automation may trigger Apple ID lockouts
- No @mentions, bot profile, or command menus
- AppleScript + direct DB reads not Apple-sanctioned — use dedicated Apple ID; no spam

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
