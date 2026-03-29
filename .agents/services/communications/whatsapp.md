---
description: WhatsApp bot via Baileys (unofficial API) — QR linking, messaging, access control, runner dispatch
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

# WhatsApp Bot Integration (Baileys)

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Library**: [Baileys](https://github.com/WhiskeySockets/Baileys) (TypeScript, MIT) — unofficial, reverse-engineered WhatsApp Web protocol
- **Runtime**: Node.js 20+ or Bun
- **Protocol**: Multi-device (linked device, no phone after pairing; max 4 devices)
- **Auth**: QR scan or pairing code → sessions persist ~14 days
- **Session**: `useMultiFileAuthState` (file-based); custom `AuthenticationState` for SQLite/Redis/PostgreSQL
- **Docs**: https://whiskeysockets.github.io/Baileys/

| Criterion | Baileys | Business API | SimpleX | Matrix |
|-----------|---------|--------------|---------|--------|
| Official | No (ban risk) | Yes | N/A | N/A |
| Cost | Free | Per-conversation | Free | Free |
| Metadata privacy | Poor | Poor | Excellent | Moderate |
| Best for | Prototyping | Production | Privacy | Teams |

<!-- AI-CONTEXT-END -->

## Installation

```bash
npm install baileys @bufbuild/protobuf  # or: bun add baileys
```

## Minimal Setup

```typescript
import makeWASocket, { DisconnectReason, useMultiFileAuthState, WASocket } from "baileys"
import { Boom } from "@hapi/boom"
import pino from "pino"

async function startBot(): Promise<void> {
  const { state, saveCreds } = await useMultiFileAuthState("./auth_info")
  const sock: WASocket = makeWASocket({ auth: state, logger: pino({ level: "warn" }), printQRInTerminal: true, browser: ["aidevops Bot", "Chrome", "1.0.0"] })
  sock.ev.on("creds.update", saveCreds)
  sock.ev.on("connection.update", ({ connection, lastDisconnect }) => {
    if (connection === "close") {
      const code = (lastDisconnect?.error as Boom)?.output?.statusCode
      if (code !== DisconnectReason.loggedOut) setTimeout(() => startBot(), 3000)
    }
  })
  sock.ev.on("messages.upsert", async ({ messages, type }) => {
    if (type !== "notify") return
    for (const msg of messages) {
      if (msg.key.fromMe || !msg.message) continue
      const text = msg.message.conversation || msg.message.extendedTextMessage?.text || ""
      if (text.startsWith("/ping")) await sock.sendMessage(msg.key.remoteJid!, { text: "pong" })
    }
  })
}
startBot()
```

**Pairing**: `printQRInTerminal: true` for QR. Pairing code: `sock.requestPairingCode("1234567890")` → enter in WhatsApp > Linked Devices. Monitor `DisconnectReason.loggedOut` for session expiry.

## JID Format

| Type | Format |
|------|--------|
| Individual | `<country><number>@s.whatsapp.net` (no `+`/spaces) |
| Group | `<id>@g.us` |
| Status | `status@broadcast` |

## Messaging

```typescript
await sock.sendMessage(jid, { text: "Hello!" })
await sock.sendMessage(groupJid, { text: "@user check", mentions: ["user@s.whatsapp.net"] })
await sock.sendMessage(jid, { text: "Reply" }, { quoted: originalMsg })
await sock.sendMessage(jid, { image: readFileSync("./photo.jpg"), caption: "Caption", mimetype: "image/jpeg" })
await sock.sendMessage(jid, { audio: readFileSync("./voice.ogg"), mimetype: "audio/ogg; codecs=opus", ptt: true })
await sock.sendMessage(jid, { document: readFileSync("./report.pdf"), mimetype: "application/pdf", fileName: "report.pdf" })
await sock.sendMessage(jid, { react: { text: "👍", key: originalMsg.key } })
await sock.sendMessage(jid, { poll: { name: "Vote?", values: ["A", "B", "C"], selectableCount: 1 } })
await sock.sendPresenceUpdate("composing", jid)
const buffer = await downloadMediaMessage(msg, "buffer", {})
```

## Groups

```typescript
const group = await sock.groupCreate("Team", ["user1@s.whatsapp.net"])
await sock.groupParticipantsUpdate(groupJid, ["user@s.whatsapp.net"], "add"|"remove"|"promote"|"demote")
await sock.groupUpdateSubject(groupJid, "New Name")
const code = await sock.groupInviteCode(groupJid)  // https://chat.whatsapp.com/${code}
```

## Access Control

```typescript
const ALLOWED_USERS = new Set(["1234567890@s.whatsapp.net"])
const ALLOWED_GROUPS = new Set(["120363012345678901@g.us"])
function isAuthorized(jid: string, sender: string): boolean {
  if (jid.endsWith("@s.whatsapp.net")) return ALLOWED_USERS.has(jid)
  if (jid.endsWith("@g.us")) return ALLOWED_GROUPS.has(jid) && ALLOWED_USERS.has(sender)
  return false
}
const rateLimits = new Map<string, number[]>()
function isRateLimited(sender: string, limit = 10): boolean {
  const now = Date.now(), recent = (rateLimits.get(sender) || []).filter(t => now - t < 60_000)
  if (recent.length >= limit) return true
  recent.push(now); rateLimits.set(sender, recent); return false
}
```

**Levels**: Public (`/help`) → Standard (`/ask`) → Privileged (`/run`) → Owner (`/config`).

## Security

**E2E protected** (Signal): message content, media, calls. **NOT protected**: contact graph, group membership, usage patterns, device info, IP, timestamps — Meta harvests for ad targeting. Backups may use Meta-held keys.

### ToS Risk

| Risk | Mitigation |
|------|------------|
| Account ban (medium-high) | Dedicated prepaid SIM, not personal |
| IP ban (low-medium) | Residential proxy/VPN |
| API breakage (high) | Pin Baileys version, monitor releases |
| Rate limiting (medium) | Human-like delays (2-5s) |

## Runner Dispatch

```typescript
import { execFileSync } from "child_process"
// ALWAYS execFileSync with arg arrays — never execSync with string interpolation (shell injection)
async function dispatchToRunner(runner: string, prompt: string, sender: string): Promise<string> {
  try {
    return execFileSync("./runner-helper.sh", ["dispatch", runner, prompt], {
      timeout: 120_000, encoding: "utf-8",
      env: { ...process.env, DISPATCH_SENDER: sender, DISPATCH_CHANNEL: "whatsapp" },
    }).trim() || "(no response)"
  } catch { return "Dispatch failed." }
}

commands.set("/ask", async (ctx) => {
  if (!ctx.args) { await ctx.sock.sendMessage(ctx.jid, { text: "Usage: /ask <question>" }); return }
  await ctx.sock.sendPresenceUpdate("composing", ctx.jid)
  await ctx.sock.sendMessage(ctx.jid, { text: await dispatchToRunner("general", ctx.args, ctx.sender) })
})
commands.set("/run", async (ctx) => {
  if (!ctx.isAdmin) { await ctx.sock.sendMessage(ctx.jid, { text: "Admin only." }); return }
  await ctx.sock.sendMessage(ctx.jid, { text: await dispatchToRunner("ops", ctx.args, ctx.sender) })
})
```

**Security**: Scan inbound with `prompt-guard-helper.sh scan "$message"` before dispatch. Validate runner names against allowlist. See `tools/security/prompt-injection-defender.md`.

## Matterbridge

Bridges WhatsApp to 20+ platforms via [whatsmeow](https://github.com/tulir/whatsmeow). Build with multi-device: `go install -tags whatsappmulti github.com/42wim/matterbridge@latest`.

```toml
[whatsapp.mywa]
# QR pairing on first run
[[gateway]]
name="wa-matrix-bridge"
enable=true
  [[gateway.inout]]
  account="whatsapp.mywa"
  channel="120363012345678901"
  [[gateway.inout]]
  account="matrix.home"
  channel="#bridged:example.com"
```

**Warning**: E2E broken at bridge — host has plaintext access. See `tools/security/opsec.md`.

## Reconnect Delays

| `DisconnectReason` | Action |
|--------------------|--------|
| `loggedOut` | Delete `auth_info/`, restart for new QR |
| `restartRequired` | 1s delay |
| `connectionClosed`/`connectionLost`/`timedOut` | 5s delay |
| default | 15s delay |

## Limitations

- **Ban risk**: High volume, rapid group ops, bulk contacts, no delays → increased risk
- **No calls**: Voice/video protocol not reverse-engineered
- **Fragile**: Protocol changes break Baileys without warning (usually fixed within days)
- **Setup**: Phone + WhatsApp app required for initial pairing
- **Single account**: One Baileys instance per account; max 1024 group members

## Related

- `services/communications/simplex.md` — SimpleX (maximum privacy)
- `services/communications/matrix-bot.md` — Matrix runner dispatch
- `services/communications/matterbridge.md` — Multi-platform bridge
- `tools/security/opsec.md` — Platform trust matrix
- `tools/security/prompt-injection-defender.md` — Bot input defense
