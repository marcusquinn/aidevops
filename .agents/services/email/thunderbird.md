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

## Quick Reference

- **Helper**: `scripts/thunderbird-helper.sh` (config generation, Sieve deployment, OpenPGP guidance)
- **Providers**: `configs/email-providers.json` (19 providers with IMAP/SMTP settings)
- **Autoconfig format**: Mozilla ISPDB v1.1 XML (auto-discovered by Thunderbird on account setup)
- **Sieve deployment**: ManageSieve (RFC 5804) via `sieve-connect`
- **OpenPGP**: Built-in since Thunderbird 78 — no Enigmail required

**Key principle**: Thunderbird auto-discovers config from `autoconfig.<domain>` — host the generated XML there for zero-config account setup.

<!-- AI-CONTEXT-END -->

## IMAP Config Generation

Thunderbird uses Mozilla ISPDB autoconfig XML to auto-populate server settings during account setup. The helper generates this XML from provider templates or manual settings.

### From Provider Template

```bash
# Generate config using email-providers.json template
thunderbird-helper.sh gen-config --provider cloudron --email user@example.com

# Save to file
thunderbird-helper.sh gen-config \
  --provider fastmail \
  --email user@fastmail.com \
  --output ~/thunderbird-fastmail.xml
```

Supported providers (from `email-providers.json`): Cloudron, Gmail, Google Workspace, Outlook, Microsoft 365, Proton Mail, Fastmail, mailbox.org, Tuta, Yahoo, Zoho, GMX, IONOS, Namecheap, mail.com, StartMail, Disroot, ChatMail, iCloud.

### Manual Server Settings

```bash
# Custom server settings (no providers.json required)
thunderbird-helper.sh gen-config \
  --imap-host mail.example.com --imap-port 993 \
  --smtp-host mail.example.com --smtp-port 465 \
  --email user@example.com \
  --output ~/thunderbird-custom.xml
```

### Autoconfig XML Format

The generated XML follows the [Mozilla ISPDB format](https://wiki.mozilla.org/Thunderbird:Autoconfiguration:ConfigFileFormat):

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

`%EMAILADDRESS%` is a Thunderbird placeholder — it substitutes the user's email address automatically.

### Hosting for Auto-Discovery

Thunderbird checks these URLs in order during account setup:

```text
1. https://autoconfig.<domain>/mail/config-v1.1.xml
2. https://<domain>/.well-known/autoconfig/mail/config-v1.1.xml
3. https://autoconfig.thunderbird.net/v1.1/<domain>
```

Host the generated XML at option 1 or 2 for zero-config account setup — users only need to enter their email address and password.

### Manual Import

If auto-discovery is not available:

1. Open Thunderbird > Account Settings > Account Actions > Add Mail Account
2. Enter email address and password, click Continue
3. If auto-detection fails, click "Configure manually"
4. Enter the server settings from the generated XML

## Sieve Rule Deployment

Sieve (RFC 5228) is a server-side mail filtering language. Rules execute before delivery, so they work even when Thunderbird is not running.

### Prerequisites

```bash
# Install sieve-connect (macOS)
brew install sieve-connect

# Check status
thunderbird-helper.sh status
```

### Deploy Rules

```bash
# Deploy a Sieve script (password via env var, never as argument)
IMAP_PASSWORD=$(gopass show -o mail/user@example.com) \
  thunderbird-helper.sh deploy-sieve \
    --server mail.example.com \
    --user user@example.com \
    --script ~/.aidevops/sieve/sort-rules.sieve

# List active scripts
IMAP_PASSWORD=$(gopass show -o mail/user@example.com) \
  thunderbird-helper.sh list-sieve \
    --server mail.example.com \
    --user user@example.com
```

### Provider-Specific Deployment

| Provider | ManageSieve | Manual Upload |
|----------|-------------|---------------|
| Cloudron | Yes (port 4190) | Cloudron admin > Mail > Sieve |
| Fastmail | No | Settings > Filters > Edit custom Sieve |
| mailbox.org | Yes (port 4190) | Settings > Filters |
| Dovecot (self-hosted) | Yes (port 4190) | `~/.dovecot.sieve` |
| Proton Mail | No | Settings > Filters > Add Sieve filter |
| Tuta | No | Not supported |
| Gmail | No | Not supported (use Gmail filters) |

When `sieve-connect` is not available, the helper prints the script content with provider-specific manual upload instructions.

### Example Sieve Rules

See `services/email/email-mailbox.md` "Sieve Rule Patterns" for complete examples. Key patterns:

```sieve
require ["fileinto", "imap4flags"];

# Sort transactions to Transactions folder
if address :domain :is "from" ["paypal.com", "stripe.com"] {
    if header :contains "subject" ["receipt", "invoice", "payment"] {
        fileinto "Transactions";
        stop;
    }
}

# Flag action-required messages
if header :contains "subject" ["action required", "please review", "approval needed"] {
    addflag "$Task";
}
```

## OpenPGP Key Import

Thunderbird 78+ has built-in OpenPGP support — no Enigmail plugin required.

### Import Guide

```bash
# Step-by-step guidance (prints to terminal)
thunderbird-helper.sh openpgp-guide --email user@example.com

# With key file (shows fingerprint, includes file path in instructions)
thunderbird-helper.sh openpgp-guide \
  --email user@example.com \
  --key-file ~/keys/user@example.com.asc
```

### Import Steps (Summary)

1. **Tools > Account Settings > End-To-End Encryption**
2. Click **"Add Key..."**
3. Choose:
   - **"Import a Personal OpenPGP Key"** — for .asc/.gpg files
   - **"Use your external key through GnuPG"** — to use system keyring
4. Select the key and click **"Use this key by default"**
5. Configure encryption behaviour (sign unencrypted: ON, encrypt drafts: ON)
6. Optionally publish public key to keys.openpgp.org

### Key Generation (if needed)

```bash
# Generate a new key pair
gpg --full-generate-key
# Choose: RSA and RSA, 4096 bits, no expiry (or 2 years)
# Enter: Real Name, Email Address, Passphrase

# Export public key for sharing
gpg --armor --export user@example.com > user-public.asc

# Export private key for backup (store securely, never share)
# WARNING: Run this in your terminal, not in AI chat
gpg --armor --export-secret-keys user@example.com > user-private.asc
```

### Thunderbird vs System GnuPG

Thunderbird maintains its own OpenPGP keyring, separate from the system GnuPG keyring. Keys imported into Thunderbird are not automatically available to `gpg` CLI, and vice versa.

To use the same key in both:

1. Import into Thunderbird via "Use your external key through GnuPG" (reads system keyring)
2. Or export from Thunderbird and import into system GnuPG

## Account Setup Workflow

Complete workflow for a new Thunderbird account:

```bash
# 1. Generate autoconfig XML
thunderbird-helper.sh gen-config \
  --provider cloudron \
  --email user@example.com \
  --output ~/thunderbird-config.xml

# 2. Review the generated config
cat ~/thunderbird-config.xml

# 3. Host at autoconfig.<domain> (optional, for auto-discovery)
# scp ~/thunderbird-config.xml server:/var/www/autoconfig.example.com/mail/config-v1.1.xml

# 4. In Thunderbird: Add Mail Account > enter email + password
# Thunderbird auto-fetches config from autoconfig.example.com

# 5. Deploy Sieve rules (after account is set up)
IMAP_PASSWORD=$(gopass show -o mail/user@example.com) \
  thunderbird-helper.sh deploy-sieve \
    --server mail.example.com \
    --user user@example.com \
    --script ~/.aidevops/sieve/sort-rules.sieve

# 6. Import OpenPGP key
thunderbird-helper.sh openpgp-guide --email user@example.com
```

## Troubleshooting

### Account Setup Fails

1. Check server settings: `thunderbird-helper.sh status`
2. Verify IMAP/SMTP ports are open: `nc -zv mail.example.com 993`
3. Test IMAP connection: `openssl s_client -connect mail.example.com:993 -quiet`
4. Check auth method — OAuth2 providers (Gmail, Outlook) require app passwords or OAuth flow

### Sieve Rules Not Applying

1. Verify script is active: `thunderbird-helper.sh list-sieve --server ... --user ...`
2. Check `require` statements include all needed extensions
3. Test with `sieve-test` (Dovecot): `sieve-test ~/.dovecot.sieve test-message.eml`
4. Check rule order — first matching rule with `stop` wins

### OpenPGP Decryption Fails

1. Verify private key is imported (not just public key)
2. Check key fingerprint matches: Tools > OpenPGP Key Manager
3. Ensure system clock is accurate (NTP sync) — signature validation is time-sensitive
4. For GnuPG integration: verify `gpg --list-secret-keys` shows the key

## Related

- `services/email/email-mailbox.md` — Mailbox operations, Sieve patterns, IMAP/JMAP adapter
- `services/email/email-providers.md` — Provider config templates and privacy ratings
- `services/email/email-security.md` — SPF, DKIM, DMARC, encryption
- `scripts/thunderbird-helper.sh` — Helper script (config generation, Sieve deployment, OpenPGP guidance)
- `scripts/email-mailbox-helper.sh` — IMAP mailbox operations (t1493)
- `scripts/email-sieve-helper.sh` — Sieve rule generator from triage patterns (t1503)
