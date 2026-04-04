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

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# iMessage / BlueBubbles Bot Integration

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Platform**: macOS only; Messages.app relay.
- **BlueBubbles**: Recommended for bots — REST API + webhooks (DMs, groups, reactions, attachments). [Repo](https://github.com/BlueBubblesApp/bluebubbles-server)
- **imsg**: Send-only CLI for alerts. [Repo](https://github.com/steipete/imsg)
- **Security**: iMessage E2E; BlueBubbles reads decrypted messages locally.
- **Trade-offs**: Native Apple reach vs. SimpleX (privacy), Matrix (teams), Signal (1:1).

<!-- AI-CONTEXT-END -->

## Architecture

`iPhone/iPad/Mac → iMessage (E2E) → Apple → Messages.app + BlueBubbles → REST API/Webhooks → Bot → aidevops`

Messages.app decrypts to `~/Library/Messages/chat.db`. BlueBubbles watches filesystem events, emitting webhooks for bot response via REST API. `imsg` uses AppleScript for send-only.

## BlueBubbles (Recommended)

- **Setup**: macOS 11+, Messages.app signed in, Full Disk Access, Accessibility. Download DMG from [GitHub Releases](https://github.com/BlueBubblesApp/bluebubbles-server/releases).
- **Config**: Port `1234`; auth headers only; Cloudflare tunnel; poll `1000ms`. Use `caffeinate -d` for headless.

### REST API

```bash
BB="http://localhost:1234/api/v1"; AUTH='-H "Authorization: Bearer YOUR_PASSWORD"'
# Send text
curl -X POST "$BB/message/text" -H "Content-Type: application/json" $AUTH \
  -d '{"chatGuid":"iMessage;-;+1234567890","message":"Hello!","method":"apple-script"}'
# Send attachment
curl -X POST "$BB/message/attachment" $AUTH \
  -F "chatGuid=iMessage;-;+1234567890" -F "attachment=@/path/to/file.png"
# React
curl -X POST "$BB/message/react" -H "Content-Type: application/json" $AUTH \
  -d '{"chatGuid":"iMessage;-;+1234567890","selectedMessageGuid":"p:0/MSG-GUID","reaction":"love"}'
# Register webhook
curl -X POST "$BB/server/webhook" -H "Content-Type: application/json" \
  -d '{"url":"http://localhost:8080/webhook","password":"YOUR_PASSWORD"}'
```

- **Endpoints**: `GET /api/v1/chat/:guid/message` · `GET /api/v1/contact` · `GET /api/v1/server/info`
- **GUIDs**: `iMessage;-;+14155551234` (phone) · `iMessage;-;user@example.com` (email) · `iMessage;+;chat123456789` (group) · `SMS;-;+14155551234` (SMS)
- **Events**: `new-message` (fields: `data.text`, `data.chatGuid`, `data.handle.address`) · `updated-message` · `typing-indicator` · `read-receipt` · `group-name-change` · `participant-added/removed`
- **Supported**: Text, attachments, tapbacks (6), threading, edit/unsend detection, SMS fallback.
- **Unsupported**: `@mentions`, stickers.

## imsg CLI (Send-Only)

macOS 12+, Messages.app signed in, Accessibility. Best for one-way alerts.

```bash
brew install steipete/tap/imsg
imsg send "+14155551234" "Hello!"
imsg send --group "Family" "Hello!"
```

## macOS Host

- **Options**: Mac mini (recommended), macOS VM (UTM/Parallels), Cloud Mac (MacStadium/AWS).
- **Prevent sleep**: `caffeinate -d &` or `sudo pmset -a sleep 0`.
- **Keepalive** (`sh.aidevops.imessage-keepalive`): Restart Messages/BlueBubbles if missing.

```bash
# Example keepalive logic
pgrep -x "Messages" > /dev/null || open -a "Messages"
pgrep -x "BlueBubbles" > /dev/null || open -a "BlueBubbles"
```

## Access Control

- **Network**: Bind to `127.0.0.1`; Cloudflare tunnel; block port 1234 externally.
- **Secret**: `aidevops secret set BLUEBUBBLES_PASSWORD`.
- **Bot-level**: Allowlist by phone/email/group, rate limiting, `prompt-guard-helper.sh` for AI content.

## Privacy and Security

- **Encryption**: iMessage E2E (PQ3 on iOS 17.4+). Apple sees metadata, not content with ADP enabled.
- **Risk**: Local Mac compromise exposes all messages; server compromise allows bot impersonation.
- **Hardening**: Enable ADP, dedicated Apple ID, localhost binding, rotate passwords, FileVault.

## aidevops Integration

`iMessage User → Bot (webhook) → aidevops Runner → AI session → response`

- **Pattern**: Listener on 8080 → `new-message`: verify allowlist, extract `text` + `chatGuid`, call `runner-helper.sh`, reply via API.
- **Bridges**: Use BlueBubbles API custom adapter or Matrix (`matterbridge.md`).

## Limitations

- macOS only; Apple ID required; no official API.
- Automation may trigger Apple ID lockouts; macOS updates may break BlueBubbles.
- No `@mentions`, bot profiles, or command menus.
- Use dedicated Apple ID; avoid spam to prevent lockout.

## Troubleshooting

| Issue | Fix |
|-------|-----|
| App not running | `open -a Messages; open -a BlueBubbles` |
| Read failure | Grant Full Disk Access to BlueBubbles |
| Send failure | Grant Accessibility permission to BlueBubbles |
| Mac sleeping | `caffeinate -d &` |
| API 401 | Check `Authorization: Bearer` header |
| Webhook failure | Verify URL reachability; check BlueBubbles logs |
| SMS fallback | `imsg check <number>` |
| ID locked | Wait 24h or contact Apple |

## Related

`simplex.md` · `matrix-bot.md` · `matterbridge.md` · `tools/security/opsec.md` · `tools/ai-assistants/headless-dispatch.md` · [BlueBubbles docs](https://docs.bluebubbles.app/) · [Apple iMessage security](https://support.apple.com/guide/security/imessage-security-overview-secd9764312f/web)
