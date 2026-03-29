---
description: WhatsApp bot integration via Baileys — QR linking, multi-device, messaging, access control, runner dispatch, Matterbridge bridging
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

- **Library**: [Baileys](https://github.com/WhiskeySockets/Baileys) (TypeScript, MIT) — unofficial reverse-engineered WhatsApp Web API
- **Runtime**: Node.js 20+ or Bun
- **Protocol**: Multi-device (linked device, no phone after pairing; max 4 linked devices)
- **Encryption**: Signal Protocol E2E (WhatsApp-implemented, not Baileys)
- **Auth**: QR scan or pairing code; sessions expire after ~14 days inactivity
- **Session store**: `useMultiFileAuthState` (file-based); custom `AuthenticationState` for SQLite/Redis/PostgreSQL
- **npm**: `baileys` | **Docs**: https://whiskeysockets.github.io/Baileys/
- **Limits**: No voice/video calls; 1 account per bot; max 1024 group members; WA protocol changes can break Baileys without warning

| Criterion | Baileys | WA Business API | SimpleX | Matrix |
|-----------|---------|-----------------|---------|--------|
| Official | No (reverse-engineered) | Yes (Meta) | N/A | N/A |
| Cost | Free | Per-conversation | Free | Free |
| Ban risk | Yes (ToS violation) | No | No | No |
| Metadata privacy | Poor (Meta) | Poor | Excellent | Moderate |
| Best for | Existing WA users, prototyping | Production business | Max privacy | Team collab |

<!-- AI-CONTEXT-END -->

## Installation

```bash
npm install baileys @bufbuild/protobuf  # or: bun add baileys
# Optional: qrcode-terminal, pino, link-preview-js, sharp, fluent-ffmpeg
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
      // loggedOut: delete auth_info/, restart for new QR. Otherwise auto-reconnect.
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

**Pairing**: `printQRInTerminal: true` for QR. Pairing code: `sock.requestPairingCode("1234567890")` → enter in WhatsApp > Linked Devices.

## JID Format

| Type | Format | Example |
|------|--------|---------|
| Individual | `<phone>@s.whatsapp.net` | `1234567890@s.whatsapp.net` |
| Group | `<id>@g.us` | `120363012345678901@g.us` |
| Status broadcast | `status@broadcast` | `status@broadcast` |

Phone number: country code + number, no `+`, no spaces/dashes.

## Messaging Features

```typescript
// Text, mentions, quoted reply
await sock.sendMessage(jid, { text: "Hello!" })
await sock.sendMessage(groupJid, { text: "@user check this", mentions: ["user@s.whatsapp.net"] })
await sock.sendMessage(jid, { text: "Reply" }, { quoted: originalMsg })
// Media: image, video, audio (ptt), document, sticker, location
await sock.sendMessage(jid, { image: readFileSync("./photo.jpg"), caption: "Caption", mimetype: "image/jpeg" })
await sock.sendMessage(jid, { image: { url: "https://example.com/photo.jpg" }, caption: "From URL" })
await sock.sendMessage(jid, { audio: readFileSync("./voice.ogg"), mimetype: "audio/ogg; codecs=opus", ptt: true })
await sock.sendMessage(jid, { document: readFileSync("./report.pdf"), mimetype: "application/pdf", fileName: "report.pdf" })
// Reaction, poll, presence, media download
await sock.sendMessage(jid, { react: { text: "👍", key: originalMsg.key } })
await sock.sendMessage(jid, { poll: { name: "What next?", values: ["A", "B", "C"], selectableCount: 1 } })
await sock.sendPresenceUpdate("composing", jid)
const buffer = await downloadMediaMessage(msg, "buffer", {})
```

## Group Management

```typescript
const group = await sock.groupCreate("Team", ["user1@s.whatsapp.net"])
const metadata = await sock.groupMetadata(groupJid)
await sock.groupParticipantsUpdate(groupJid, ["user@s.whatsapp.net"], "add"|"remove"|"promote"|"demote")
await sock.groupUpdateSubject(groupJid, "New Name")
await sock.groupSettingUpdate(groupJid, "announcement"|"locked")
const code = await sock.groupInviteCode(groupJid)  // https://chat.whatsapp.com/${code}
```

## Access Control

```typescript
const ALLOWED_USERS = new Set(["1234567890@s.whatsapp.net"])
const ALLOWED_GROUPS = new Set(["120363012345678901@g.us"])
const ADMIN_USERS = new Set(["1234567890@s.whatsapp.net"])
function isAuthorized(jid: string, sender: string): boolean {
  if (jid.endsWith("@s.whatsapp.net")) return ALLOWED_USERS.has(jid)
  if (jid.endsWith("@g.us")) return ALLOWED_GROUPS.has(jid) && ALLOWED_USERS.has(sender)
  return false
}
// Rate limiting: 10 msgs/min per sender
const rateLimits = new Map<string, number[]>()
function isRateLimited(sender: string): boolean {
  const now = Date.now()
  const recent = (rateLimits.get(sender) || []).filter(t => now - t < 60_000)
  if (recent.length >= 10) return true
  recent.push(now); rateLimits.set(sender, recent); return false
}
```

**Permission levels**: Public (`/help`, `/ping`) → Standard (`/ask`) → Privileged (`/run`, `/deploy`) → Owner (`/config`, `/allow`).

## Privacy and Security

**E2E protected** (Signal Protocol): message text, media, calls, group messages, status broadcasts.

**NOT protected** (Meta metadata): contact graph, group membership, usage patterns, device info, IP, timestamps. Used for cross-platform ad targeting. Backups may use Meta-held keys. Meta AI processes content when invoked.

| ToS Risk | Likelihood | Mitigation |
|----------|-----------|------------|
| Account ban | Medium-High | Dedicated prepaid SIM, not personal |
| IP ban | Low-Medium | Residential proxy or VPN |
| API changes | High | Pin Baileys version, monitor releases |
| Rate limiting | Medium | Human-like delays (2-5s) |

## aidevops Runner Dispatch

```typescript
import { execFileSync } from "child_process"
import { WASocket, proto } from "baileys"
interface CommandContext { sock: WASocket; msg: proto.IWebMessageInfo; sender: string; jid: string; args: string; isAdmin: boolean; isGroup: boolean }

// ALWAYS execFileSync with arg arrays — never execSync with string interpolation (shell injection)
async function dispatchToRunner(runner: string, prompt: string, sender: string): Promise<string> {
  try {
    return execFileSync("./runner-helper.sh", ["dispatch", runner, prompt], {
      timeout: 120_000, encoding: "utf-8",
      env: { ...process.env, DISPATCH_SENDER: sender, DISPATCH_CHANNEL: "whatsapp" },
    }).trim() || "(no response)"
  } catch { return "Dispatch failed. Check bot logs." }
}

const commands = new Map<string, (ctx: CommandContext) => Promise<void>>()
commands.set("/ask", async (ctx) => {
  if (!ctx.args) { await ctx.sock.sendMessage(ctx.jid, { text: "Usage: /ask <question>" }); return }
  await ctx.sock.sendPresenceUpdate("composing", ctx.jid)
  await ctx.sock.sendMessage(ctx.jid, { text: await dispatchToRunner("general", ctx.args, ctx.sender) })
})
commands.set("/run", async (ctx) => {
  if (!ctx.isAdmin) { await ctx.sock.sendMessage(ctx.jid, { text: "Admin only." }); return }
  await ctx.sock.sendMessage(ctx.jid, { text: await dispatchToRunner("ops", ctx.args, ctx.sender) })
})
// Message router: extract text, check isAuthorized + isRateLimited, dispatch to commands map
```

**Security**: Scan inbound with `prompt-guard-helper.sh scan "$message"` before dispatch. Validate runner names against allowlist. See `tools/security/prompt-injection-defender.md`.

## Matterbridge Integration

Native WhatsApp support via [whatsmeow](https://github.com/tulir/whatsmeow) (Go) — bridges to 20+ platforms. Build: `go install -tags whatsappmulti github.com/42wim/matterbridge@latest` (`-tags whatsappmulti` required, excluded from default binary due to GPL3).

```toml
[whatsapp]
  [whatsapp.mywa]
  # No token — QR pairing on first run

[[gateway]]
name="wa-matrix-bridge"
enable=true
  [[gateway.inout]]
  account="whatsapp.mywa"
  channel="120363012345678901"  # Group JID without @g.us
  [[gateway.inout]]
  account="matrix.home"
  channel="#bridged:example.com"
```

E2E broken at bridge — bridge host has plaintext access. See `tools/security/opsec.md`.

## Related

- `services/communications/simplex.md` — SimpleX (max privacy, no identifiers)
- `services/communications/matrix-bot.md` — Matrix bot runner dispatch
- `services/communications/matterbridge.md` — Multi-platform chat bridge
- `services/communications/xmtp.md` — XMTP (Web3 messaging)
- `tools/security/opsec.md` — Platform trust matrix
- `tools/security/prompt-injection-defender.md` — Prompt injection defense
- https://www.whatsapp.com/security/WhatsApp-Security-Whitepaper.pdf
- https://github.com/42wim/matterbridge
