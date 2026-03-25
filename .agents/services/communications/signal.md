---
description: Signal bot integration via signal-cli — registration, JSON-RPC daemon mode, DM/group messaging, attachments, reactions, access control, privacy/security assessment, aidevops runner dispatch, and Matterbridge bridging
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

# Signal Bot Integration (signal-cli)

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Type**: E2E encrypted messaging — phone number required, minimal metadata, sealed sender
- **License**: GPL-3.0 (signal-cli); GPL-3.0 (libsignal)
- **Bot tool**: [signal-cli](https://github.com/AsamK/signal-cli) (Java/GraalVM native, 4.2K stars)
- **Daemon API**: JSON-RPC 2.0 over HTTP (`:8080`), TCP (`:7583`), Unix socket, stdin/stdout, D-Bus
- **SSE endpoint**: `GET /api/v1/events` (incoming messages as Server-Sent Events)
- **Data**: `~/.local/share/signal-cli/data/` (SQLite: `account.db`)
- **Registration**: SMS/voice verification + CAPTCHA, or QR code link to existing account
- **Protocol**: Signal Protocol (Double Ratchet + X3DH, Curve25519, AES-256-CBC, HMAC-SHA256)
- **Docs**: https://github.com/AsamK/signal-cli/wiki

**Key differentiator**: Gold standard for mainstream encrypted messaging. E2E encrypted by default, sealed sender hides sender identity from the server, minimal metadata, non-profit operator (no AI training on chat data), independent security audits, 1B+ installs.

**When to use Signal vs other platforms**:

| Criterion | Signal | SimpleX | Matrix |
|-----------|--------|---------|--------|
| User identifiers | Phone number (hidden via usernames) | None | `@user:server` |
| E2E encryption | Default, all messages | Default, all messages | Opt-in (rooms) |
| Server metadata | Minimal (sealed sender) | Stateless (memory only) | Full history stored |
| User base | 1B+ installs, mainstream | Niche, privacy-focused | Technical, federated |
| Best for | Mainstream secure comms, wide reach | Maximum privacy, zero-knowledge | Team collaboration, bridges |

<!-- AI-CONTEXT-END -->

## Architecture

```text
Signal Mobile/Desktop → Signal Servers (minimal metadata, no message content)
                              │
                        signal-cli daemon (JSON-RPC on :8080 / TCP :7583 / Unix socket)
                              │ JSON-RPC 2.0 / SSE
                        Bot Process (command router, access control, aidevops dispatch)
```

**Message flow**: Sender encrypts with Signal Protocol (Double Ratchet + X3DH) → sealed sender wraps message hiding sender identity → Signal servers deliver (no content access) → signal-cli daemon decrypts locally → JSON-RPC notification pushed to bot via SSE → bot responds via JSON-RPC `send`.

## Installation

### JVM Build (requires JRE 25+)

```bash
VERSION=$(curl -Ls -o /dev/null -w %{url_effective} \
  https://github.com/AsamK/signal-cli/releases/latest | sed -e 's/^.*\/v//')
curl -L -O "https://github.com/AsamK/signal-cli/releases/download/v${VERSION}/signal-cli-${VERSION}.tar.gz"
sudo tar xf "signal-cli-${VERSION}.tar.gz" -C /opt
sudo ln -sf "/opt/signal-cli-${VERSION}/bin/signal-cli" /usr/local/bin/
signal-cli --version
```

### GraalVM Native Binary (no JRE required, experimental)

```bash
VERSION=$(curl -Ls -o /dev/null -w %{url_effective} \
  https://github.com/AsamK/signal-cli/releases/latest | sed -e 's/^.*\/v//')
curl -L -O "https://github.com/AsamK/signal-cli/releases/download/v${VERSION}/signal-cli-${VERSION}-Linux-native.tar.gz"
sudo tar xf "signal-cli-${VERSION}-Linux-native.tar.gz" -C /opt
sudo ln -sf /opt/signal-cli /usr/local/bin/
```

### Docker / OCI Container

```bash
docker pull ghcr.io/asamk/signal-cli
docker run -d --name signal-cli \
  -v signal-cli-data:/home/.local/share/signal-cli \
  -p 8080:8080 \
  ghcr.io/asamk/signal-cli:latest \
  daemon --http 0.0.0.0:8080
```

### Package Managers

| Manager | Package |
|---------|---------|
| Arch Linux (AUR) | `signal-cli` |
| Flathub | `org.asamk.SignalCli` |
| Debian/Ubuntu | [packaging.gitlab.io](https://packaging.gitlab.io/signal-cli/installation/standalone/) |
| Alpine | `signal-cli` |
| Fedora/EPEL (RPM) | [signal-cli-rpm](https://github.com/pbiering/signal-cli-rpm) |

**Note**: No native Homebrew formula. On macOS, use the JVM or native binary install.

**Native library**: Bundled for x86_64 Linux, Windows, macOS. Other architectures must provide `libsignal-client` — see the [wiki](https://github.com/AsamK/signal-cli/wiki/Provide-native-lib-for-libsignal).

## Registration

### SMS Verification

```bash
signal-cli -a +1234567890 register
signal-cli -a +1234567890 verify 123-456
```

### Voice Verification (landline numbers)

```bash
signal-cli -a +1234567890 register        # attempt SMS first
signal-cli -a +1234567890 register --voice  # wait 60s, then request voice call
signal-cli -a +1234567890 verify 123-456
```

### CAPTCHA (almost always required)

1. Open https://signalcaptchas.org/registration/generate.html in a browser on the **same external IP** as signal-cli
2. Solve the CAPTCHA, right-click "Open Signal" link, copy the URL

```bash
signal-cli -a +1234567890 register \
  --captcha "signalcaptcha://signal-recaptcha-v2.somecode.registration.somelongcode"
```

### QR Code Linking (recommended for bots)

Links signal-cli as a secondary device, keeping the primary phone active:

```bash
signal-cli link -n "aidevops-bot" | tee >(xargs -L 1 qrencode -t utf8)
# Scan QR with primary Signal app: Settings > Linked Devices > Link New Device
signal-cli -a +1234567890 receive  # sync contacts and groups
```

**Limits**: Up to 5 linked devices per primary account.

### PIN Protection

```bash
signal-cli -a +1234567890 verify 123-456 --pin YOUR_PIN
signal-cli -a +1234567890 setPin YOUR_PIN
signal-cli -a +1234567890 removePin
```

## Daemon Mode

signal-cli runs as a persistent daemon exposing a JSON-RPC 2.0 interface. Multiple transports can run simultaneously.

### HTTP (recommended for bots)

```bash
signal-cli -a +1234567890 daemon --http          # localhost:8080
signal-cli -a +1234567890 daemon --http 0.0.0.0:8080  # custom bind
signal-cli daemon --http                          # multi-account
```

**HTTP endpoints**:

| Endpoint | Method | Description |
|----------|--------|-------------|
| `/api/v1/rpc` | POST | JSON-RPC request (single or batch) |
| `/api/v1/events` | GET | Server-Sent Events stream (incoming messages) |
| `/api/v1/check` | GET | Health check (200 OK) |

### Other Transports

```bash
signal-cli -a +1234567890 daemon --tcp           # TCP :7583
signal-cli -a +1234567890 daemon --socket        # Unix socket ($XDG_RUNTIME_DIR/signal-cli/socket)
signal-cli -a +1234567890 jsonRpc                # stdin/stdout
signal-cli -a +1234567890 daemon --dbus          # D-Bus user bus
signal-cli -a +1234567890 daemon --http --socket --dbus  # multiple simultaneously
```

### Daemon Options

| Option | Description |
|--------|-------------|
| `--ignore-attachments` | Don't download attachments |
| `--ignore-stories` | Don't receive story messages |
| `--send-read-receipts` | Auto-send read receipts |
| `--receive-mode` | `on-start` (default), `on-connection`, or `manual` |

### Systemd Service

```ini
[Unit]
Description=signal-cli JSON-RPC daemon
After=network.target
[Service]
Type=simple
User=signal-cli
ExecStart=/usr/local/bin/signal-cli -a +1234567890 daemon --http 127.0.0.1:8080
Restart=on-failure
RestartSec=10
[Install]
WantedBy=multi-user.target
```

```bash
sudo systemctl daemon-reload && sudo systemctl enable --now signal-cli
```

## JSON-RPC API

### Protocol

Standard JSON-RPC 2.0. Each request is a single-line JSON object with a unique `id`.

```json
{"jsonrpc":"2.0","method":"send","params":{"recipient":["+0987654321"],"message":"Hello"},"id":"1"}
{"jsonrpc":"2.0","result":{"timestamp":1631458508784},"id":"1"}
```

Multi-account mode: include `"account":"+1234567890"` in params.

### Incoming Message Notification (SSE / stdout)

```json
{
  "jsonrpc": "2.0", "method": "receive",
  "params": { "envelope": {
    "source": "+1234567890", "sourceUuid": "a1b2c3d4-...", "sourceName": "Contact Name",
    "timestamp": 1631458508784,
    "dataMessage": { "message": "Hello!", "expiresInSeconds": 0, "attachments": [] }
  }}
}
```

### Key Methods

**Messaging**: `send` (recipient/groupId, message, attachments, mention, quoteTimestamp, editTimestamp, sticker, viewOnce, textStyle), `sendReaction` (emoji, targetAuthor, targetTimestamp, remove), `sendTyping`, `sendReceipt`, `remoteDelete`, `sendPollCreate`, `sendPollVote`

**Groups**: `updateGroup` (name, description, members, removeMember, admin, link, expiration), `quitGroup`, `joinGroup`, `listGroups`

**Account**: `register`/`verify`/`unregister`, `updateAccount`, `updateProfile`, `listContacts`/`listIdentities`/`listDevices`, `getUserStatus`, `block`/`unblock`, `startLink`/`finishLink`

### HTTP Examples

```bash
# Send a message
curl -s -X POST http://localhost:8080/api/v1/rpc \
  -H "Content-Type: application/json" \
  -d '{"jsonrpc":"2.0","method":"send","params":{"recipient":["+0987654321"],"message":"Hello"},"id":"1"}'

# Subscribe to incoming messages (SSE)
curl -N http://localhost:8080/api/v1/events

# Health check
curl http://localhost:8080/api/v1/check
```

## Messaging Features

```bash
# DM by phone number or username
signal-cli -a +1234567890 send -m "Hello" +0987654321
signal-cli -a +1234567890 send -m "Hello" u:username.000

# Group message
signal-cli -a +1234567890 send -m "Hello group" -g GROUP_ID_BASE64

# Pipe from stdin
echo "alert: disk full" | signal-cli -a +1234567890 send --message-from-stdin +0987654321

# Attachments (files, view-once, data URI)
signal-cli -a +1234567890 send -m "See attached" -a /path/to/file.pdf +0987654321
signal-cli -a +1234567890 send -m "" -a /path/to/photo.jpg --view-once +0987654321

# Reactions
signal-cli -a +1234567890 sendReaction -e "👍" -a +0987654321 -t 1631458508784 +0987654321
signal-cli -a +1234567890 sendReaction -e "👍" -a +0987654321 -t 1631458508784 -r +0987654321  # remove

# Typing indicators
signal-cli -a +1234567890 sendTyping +0987654321
signal-cli -a +1234567890 sendTyping -s +0987654321  # stop

# Mentions (UTF-16 code units: start:length:recipientNumber)
signal-cli -a +1234567890 send -m "Hi X!" --mention "3:1:+0987654321" -g GROUP_ID

# Quotes (reply)
signal-cli -a +1234567890 send -m "My reply" \
  --quote-timestamp 1631458508784 --quote-author +0987654321 --quote-message "Original" +0987654321

# Text styles (BOLD, ITALIC, SPOILER, STRIKETHROUGH, MONOSPACE)
signal-cli -a +1234567890 send -m "Something BIG!" --text-style "10:3:BOLD"

# Edit / remote delete
signal-cli -a +1234567890 send -m "Corrected" --edit-timestamp ORIGINAL_TIMESTAMP +0987654321
signal-cli -a +1234567890 remoteDelete -t TIMESTAMP +0987654321

# Polls
signal-cli -a +1234567890 sendPollCreate -q "Favorite color?" -o "Red" "Blue" "Green" +0987654321
signal-cli -a +1234567890 sendPollVote --poll-author +1234567890 --poll-timestamp TIMESTAMP -o 0 +0987654321
```

## Group Management

```bash
# Create / update
signal-cli -a +1234567890 updateGroup -n "Group Name" -m +0987654321 +1112223333
signal-cli -a +1234567890 updateGroup -g GROUP_ID -n "New Name" -d "Description" -e 3600

# Members
signal-cli -a +1234567890 updateGroup -g GROUP_ID -m +NEW_MEMBER
signal-cli -a +1234567890 updateGroup -g GROUP_ID -r +MEMBER_TO_REMOVE
signal-cli -a +1234567890 updateGroup -g GROUP_ID --admin +MEMBER
signal-cli -a +1234567890 updateGroup -g GROUP_ID --ban +MEMBER

# Permissions (every-member | only-admins)
signal-cli -a +1234567890 updateGroup -g GROUP_ID --set-permission-add-member only-admins
signal-cli -a +1234567890 updateGroup -g GROUP_ID --set-permission-send-messages only-admins

# Links
signal-cli -a +1234567890 updateGroup -g GROUP_ID --link enabled
signal-cli -a +1234567890 joinGroup --uri "https://signal.group/#..."

# Leave / list
signal-cli -a +1234567890 quitGroup -g GROUP_ID --delete
signal-cli -a +1234567890 listGroups -d -o json
```

## Access Control

signal-cli has no built-in allowlists — implement at the application layer by filtering on sender identifiers in received message envelopes.

**Recipient identifier types**: E.164 phone number (`+XXXXXXXXXXX`), ACI UUID (`a1b2c3d4-...`), PNI (`PNI:a1b2c3d4-...`), username (`u:username.NNN`).

```python
ALLOWED = {"+1234567890", "+0987654321"}

def handle_message(envelope):
    sender = envelope.get("sourceNumber", "")
    if sender not in ALLOWED:
        return  # silently ignore
    # process message...
```

### Blocking and Trust

```bash
signal-cli -a +1234567890 block +BLOCKED_NUMBER
signal-cli -a +1234567890 unblock +BLOCKED_NUMBER

# Trust management
signal-cli --trust-new-identities on-first-use   # default
signal-cli --trust-new-identities never           # manual verification only
signal-cli -a +1234567890 trust -v VERIFIED_SAFETY_NUMBER +0987654321
signal-cli -a +1234567890 listIdentities
```

## Privacy and Security

### Signal Protocol

| Component | Detail |
|-----------|--------|
| Key agreement | X3DH (Extended Triple Diffie-Hellman) with Curve25519 |
| Message encryption | Double Ratchet (forward secrecy + break-in recovery) |
| Symmetric cipher | AES-256-CBC |
| MAC | HMAC-SHA256 |
| Sealed sender | Hides sender identity from Signal servers |
| Contact discovery | SGX enclaves (private set intersection) |

### What Signal Servers Store / Don't Store

**Stores**: Phone number (hashed), push tokens, registration date, last connection date.

**Does NOT store**: Message content, contact lists, group memberships, profile data, who messages whom (sealed sender).

### Metadata Exposure

| Data | Visibility |
|------|------------|
| Message content | Never visible to server |
| Sender identity | Hidden via sealed sender |
| Recipient identity | Server knows delivery target |
| Timing | Server sees delivery timestamps |
| Group membership | Not stored server-side |

### Platform Comparison

| Aspect | Signal | SimpleX | Matrix | Telegram |
|--------|--------|---------|--------|----------|
| E2E default | Yes (all) | Yes (all) | No (opt-in) | No (opt-in, 1:1 only) |
| Server metadata | Minimal | None (stateless) | Full | Full |
| Sealed sender | Yes | N/A | No | No |
| Security audits | Independent, published | Independent, published | Varies | None published |
| Operator | Non-profit foundation | Open-source project | Foundation + companies | For-profit company |

### Key Storage

All cryptographic keys stored locally at `~/.local/share/signal-cli/data/+1234567890/account.db`. No private key material is ever sent to the server.

### Bot Security Model

1. **Treat all inbound messages as untrusted** — sanitize before passing to AI models or shell commands
2. **Application-level allowlists** — filter by E.164 phone number or UUID
3. **Command sandboxing** — bot commands should run in restricted environments
4. **Credential isolation** — never expose secrets to chat context or tool output
5. **Prompt injection defense** — scan inbound messages with `prompt-guard-helper.sh` before AI dispatch

Cross-reference: `tools/security/opsec.md`, `tools/credentials/gopass.md`, `tools/security/prompt-injection-defender.md`

## Configuration

```bash
# Data storage
# Default: $XDG_DATA_HOME/signal-cli/data/ or ~/.local/share/signal-cli/data/
signal-cli --config /custom/path ...

# Logging (with sensitive data scrubbed)
signal-cli --log-file /var/log/signal-cli.log --scrub-log -a +1234567890 daemon --http

# Database backup before upgrading (migrations prevent downgrade)
cp ~/.local/share/signal-cli/data/+1234567890/account.db \
   ~/.local/share/signal-cli/data/+1234567890/account.db.bak.$(date +%Y%m%d)
```

| Option | Description |
|--------|-------------|
| `--service-environment live` | Production Signal servers (default) |
| `--trust-new-identities` | `on-first-use` (default), `always`, `never` |
| `--disable-send-log` | Disable message resend log |

## Integration with aidevops

### Runner Dispatch Pattern

```text
Signal User → "!ai Review the auth module"
    → signal-cli daemon (HTTP :8080)
    → Bot Process: check allowlist → parse command → resolve entity → load context
    → runner-helper.sh dispatch
    → AI Session → Response
    → signal-cli send → Signal User
```

### Minimal Bot Example (Shell)

```bash
#!/usr/bin/env bash
# Requires: signal-cli daemon --http running on :8080, jq, curl
ACCOUNT="+1234567890"
ALLOWED="+0987654321"

curl -sN http://localhost:8080/api/v1/events | while read -r line; do
  data="${line#data:}"
  [[ -z "$data" || "$data" == "$line" ]] && continue

  sender=$(echo "$data" | jq -r '.params.envelope.sourceNumber // empty')
  message=$(echo "$data" | jq -r '.params.envelope.dataMessage.message // empty')
  [[ -z "$message" || "$sender" != "$ALLOWED" ]] && continue

  curl -s -X POST http://localhost:8080/api/v1/rpc \
    -H "Content-Type: application/json" \
    -d "{\"jsonrpc\":\"2.0\",\"method\":\"send\",\"params\":{\"recipient\":[\"$sender\"],\"message\":\"Echo: $message\"},\"id\":\"$(date +%s)\"}"
done
```

## Matterbridge Integration

Matterbridge does **not** natively support Signal. Two options:

**Option 1**: [signal-cli-rest-api](https://github.com/bbernhard/signal-cli-rest-api) wraps signal-cli in a REST API. Connect to Matterbridge via the [API gateway](https://github.com/42wim/matterbridge/wiki/API) with custom middleware.

**Option 2**: Write lightweight middleware that subscribes to signal-cli SSE events, forwards to Matterbridge API, polls for outbound messages, and sends via signal-cli JSON-RPC.

**Privacy Warning**: Bridging Signal to unencrypted platforms (Discord, Slack, IRC) breaks E2E encryption at the bridge boundary. The bridge host has access to all message content.

## Limitations

| Limitation | Detail |
|------------|--------|
| Phone number required | Must receive SMS or voice call at least once for verification |
| No multi-device as primary | Link signal-cli as secondary device via QR code to use alongside phone |
| Version expiry | Must be kept up-to-date; releases older than ~3 months may stop working |
| Rate limiting | Registration, sending, and other operations are rate-limited |
| No voice/video calls | Text messaging, attachments, and protocol-level features only |
| Single instance per number | Cannot run two signal-cli instances for the same account simultaneously |
| Database migrations | Upgrading may migrate SQLite DB, preventing downgrade — always backup first |
| Entropy requirement | Cryptographic operations require sufficient random entropy (`haveged` on idle systems) |

**Exit codes**: 1 = user-fixable error, 2 = unexpected error, 3 = server/IO error, 4 = untrusted key, 5 = rate limiting.

**Rate limit challenge**:

```bash
signal-cli -a +1234567890 submitRateLimitChallenge --challenge TOKEN \
  --captcha "signalcaptcha://..."
# CAPTCHA: https://signalcaptchas.org/challenge/generate.html
```

## Related

- `services/communications/simplex.md` — SimpleX Chat (zero-knowledge, no identifiers)
- `services/communications/matrix-bot.md` — Matrix bot for aidevops runner dispatch
- `services/communications/matterbridge.md` — Multi-platform chat bridge (40+ platforms)
- `tools/security/opsec.md` — Platform trust matrix, E2E status, metadata warnings
- `tools/security/prompt-injection-defender.md` — Prompt injection defense for chat bots
- `tools/credentials/gopass.md` — Secure credential storage
- Signal Protocol spec: https://signal.org/docs/
- signal-cli wiki: https://github.com/AsamK/signal-cli/wiki
- signal-cli-rest-api: https://github.com/bbernhard/signal-cli-rest-api
