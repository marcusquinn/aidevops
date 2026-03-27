---
description: Thunderbird email client integration — IMAP config generation, Sieve rule deployment, OpenPGP key import
mode: subagent
tools:
  read: true
  write: false
  edit: false
  bash: true
  glob: true
  grep: true
  webfetch: false
---

# Thunderbird Integration

<!-- AI-CONTEXT-START -->

**Helper**: `scripts/thunderbird-helper.sh` | **Providers**: `configs/email-providers.json` (19 providers)
**Autoconfig**: Mozilla ISPDB v1.1 XML | **Sieve**: ManageSieve (RFC 5804) via `sieve-connect`
**Key principle**: Host generated XML at `autoconfig.<domain>` for zero-config account setup.

<!-- AI-CONTEXT-END -->

## IMAP Config Generation

```bash
# From provider template
thunderbird-helper.sh gen-config --provider cloudron --email user@example.com
thunderbird-helper.sh gen-config --provider fastmail --email user@fastmail.com --output ~/tb-fastmail.xml

# Custom server settings
thunderbird-helper.sh gen-config \
  --imap-host mail.example.com --imap-port 993 \
  --smtp-host mail.example.com --smtp-port 465 \
  --email user@example.com --output ~/tb-custom.xml
```

Supported providers: Cloudron, Gmail, Google Workspace, Outlook, Microsoft 365, Proton Mail, Fastmail, mailbox.org, Tuta, Yahoo, Zoho, GMX, IONOS, Namecheap, mail.com, StartMail, Disroot, ChatMail, iCloud.

### Autoconfig XML Format

```xml
<?xml version="1.0" encoding="UTF-8"?>
<clientConfig version="1.1">
  <emailProvider id="example.com">
    <domain>example.com</domain>
    <displayName>Example Mail</displayName>
    <incomingServer type="imap">
      <hostname>mail.example.com</hostname>
      <port>993</port>
      <socketType>SSL</socketType>
      <authentication>password-cleartext</authentication>
      <username>%EMAILADDRESS%</username>
    </incomingServer>
    <outgoingServer type="smtp">
      <hostname>mail.example.com</hostname>
      <port>465</port>
      <socketType>SSL</socketType>
      <authentication>password-cleartext</authentication>
      <username>%EMAILADDRESS%</username>
    </outgoingServer>
  </emailProvider>
</clientConfig>
```

`%EMAILADDRESS%` is substituted automatically by Thunderbird.

### Auto-Discovery URL Order

```
1. https://autoconfig.<domain>/mail/config-v1.1.xml
2. https://<domain>/.well-known/autoconfig/mail/config-v1.1.xml
3. https://autoconfig.thunderbird.net/v1.1/<domain>
```

**Manual import** (if auto-discovery unavailable): Account Settings > Account Actions > Add Mail Account > Configure manually.

## Sieve Rule Deployment

Sieve (RFC 5228) filters execute server-side before delivery — works when Thunderbird is offline.

```bash
# Install sieve-connect (macOS)
brew install sieve-connect

# Deploy script (password via env var, never as argument)
IMAP_PASSWORD=$(gopass show -o mail/user@example.com) \
  thunderbird-helper.sh deploy-sieve \
    --server mail.example.com --user user@example.com \
    --script ~/.aidevops/sieve/sort-rules.sieve

# List active scripts
IMAP_PASSWORD=$(gopass show -o mail/user@example.com) \
  thunderbird-helper.sh list-sieve --server mail.example.com --user user@example.com
```

### Provider ManageSieve Support

| Provider | ManageSieve | Manual Upload Path |
|----------|-------------|-------------------|
| Cloudron | Yes (port 4190) | Admin > Mail > Sieve |
| Fastmail | No | Settings > Filters > Edit custom Sieve |
| mailbox.org | Yes (port 4190) | Settings > Filters |
| Dovecot (self-hosted) | Yes (port 4190) | `~/.dovecot.sieve` |
| Proton Mail | No | Settings > Filters > Add Sieve filter |
| Tuta | No | Not supported |
| Gmail | No | Not supported (use Gmail filters) |

When `sieve-connect` is unavailable, the helper prints the script with provider-specific upload instructions.

### Example Sieve Rules

See `services/email/email-mailbox.md` "Sieve Rule Patterns" for complete examples.

```sieve
require ["fileinto", "imap4flags"];

if address :domain :is "from" ["paypal.com", "stripe.com"] {
    if header :contains "subject" ["receipt", "invoice", "payment"] {
        fileinto "Transactions"; stop;
    }
}
if header :contains "subject" ["action required", "please review", "approval needed"] {
    addflag "$Task";
}
```

## OpenPGP Key Import

Thunderbird 78+ has built-in OpenPGP — no Enigmail required.

```bash
thunderbird-helper.sh openpgp-guide --email user@example.com
thunderbird-helper.sh openpgp-guide --email user@example.com --key-file ~/keys/user@example.com.asc
```

**Import steps**: Tools > Account Settings > End-To-End Encryption > Add Key > Import Personal OpenPGP Key (or "Use external key through GnuPG" for system keyring) > Use this key by default > enable sign unencrypted + encrypt drafts.

```bash
# Generate new key pair (RSA 4096, no expiry)
gpg --full-generate-key

# Export public key for sharing
gpg --armor --export user@example.com > user-public.asc

# Export private key for backup — run in terminal, NOT in AI chat
gpg --armor --export-secret-keys user@example.com > user-private.asc
```

**Keyring note**: Thunderbird maintains its own OpenPGP keyring, separate from system GnuPG. Use "external key through GnuPG" to share keys, or export/import manually.

## Account Setup Workflow

```bash
# 1. Generate config
thunderbird-helper.sh gen-config --provider cloudron --email user@example.com --output ~/tb-config.xml

# 2. Host at autoconfig.<domain> (optional, for auto-discovery)
# scp ~/tb-config.xml server:/var/www/autoconfig.example.com/mail/config-v1.1.xml

# 3. Thunderbird: Add Mail Account > enter email + password (auto-fetches config)

# 4. Deploy Sieve rules
IMAP_PASSWORD=$(gopass show -o mail/user@example.com) \
  thunderbird-helper.sh deploy-sieve --server mail.example.com --user user@example.com \
    --script ~/.aidevops/sieve/sort-rules.sieve

# 5. Import OpenPGP key
thunderbird-helper.sh openpgp-guide --email user@example.com
```

## Troubleshooting

| Symptom | Steps |
|---------|-------|
| Account setup fails | `thunderbird-helper.sh status` → `nc -zv mail.example.com 993` → `openssl s_client -connect mail.example.com:993 -quiet` → check OAuth2 providers need app passwords |
| Sieve rules not applying | `list-sieve` to verify active → check `require` statements → `sieve-test ~/.dovecot.sieve test-message.eml` → check rule order (first `stop` wins) |
| OpenPGP decryption fails | Verify private key imported (not just public) → check fingerprint in Tools > OpenPGP Key Manager → verify NTP sync → `gpg --list-secret-keys` for GnuPG integration |

## Related

- `services/email/email-mailbox.md` — Mailbox operations, Sieve patterns, IMAP/JMAP adapter
- `services/email/email-providers.md` — Provider config templates and privacy ratings
- `services/email/email-security.md` — SPF, DKIM, DMARC, encryption
- `scripts/thunderbird-helper.sh` — Config generation, Sieve deployment, OpenPGP guidance
- `scripts/email-mailbox-helper.sh` — IMAP mailbox operations (t1493)
- `scripts/email-sieve-helper.sh` — Sieve rule generator from triage patterns (t1503)
