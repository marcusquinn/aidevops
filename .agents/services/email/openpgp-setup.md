---
description: OpenPGP setup helper for email encryption - key generation, publishing, client integration, exchange workflows, and agent-assisted commands
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

# OpenPGP Setup Helper

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Purpose**: Practical OpenPGP for secure email across desktop, webmail, and terminal
- **Toolchain**: `gpg`, `keys.openpgp.org`, client integrations (Mailvelope, Thunderbird, Mutt)
- **Artifacts**: public key (`.asc`), encrypted private backup (`.asc`), revocation certificate
- **Related**: `services/email/email-security.md`, `tools/credentials/encryption-stack.md`

**Decision path:**

1. New identity? -> [Generate and Harden Keys](#generate-and-harden-keys)
2. Recipient discovery? -> [Publish and Discover Keys](#publish-and-discover-keys)
3. Client setup? -> [Client Integration](#client-integration)
4. Key exchange? -> [Key Exchange Workflows](#key-exchange-workflows)
5. AI-assisted commands? -> [Agent-Assisted Commands](#agent-assisted-commands)

<!-- AI-CONTEXT-END -->

## Operational Goal

OpenPGP requires three constraints simultaneously: (1) you control your private key and passphrase, (2) recipients can fetch your verified public key, (3) your mail client defaults to signing/encrypting when appropriate. Any failure degrades confidentiality and authenticity.

## Generate and Harden Keys

Create a modern, portable key with rotation discipline.

```bash
# Generate key pair (interactive)
gpg --full-generate-key
# Recommended: RSA 4096, 1-2y expiry, full legal/business identity + active email

# List keys and capture long key ID + fingerprint
gpg --list-secret-keys --keyid-format long
gpg --fingerprint your@email.com

# Export public key for sharing
gpg --armor --export your@email.com > publickey.asc

# Export private key for encrypted offline backup
gpg --armor --export-secret-keys your@email.com > privatekey.asc

# Generate revocation certificate immediately
gpg --output revoke-your-email.asc --gen-revoke your@email.com
```

**Hardening checklist:**

- Store `privatekey.asc` and `revoke-*.asc` in encrypted storage only (second offline backup recommended).
- Use subkeys for daily signing/encryption; keep primary key minimally used.
- Set calendar reminders 30 days before key expiration.

## Publish and Discover Keys

Publishing enables discovery; multi-channel distribution enables verification.

```bash
# Publish to verified keyserver
gpg --keyserver hkps://keys.openpgp.org --send-keys YOUR_LONG_KEY_ID

# Verify upload
gpg --keyserver hkps://keys.openpgp.org --search-keys your@email.com

# Refresh local keyring
gpg --keyserver hkps://keys.openpgp.org --refresh-keys
```

**Distribution channels** (use multiple for verification):

1. **Keyserver**: `keys.openpgp.org` for machine discovery.
2. **Direct**: attach `publickey.asc` in onboarding/security docs.
3. **Fingerprint**: publish in email signature, website contact page, team docs.
4. **WKD**: host at `/.well-known/openpgpkey/` on your domain (if controlled).

**Rotation and revocation:**

- Announce rotations with a message signed by the old key containing the new fingerprint.
- Keep old key active during overlap window to avoid delivery failures.
- If compromised: publish revocation immediately, notify trusted contacts via verified channels.

## Client Integration

### Mailvelope (browser extension)

1. Install from browser extension store.
2. Import private key (`privatekey.asc`) + public key (`publickey.asc`) in Mailvelope options.
3. Configure Display Name and sender email to match OpenPGP identity.
4. Enable integration for supported webmail domains (Gmail, Outlook Web, custom URLs).
5. Test: signed message to self, then signed+encrypted to a known recipient.

Keep private key import local to trusted devices. Prefer short passphrase cache timeout. Re-import after recipient key rotations.

### Thunderbird (built-in OpenPGP)

1. `Settings -> Account Settings -> End-to-End Encryption`.
2. Import or generate key.
3. Defaults: sign all outgoing, encrypt when recipient key available.
4. Validate: send signed mail to self, check signature status.

### Mutt (terminal)

Configure GPG hooks in `~/.muttrc`:

```muttrc
set pgp_autosign = yes
set pgp_autoencrypt = yes
set pgp_sign_as = 0xYOUR_LONG_KEY_ID
set crypt_use_gpgme = yes
set postpone_encrypt = yes   # prevents plaintext when recipient key missing
```

Test:

```bash
echo "OpenPGP test from mutt" | mutt -s "PGP test" -e "set crypt_autosign=yes; set crypt_autoencrypt=yes" recipient@example.com
```

## Key Exchange Workflows

### Workflow A: New recipient onboarding

1. Exchange fingerprints over a second channel (voice, Signal, in-person).
2. Import and verify each other's public keys.
3. Set trust only after fingerprint match via second channel.
4. Send signed-only test, then signed+encrypted after signature verification.

```bash
gpg --import recipient-publickey.asc
gpg --fingerprint recipient@example.com   # confirm out-of-band
gpg --edit-key recipient@example.com      # trust -> save

# Encrypt + sign test payload
echo "confidential test" | gpg --armor --encrypt --sign --recipient recipient@example.com
```

### Workflow B: Key rotation

1. Publish new key; keep old key active during migration window.
2. Send signed announcement from old key with new fingerprint.
3. Recipients confirm fingerprint over secondary channel.
4. Start signing with new key, deprecate old on schedule.

### Workflow C: Suspected compromise

1. Revoke compromised key using revocation certificate.
2. Publish revocation to keyserver.
3. Notify trusted contacts via verified channel.
4. Generate replacement key pair and repeat onboarding flow.

```bash
gpg --import revoke-your-email.asc
gpg --keyserver hkps://keys.openpgp.org --send-keys YOUR_LONG_KEY_ID
```

## Agent-Assisted Commands

Use the agent to draft safe commands and check config state. **Never paste secret values into AI chat** -- run commands in terminal, enter secrets at hidden prompts.

**Safe prompt examples:**

- "Generate a GPG key rotation checklist for `user@example.com` with 30-day overlap."
- "Draft `gpg` commands to export only my public key and fingerprint."
- "Generate Mutt troubleshooting steps for missing recipient public keys."

**Local wrapper pattern:**

```bash
# 1) Ask for command plan (no secrets in prompt)
opencode run --dir ~/Git/aidevops \
  "Draft OpenPGP onboarding commands for Thunderbird + Mutt using placeholder emails"

# 2) Execute locally with real identities
gpg --armor --export your@email.com > publickey.asc
gpg --fingerprint your@email.com
```

**Safety boundaries:** Do not ask the agent to display private key material, paste `privatekey.asc`/passphrases/tokenized URLs into chat, or request raw secret values. Ask for key names, fingerprints, and procedural steps only.

## Verification Matrix

| Check | Command or action | Expected result |
|-------|-------------------|-----------------|
| Key exists locally | `gpg --list-secret-keys --keyid-format long` | Secret key present for target identity |
| Fingerprint captured | `gpg --fingerprint your@email.com` | Fingerprint recorded in docs/contact card |
| Keyserver published | `gpg --keyserver hkps://keys.openpgp.org --search-keys your@email.com` | Key visible from public lookup |
| Thunderbird signing | Send signed test mail | Recipient sees valid signature |
| Mutt encryption | Send test mail with autosign+autoencrypt | Recipient decrypts and verifies signature |

## Common Failure Modes

- **Recipient cannot decrypt**: stale key; refresh and verify fingerprint.
- **Signature shows unknown**: key not trusted; verify fingerprint then assign trust.
- **Mutt sends plaintext**: recipient key missing; enforce `postpone_encrypt`, verify key presence.
- **Keyserver lookup fails**: network/keyserver issue or email verification not completed.
