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

**Key differentiator**: Signal is the gold standard for mainstream encrypted messaging. E2E encrypted by default for all messages, sealed sender hides sender identity from the server, minimal metadata collection, phone number required but hidden from other users via usernames. Signal Foundation is a non-profit — no AI training on chat data. Independent security audits. 1B+ installs.

**When to use Signal over other platforms**:

| Criterion | Signal | SimpleX | Matrix |
|-----------|--------|---------|--------|
| User identifiers | Phone number (hidden via usernames) | None | `@user:server` |
| E2E encryption | Default, all messages | Default, all messages | Opt-in (rooms) |
| Server metadata | Minimal (sealed sender) | Stateless (memory only) | Full history stored |
| User base | 1B+ installs, mainstream | Niche, privacy-focused | Technical, federated |
| Bot ecosystem | signal-cli (JSON-RPC) | WebSocket API | Mature (SDK, bridges) |
| Group scalability | 1000 members | Experimental (1000+) | Production-grade |
| Best for | Mainstream secure comms, wide reach | Maximum privacy, zero-knowledge | Team collaboration, bridges |

<!-- AI-CONTEXT-END -->

## Architecture

```text
┌──────────────────────┐
│ Signal Mobile/Desktop │
│ (iOS, Android,        │
│  Linux, macOS, Win)   │
└──────────┬───────────┘
           │ Signal Protocol (E2E encrypted)
           │ Sealed sender (hides sender from server)
           │
┌──────────▼───────────┐
│ Signal Servers         │
│ (minimal metadata,     │
│  no message content)   │
└──────────┬───────────┘
           │
┌──────────▼───────────┐
│ signal-cli daemon      │
│ (JSON-RPC on :8080     │
│  or TCP :7583          │
│  or Unix socket)       │
└──────────┬───────────┘
           │ JSON-RPC 2.0 / SSE
           │
┌──────────▼───────────┐
│ Bot Process            │
│ (any language)         │
│                        │
│ ├─ Command router      │
│ ├─ Message handler     │
│ ├─ Access control      │
│ └─ aidevops dispatch   │
└────────────────────────┘
```

**Message flow**:

1. Sender's app encrypts message with Signal Protocol (Double Ratchet + X3DH)
2. Sealed sender wraps the encrypted message, hiding sender identity from server
3. Message delivered via Signal servers (no content access, minimal metadata)
4. signal-cli daemon receives and decrypts locally
5. JSON-RPC notification pushed to bot via SSE or stdout
6. Bot processes and responds via JSON-RPC `send` method

## Installation

### JVM Build (requires JRE 25+)

```bash
VERSION=$(curl -Ls -o /dev/null -w %{url_effective} \
  https://github.com/AsamK/signal-cli/releases/latest | sed -e 's/^.*\/v//')
curl -L -O "https://github.com/AsamK/signal-cli/releases/download/v${VERSION}/signal-cli-${VERSION}.tar.gz"
sudo tar xf "signal-cli-${VERSION}.tar.gz" -C /opt
sudo ln -sf "/opt/signal-cli-${VERSION}/bin/signal-cli" /usr/local/bin/

# Verify
signal-cli --version
```

### GraalVM Native Binary (no JRE required, experimental)

```bash
VERSION=$(curl -Ls -o /dev/null -w %{url_effective} \
  https://github.com/AsamK/signal-cli/releases/latest | sed -e 's/^.*\/v//')
curl -L -O "https://github.com/AsamK/signal-cli/releases/download/v${VERSION}/signal-cli-${VERSION}-Linux-native.tar.gz"
sudo tar xf "signal-cli-${VERSION}-Linux-native.tar.gz" -C /opt
sudo ln -sf /opt/signal-cli /usr/local/bin/

signal-cli --version
```

### Docker / OCI Container

```bash
# Official OCI image
docker pull ghcr.io/asamk/signal-cli

# Run daemon in HTTP mode
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
| FreeBSD | `net-im/signal-cli` |
| Alpine | `signal-cli` |
| Fedora/EPEL (RPM) | [signal-cli-rpm](https://github.com/pbiering/signal-cli-rpm) |

**Note**: No native Homebrew formula exists. On macOS, use the JVM or native binary install.

### Build from Source

```bash
git clone https://github.com/AsamK/signal-cli.git
cd signal-cli
./gradlew build
./gradlew installDist       # JVM wrapper in build/install/signal-cli/bin
./gradlew nativeCompile     # GraalVM native binary (experimental)
```

### Native Library Requirements

Bundled for: x86_64 Linux, Windows, macOS. Other architectures (e.g., aarch64) must provide `libsignal-client` native library — see the [wiki](https://github.com/AsamK/signal-cli/wiki/Provide-native-lib-for-libsignal).

## Registration

### SMS Verification

```bash
# Step 1: Request SMS code (usually requires CAPTCHA — see below)
signal-cli -a +1234567890 register

# Step 2: Enter verification code
signal-cli -a +1234567890 verify 123-456
```

### Voice Verification (landline numbers)

```bash
# Step 1: Attempt SMS first (will fail for landlines)
signal-cli -a +1234567890 register

# Step 2: Wait 60 seconds, then request voice call
signal-cli -a +1234567890 register --voice

# Step 3: Enter code from voice call
signal-cli -a +1234567890 verify 123-456
```

### CAPTCHA (almost always required)

Registration requires solving a CAPTCHA from the **same external IP** as signal-cli:

1. Open https://signalcaptchas.org/registration/generate.html in a browser
2. Solve the CAPTCHA
3. Right-click "Open Signal" link, copy the URL
4. Register with the token:

```bash
signal-cli -a +1234567890 register \
  --captcha "signalcaptcha://signal-recaptcha-v2.somecode.registration.somelongcode"
```

### QR Code Linking (link to existing Signal account)

This is the recommended approach for bots — keeps the primary phone active:

```bash
# Generate link URI (pipe to qrencode for QR display)
signal-cli link -n "aidevops-bot" | tee >(xargs -L 1 qrencode -t utf8)

# Scan the QR code with the primary Signal app:
# Settings > Linked Devices > Link New Device

# After linking, sync contacts and groups
signal-cli -a +1234567890 receive
```

**Limits**: Signal allows up to 5 linked devices per primary account.

### PIN Protection

```bash
# Verify with PIN if registration lock is set
signal-cli -a +1234567890 verify 123-456 --pin YOUR_PIN

# Set a registration lock PIN
signal-cli -a +1234567890 setPin YOUR_PIN

# Remove PIN
signal-cli -a +1234567890 removePin
```

## Daemon Mode

signal-cli runs as a persistent daemon exposing a JSON-RPC 2.0 interface. Multiple transport modes can run simultaneously.

### JSON-RPC over HTTP (recommended for bots)

```bash
# Single account
signal-cli -a +1234567890 daemon --http
# Listens on localhost:8080

# Custom bind address
signal-cli -a +1234567890 daemon --http 0.0.0.0:8080

# Multi-account
signal-cli daemon --http
```

**HTTP endpoints**:

| Endpoint | Method | Description |
|----------|--------|-------------|
| `/api/v1/rpc` | POST | JSON-RPC request (single or batch) |
| `/api/v1/events` | GET | Server-Sent Events stream (incoming messages) |
| `/api/v1/check` | GET | Health check (200 OK) |

### JSON-RPC over TCP

```bash
signal-cli -a +1234567890 daemon --tcp
# Default: localhost:7583

signal-cli -a +1234567890 daemon --tcp 0.0.0.0:7583
```

### JSON-RPC over Unix Socket

```bash
signal-cli -a +1234567890 daemon --socket
# Default: $XDG_RUNTIME_DIR/signal-cli/socket

signal-cli -a +1234567890 daemon --socket /path/to/custom.socket
```

### JSON-RPC over stdin/stdout

```bash
signal-cli -a +1234567890 jsonRpc
# Reads JSON-RPC from stdin, responds on stdout (one JSON object per line)
```

### D-Bus

```bash
signal-cli -a +1234567890 daemon --dbus        # User bus
signal-cli -a +1234567890 daemon --dbus-system  # System bus
```

D-Bus name: `org.asamk.Signal`. Object path: `/org/asamk/Signal` (multi-account: `/org/asamk/Signal/_<phonenumber>` where `+` becomes `_`).

### Multiple Transports Simultaneously

```bash
signal-cli -a +1234567890 daemon --http --socket --dbus
```

### Daemon Options

| Option | Description |
|--------|-------------|
| `--ignore-attachments` | Don't download attachments |
| `--ignore-stories` | Don't receive story messages |
| `--send-read-receipts` | Auto-send read receipts for received messages |
| `--no-receive-stdout` | Don't print received messages to stdout |
| `--receive-mode` | `on-start` (default), `on-connection`, or `manual` |

### Systemd Service

```ini
# /etc/systemd/system/signal-cli.service
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
sudo systemctl daemon-reload
sudo systemctl enable --now signal-cli
sudo journalctl -fu signal-cli
```

## JSON-RPC API

### Protocol

Standard JSON-RPC 2.0. Each request is a single-line JSON object with a unique `id`.

### Request Format

```json
{"jsonrpc":"2.0","method":"send","params":{"recipient":["+0987654321"],"message":"Hello"},"id":"1"}
```

### Response Format

```json
{"jsonrpc":"2.0","result":{"timestamp":1631458508784},"id":"1"}
```

### Error Format

```json
{"jsonrpc":"2.0","error":{"code":-32600,"message":"method field must be set","data":null},"id":null}
```

### Multi-Account Mode

When daemon started without `-a`, include `account` in params:

```json
{"jsonrpc":"2.0","method":"listGroups","params":{"account":"+1234567890"},"id":"1"}
```

### Incoming Message Notification (SSE / stdout)

```json
{
  "jsonrpc": "2.0",
  "method": "receive",
  "params": {
    "envelope": {
      "source": "+1234567890",
      "sourceNumber": "+1234567890",
      "sourceUuid": "a1b2c3d4-...",
      "sourceName": "Contact Name",
      "sourceDevice": 1,
      "timestamp": 1631458508784,
      "dataMessage": {
        "timestamp": 1631458508784,
        "message": "Hello!",
        "expiresInSeconds": 0,
        "viewOnce": false,
        "mentions": [],
        "attachments": [],
        "contacts": []
      }
    }
  }
}
```

### Key Methods

**Messaging:**

| Method | Description | Key Params |
|--------|-------------|------------|
| `send` | Send message | `recipient`, `message`, `attachments`, `groupId`, `mention`, `quoteTimestamp`, `editTimestamp`, `sticker`, `viewOnce`, `textStyle` |
| `sendReaction` | React to message | `emoji`, `targetAuthor`, `targetTimestamp`, `remove`, `recipient`/`groupId` |
| `sendTyping` | Typing indicator | `recipient`/`groupId`, `stop` |
| `sendReceipt` | Read/viewed receipt | `recipient`, `targetTimestamp`, `type` |
| `remoteDelete` | Delete sent message | `targetTimestamp`, `recipient`/`groupId` |
| `sendPollCreate` | Create poll | `question`, `options`, `recipient`/`groupId` |
| `sendPollVote` | Vote in poll | `pollAuthor`, `pollTimestamp`, `options` |

**Groups:**

| Method | Description | Key Params |
|--------|-------------|------------|
| `updateGroup` | Create/update group | `groupId`, `name`, `description`, `members`, `removeMember`, `admin`, `removeAdmin`, `link`, `setPermissionAddMember`, `setPermissionEditDetails`, `setPermissionSendMessages`, `expiration` |
| `quitGroup` | Leave group | `groupId`, `delete` |
| `joinGroup` | Join via link | `uri` |
| `listGroups` | List all groups | — |

**Account:**

| Method | Description |
|--------|-------------|
| `register` / `verify` / `unregister` | Registration lifecycle |
| `updateAccount` | Device name, username, discoverability |
| `updateProfile` | Name, about, emoji, avatar |
| `listContacts` / `listIdentities` / `listDevices` | Query account state |
| `getUserStatus` | Check if numbers are registered on Signal |
| `block` / `unblock` | Block/unblock contacts or groups |
| `startLink` / `finishLink` | Device linking (multi-account mode) |
| `subscribeReceive` / `unsubscribeReceive` | Manual receive mode control |

### HTTP Example (curl)

```bash
# Send a message
curl -s -X POST http://localhost:8080/api/v1/rpc \
  -H "Content-Type: application/json" \
  -d '{"jsonrpc":"2.0","method":"send","params":{"recipient":["+0987654321"],"message":"Hello from signal-cli"},"id":"1"}'

# List groups
curl -s -X POST http://localhost:8080/api/v1/rpc \
  -H "Content-Type: application/json" \
  -d '{"jsonrpc":"2.0","method":"listGroups","id":"2"}'

# Subscribe to incoming messages (SSE)
curl -N http://localhost:8080/api/v1/events

# Health check
curl http://localhost:8080/api/v1/check
```

## Messaging Features

### Send Messages

```bash
# DM by phone number
signal-cli -a +1234567890 send -m "Hello" +0987654321

# DM by username
signal-cli -a +1234567890 send -m "Hello" u:username.000

# Group message
signal-cli -a +1234567890 send -m "Hello group" -g GROUP_ID_BASE64

# Pipe from stdin
echo "alert: disk full" | signal-cli -a +1234567890 send --message-from-stdin +0987654321

# Note to self
signal-cli -a +1234567890 send -m "Reminder" --note-to-self
```

### Attachments

```bash
# Send files
signal-cli -a +1234567890 send -m "See attached" -a /path/to/file.pdf /path/to/image.png +0987654321

# View-once media
signal-cli -a +1234567890 send -m "" -a /path/to/photo.jpg --view-once +0987654321

# Data URI attachment
signal-cli -a +1234567890 send -a "data:image/png;filename=test.png;base64,..." +0987654321
```

### Reactions

```bash
# Add reaction
signal-cli -a +1234567890 sendReaction -e "👍" -a +0987654321 -t 1631458508784 +0987654321

# Remove reaction
signal-cli -a +1234567890 sendReaction -e "👍" -a +0987654321 -t 1631458508784 -r +0987654321
```

### Typing Indicators

```bash
signal-cli -a +1234567890 sendTyping +0987654321
signal-cli -a +1234567890 sendTyping -s +0987654321       # stop typing
signal-cli -a +1234567890 sendTyping -g GROUP_ID           # group typing
```

### Read/Viewed Receipts

```bash
signal-cli -a +1234567890 sendReceipt +0987654321 -t 1631458508784
signal-cli -a +1234567890 sendReceipt +0987654321 -t 1631458508784 --type viewed
```

### Mentions

```bash
# Format: start:length:recipientNumber (UTF-16 code units)
signal-cli -a +1234567890 send -m "Hi X!" --mention "3:1:+0987654321" -g GROUP_ID
```

### Quotes (Reply)

```bash
signal-cli -a +1234567890 send -m "My reply" \
  --quote-timestamp 1631458508784 \
  --quote-author +0987654321 \
  --quote-message "Original message" \
  +0987654321
```

### Stickers

```bash
signal-cli -a +1234567890 send --sticker "PACK_ID:STICKER_ID" +0987654321
```

### Text Styles

```bash
# Format: start:length:STYLE (BOLD, ITALIC, SPOILER, STRIKETHROUGH, MONOSPACE)
signal-cli -a +1234567890 send -m "Something BIG!" --text-style "10:3:BOLD"
```

### Edit Messages

```bash
signal-cli -a +1234567890 send -m "Corrected message" --edit-timestamp ORIGINAL_TIMESTAMP +0987654321
```

### Remote Delete

```bash
signal-cli -a +1234567890 remoteDelete -t TIMESTAMP +0987654321
```

### Link Previews

```bash
signal-cli -a +1234567890 send -m "Check https://example.com" \
  --preview-url "https://example.com" \
  --preview-title "Example" \
  --preview-description "Description" \
  --preview-image /path/to/img.jpg \
  +0987654321
```

### Polls

```bash
# Create poll
signal-cli -a +1234567890 sendPollCreate -q "Favorite color?" -o "Red" "Blue" "Green" +0987654321

# Vote (option index, 0-based)
signal-cli -a +1234567890 sendPollVote --poll-author +1234567890 --poll-timestamp TIMESTAMP -o 0 +0987654321
```

## Group Management

### Create Group

```bash
signal-cli -a +1234567890 updateGroup -n "Group Name" -m +0987654321 +1112223333
```

### Update Group

```bash
# Change name
signal-cli -a +1234567890 updateGroup -g GROUP_ID -n "New Name"

# Set description
signal-cli -a +1234567890 updateGroup -g GROUP_ID -d "Group description"

# Set avatar
signal-cli -a +1234567890 updateGroup -g GROUP_ID -a /path/to/avatar.jpg

# Add members
signal-cli -a +1234567890 updateGroup -g GROUP_ID -m +NEW_MEMBER

# Remove members
signal-cli -a +1234567890 updateGroup -g GROUP_ID -r +MEMBER_TO_REMOVE

# Set message expiration (seconds)
signal-cli -a +1234567890 updateGroup -g GROUP_ID -e 3600
```

### Admin Controls

```bash
# Promote to admin
signal-cli -a +1234567890 updateGroup -g GROUP_ID --admin +MEMBER

# Demote from admin
signal-cli -a +1234567890 updateGroup -g GROUP_ID --remove-admin +MEMBER

# Ban/unban members
signal-cli -a +1234567890 updateGroup -g GROUP_ID --ban +MEMBER
signal-cli -a +1234567890 updateGroup -g GROUP_ID --unban +MEMBER
```

### Permissions

```bash
# Who can add members: every-member | only-admins
signal-cli -a +1234567890 updateGroup -g GROUP_ID --set-permission-add-member only-admins

# Who can edit details: every-member | only-admins
signal-cli -a +1234567890 updateGroup -g GROUP_ID --set-permission-edit-details only-admins

# Announcement group (only admins can send): every-member | only-admins
signal-cli -a +1234567890 updateGroup -g GROUP_ID --set-permission-send-messages only-admins
```

### Group Links

```bash
# Enable group link
signal-cli -a +1234567890 updateGroup -g GROUP_ID --link enabled
signal-cli -a +1234567890 updateGroup -g GROUP_ID --link enabled-with-approval

# Disable / reset link
signal-cli -a +1234567890 updateGroup -g GROUP_ID --link disabled
signal-cli -a +1234567890 updateGroup -g GROUP_ID --reset-link

# Join via link
signal-cli -a +1234567890 joinGroup --uri "https://signal.group/#..."
```

### Leave Group

```bash
signal-cli -a +1234567890 quitGroup -g GROUP_ID
signal-cli -a +1234567890 quitGroup -g GROUP_ID --delete  # also delete local data
```

### List Groups

```bash
signal-cli -a +1234567890 listGroups
signal-cli -a +1234567890 listGroups -d       # detailed (includes members, invite link)
signal-cli -a +1234567890 listGroups -o json   # JSON output
```

## Access Control

signal-cli does **not** have built-in allowlists. Access control must be implemented at the application layer by filtering on sender identifiers in received message envelopes.

### Recipient Identifiers

signal-cli supports identifying recipients by:

| Type | Format | Example |
|------|--------|---------|
| Phone number (E.164) | `+XXXXXXXXXXX` | `+1234567890` |
| ACI (Account Identity UUID) | `a1b2c3d4-...` | `a1b2c3d4-e5f6-7890-abcd-ef1234567890` |
| PNI (Phone Number Identity) | `PNI:a1b2c3d4-...` | `PNI:a1b2c3d4-...` |
| Username | `u:username.NNN` | `u:alice.042` |

### Application-Level Allowlist Pattern

Filter incoming messages by sender phone number or UUID in the JSON-RPC envelope:

```python
# Example: Python allowlist filter
ALLOWED = {"+1234567890", "+0987654321"}

def handle_message(envelope):
    sender = envelope.get("sourceNumber", "")
    if sender not in ALLOWED:
        return  # silently ignore
    # process message...
```

### Blocking

```bash
# Block a contact (no messages received from them)
signal-cli -a +1234567890 block +BLOCKED_NUMBER

# Block a group
signal-cli -a +1234567890 block -g GROUP_ID

# Unblock
signal-cli -a +1234567890 unblock +BLOCKED_NUMBER
```

### Trust Management

```bash
# Trust on first use (default)
signal-cli --trust-new-identities on-first-use

# Always trust new keys (insecure — testing only)
signal-cli --trust-new-identities always

# Never trust without manual verification
signal-cli --trust-new-identities never

# Verify a specific contact's safety number
signal-cli -a +1234567890 trust -v VERIFIED_SAFETY_NUMBER +0987654321

# Trust all known keys for a contact (TOFU — insecure)
signal-cli -a +1234567890 trust -a +0987654321

# List identities and trust status
signal-cli -a +1234567890 listIdentities
```

## Privacy and Security Assessment

### Signal Protocol

| Component | Detail |
|-----------|--------|
| Key agreement | X3DH (Extended Triple Diffie-Hellman) with Curve25519 |
| Message encryption | Double Ratchet (forward secrecy + break-in recovery) |
| Symmetric cipher | AES-256-CBC |
| MAC | HMAC-SHA256 |
| Sealed sender | Hides sender identity from Signal servers |
| Contact discovery | SGX enclaves (private set intersection) |

### What Signal Servers Store

- Phone number (hashed) and push tokens
- Registration date
- Last connection date

### What Signal Servers Do NOT Store

- Message content (E2E encrypted)
- Contact lists
- Group memberships or metadata
- Profile data (encrypted client-side)
- Who messages whom (sealed sender)

### Metadata Exposure

| Data | Visibility |
|------|------------|
| Message content | Never visible to server |
| Sender identity | Hidden via sealed sender |
| Recipient identity | Server knows delivery target |
| Timing | Server sees delivery timestamps |
| IP address | Transient, in-transit only |
| Group membership | Not stored server-side |
| Push notifications | FCM/APNs see device received a notification (no content, no sender) |

### Comparison with Other Platforms

| Aspect | Signal | SimpleX | Matrix | Telegram |
|--------|--------|---------|--------|----------|
| E2E default | Yes (all) | Yes (all) | No (opt-in) | No (opt-in, 1:1 only) |
| User identifiers | Phone (hidden) | None | `@user:server` | Phone + username |
| Server metadata | Minimal | None (stateless) | Full | Full |
| Sealed sender | Yes | N/A (no IDs) | No | No |
| Open source | Client + server | Client + server | Client + server | Client only |
| Security audits | Independent, published | Independent, published | Varies | None published |
| Operator | Non-profit foundation | Open-source project | Foundation + companies | For-profit company |

### Key Storage

All cryptographic keys stored locally:

```text
~/.local/share/signal-cli/data/
├── +1234567890/
│   ├── account.db        # SQLite: identity keys, pre-keys, sessions, contacts, groups
│   └── ...
├── attachments/           # Downloaded attachments
└── avatars/               # Downloaded avatars
```

No private key material is ever sent to the server.

### Bot Security Model

When running bots that accept messages from untrusted users:

1. **Treat all inbound messages as untrusted input** — sanitize before passing to AI models or shell commands
2. **Implement application-level allowlists** — filter by E.164 phone number or UUID in message envelopes
3. **Command sandboxing** — bot commands from chat should run in restricted environments
4. **Credential isolation** — never expose secrets to chat context or tool output
5. **Leak detection** — scan outbound messages for credential patterns before sending
6. **Per-group permissions** — different groups can have different command access levels
7. **Prompt injection defense** — scan inbound messages with `prompt-guard-helper.sh` before AI dispatch

Cross-reference: `tools/security/opsec.md`, `tools/credentials/gopass.md`, `tools/security/prompt-injection-defender.md`

## Configuration

### Data Storage

```text
Default: $XDG_DATA_HOME/signal-cli/data/
Fallback: ~/.local/share/signal-cli/data/

# Override with:
signal-cli --config /custom/path ...
```

### Logging

```bash
# Log to file with sensitive data scrubbed
signal-cli --log-file /var/log/signal-cli.log --scrub-log -a +1234567890 daemon --http

# Verbose logging (repeat -v for more detail)
signal-cli -vvv -a +1234567890 daemon --http
```

### Database Backup

```bash
# Backup before upgrading (migrations prevent downgrade)
cp ~/.local/share/signal-cli/data/+1234567890/account.db \
   ~/.local/share/signal-cli/data/+1234567890/account.db.bak.$(date +%Y%m%d)
```

### Environment Options

| Option | Description |
|--------|-------------|
| `--service-environment live` | Production Signal servers (default) |
| `--service-environment staging` | Staging servers (testing) |
| `--trust-new-identities` | `on-first-use` (default), `always`, `never` |
| `--disable-send-log` | Disable message resend log |

## Integration with aidevops

### Runner Dispatch Pattern

```text
Signal User
    │
    │ "!ai Review the auth module"
    │
    ▼
signal-cli daemon (HTTP :8080)
    │
    │ SSE event → bot process
    │
    ▼
Bot Process (TypeScript/Python/Shell)
    │
    ├─ Check sender against allowlist
    ├─ Parse command prefix (!ai)
    ├─ Resolve entity (entity-helper.sh)
    ├─ Load context (entity profile + conversation history)
    │
    ▼
runner-helper.sh dispatch
    │
    ▼
AI Session → Response
    │
    ▼
signal-cli send → Signal User
```

### Minimal Bot Example (Shell)

```bash
#!/usr/bin/env bash
# Minimal signal-cli bot using HTTP daemon + SSE
# Requires: signal-cli daemon --http running on :8080, jq, curl

ACCOUNT="+1234567890"
ALLOWED="+0987654321"

# Listen for incoming messages via SSE
curl -sN http://localhost:8080/api/v1/events | while read -r line; do
  # SSE lines prefixed with "data:"
  data="${line#data:}"
  [[ -z "$data" || "$data" == "$line" ]] && continue

  sender=$(echo "$data" | jq -r '.params.envelope.sourceNumber // empty')
  message=$(echo "$data" | jq -r '.params.envelope.dataMessage.message // empty')

  [[ -z "$message" || "$sender" != "$ALLOWED" ]] && continue

  # Echo bot: reply with the same message
  curl -s -X POST http://localhost:8080/api/v1/rpc \
    -H "Content-Type: application/json" \
    -d "{\"jsonrpc\":\"2.0\",\"method\":\"send\",\"params\":{\"recipient\":[\"$sender\"],\"message\":\"Echo: $message\"},\"id\":\"$(date +%s)\"}"
done
```

### Components (planned)

| Component | File | Description |
|-----------|------|-------------|
| Subagent doc | `.agents/services/communications/signal.md` | This file |
| Helper script | `.agents/scripts/signal-helper.sh` | Registration, daemon management, send/receive |
| Bot framework | `.agents/scripts/signal-bot/` | TypeScript/Bun bot with command routing |
| Entity integration | `.agents/scripts/entity-helper.sh` | Identity resolution for Signal users |

## Matterbridge Integration

Matterbridge does **not** natively support Signal. Integration requires an intermediary adapter.

### Option 1: signal-cli-rest-api + Matterbridge API

[signal-cli-rest-api](https://github.com/bbernhard/signal-cli-rest-api) wraps signal-cli in a REST API. Connect it to Matterbridge via the [Matterbridge API gateway](https://github.com/42wim/matterbridge/wiki/API).

```text
Signal
  │
signal-cli daemon
  │
signal-cli-rest-api (Docker)
  │
Custom middleware (translates REST ↔ Matterbridge API)
  │
Matterbridge API (:4242)
  │
  ├── Matrix rooms
  ├── Discord channels
  ├── Telegram groups
  └── 40+ other platforms
```

### Option 2: Custom JSON-RPC ↔ Matterbridge API Bridge

Write a lightweight middleware that:

1. Subscribes to signal-cli SSE events (`GET /api/v1/events`)
2. Forwards messages to Matterbridge API (`POST /api/messages`)
3. Polls Matterbridge API for outbound messages
4. Sends them via signal-cli JSON-RPC (`POST /api/v1/rpc`)

### Privacy Warning

Bridging Signal to unencrypted platforms (Discord, Slack, IRC) breaks E2E encryption at the bridge boundary. Messages are decrypted by the bridge process and re-sent in plaintext (or re-encrypted by the destination platform). The bridge host has access to all message content.

See `services/communications/matterbridge.md` and `tools/security/opsec.md` for full implications.

## Limitations

### Phone Number Required

A phone number is mandatory for registration. Must be able to receive SMS or voice calls at least once for verification. Landline numbers work via voice verification.

### No Multi-Device for CLI as Primary

When signal-cli registers as a **primary** device, the phone loses its Signal session. To use both phone and CLI simultaneously, link signal-cli as a **secondary** device via QR code.

### Version Expiry

signal-cli must be kept up-to-date. Signal Server makes incompatible changes, and official clients expire after approximately 3 months. Releases older than 3 months may stop working.

### Rate Limiting

Signal Server enforces rate limits on registration, sending, and other operations. Rate limit challenges can be solved:

```bash
# Solve rate limit challenge
signal-cli -a +1234567890 submitRateLimitChallenge \
  --challenge TOKEN \
  --captcha "signalcaptcha://..."
```

CAPTCHA for rate limits: https://signalcaptchas.org/challenge/generate.html

### No Voice/Video Calls

signal-cli does not support voice or video calls. It handles text messaging, attachments, and protocol-level features only.

### No Story Creation

signal-cli can receive stories (or ignore them with `--ignore-stories`) but cannot create them.

### Single Instance Per Number

Cannot run two signal-cli instances for the same account simultaneously. Use daemon mode with multiple transport interfaces instead.

### Database Migrations

Upgrading signal-cli may migrate the SQLite database, preventing downgrade. Always backup before upgrading.

### Entropy Requirement

Cryptographic operations require sufficient random entropy. Embedded or idle systems may need `haveged` or similar entropy daemon.

### Exit Codes

| Code | Meaning |
|------|---------|
| 1 | User-fixable error |
| 2 | Unexpected error |
| 3 | Server or IO error |
| 4 | Sending failed (untrusted key) |
| 5 | Rate limiting error |

## Related

- `services/communications/simplex.md` — SimpleX Chat (zero-knowledge, no identifiers)
- `services/communications/matrix-bot.md` — Matrix bot for aidevops runner dispatch
- `services/communications/matterbridge.md` — Multi-platform chat bridge (40+ platforms)
- `tools/security/opsec.md` — Platform trust matrix, E2E status, metadata warnings
- `tools/security/prompt-injection-defender.md` — Prompt injection defense for chat bots
- `tools/credentials/gopass.md` — Secure credential storage
- `tools/ai-assistants/headless-dispatch.md` — Headless AI dispatch patterns
- Signal Protocol spec: https://signal.org/docs/
- signal-cli wiki: https://github.com/AsamK/signal-cli/wiki
- signal-cli-rest-api: https://github.com/bbernhard/signal-cli-rest-api
