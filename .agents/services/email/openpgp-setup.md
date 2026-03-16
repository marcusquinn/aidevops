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

- **Purpose**: Set up practical OpenPGP for secure email across desktop, webmail, and terminal workflows
- **Core toolchain**: `gpg`, keyserver (`keys.openpgp.org`), client integrations (Mailvelope, Thunderbird, Mutt)
- **Output artifacts**: public key (`.asc`), encrypted private backup (`.asc`), revocation certificate
- **Related**: `services/email/email-security.md`, `tools/credentials/encryption-stack.md`

**Decision path:**

1. Need a new identity? -> [Generate and Harden Keys](#generate-and-harden-keys)
2. Need recipient discovery? -> [Publish and Discover Public Keys](#publish-and-discover-public-keys)
3. Need client setup? -> [Client Integration](#client-integration)
4. Need sharing guidance? -> [Public Key Distribution Guidance](#public-key-distribution-guidance)
5. Need key exchange process? -> [Key Exchange Workflows](#key-exchange-workflows)
6. Need AI-assisted command generation? -> [Agent-Assisted Encryption Commands](#agent-assisted-encryption-commands)

<!-- AI-CONTEXT-END -->

## Operational Goal

OpenPGP is only useful when three constraints hold at the same time:

1. You control your private key and passphrase.
2. Recipients can reliably fetch your verified public key.
3. Your mail client defaults to signing and encrypting when appropriate.

If any one of these fails, confidentiality and authenticity degrade.

## Generate and Harden Keys

Create a modern key that is portable across clients and easy to rotate.

```bash
# Generate key pair (interactive)
gpg --full-generate-key

# Recommended selections:
# - Algorithm: (1) RSA and RSA
# - Key size: 4096
# - Expiry: 1y or 2y (forces rotation discipline)
# - User ID: full legal/business identity + active email

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

### Hardening Checklist

- Store `privatekey.asc` and `revoke-*.asc` in encrypted storage only.
- Keep a second offline backup (for example, encrypted USB in a secure location).
- Use subkeys for daily signing/encryption and keep the primary key minimally used.
- Set calendar reminders 30 days before key expiration.

## Publish and Discover Public Keys

Publishing makes your key discoverable; verification makes it trustworthy.

```bash
# Send your public key to the main verified keyserver
gpg --keyserver hkps://keys.openpgp.org --send-keys YOUR_LONG_KEY_ID

# Verify upload by searching your email address
gpg --keyserver hkps://keys.openpgp.org --search-keys your@email.com

# Refresh local keyring from keyserver
gpg --keyserver hkps://keys.openpgp.org --refresh-keys
```

Optional distribution channels:

- Attach `publickey.asc` to onboarding documentation.
- Host at `/.well-known/openpgpkey/` on your domain.
- Publish fingerprint in email signature, website contact page, and team docs.

## Client Integration

### Mailvelope (browser extension)

1. Install Mailvelope from the browser extension store for your browser.
2. Open Mailvelope options and import your private key (`privatekey.asc`) plus public key (`publickey.asc`).
3. Configure the Display Name and sender email to match the OpenPGP identity.
4. Enable Mailvelope integration for supported webmail domains (for example Gmail, Outlook Web, or custom webmail URLs).
5. Compose a signed test message to yourself, then send a signed+encrypted message to a recipient with a known public key.

Operational notes:

- Keep private key import local to trusted devices only.
- Prefer passphrase caching with short timeout instead of no passphrase prompts.
- Re-import updated public keys after recipient key rotations.

### Thunderbird (built-in OpenPGP)

1. `Settings -> Account Settings -> End-to-End Encryption`.
2. Add key by import or generate from Thunderbird.
3. Set defaults: sign all outgoing mail, encrypt when recipient key is available.
4. Validate by sending a signed mail to yourself and checking signature status.

### Mutt (terminal workflow)

Install Mutt and configure GPG hooks in `~/.muttrc`:

```muttrc
set pgp_autosign = yes
set pgp_autoencrypt = yes
set pgp_sign_as = 0xYOUR_LONG_KEY_ID
set crypt_use_gpgme = yes

# Use this when recipient keys are missing instead of sending plaintext by mistake
set postpone_encrypt = yes
```

Validation command:

```bash
# Send a signed+encrypted test message through mutt
echo "OpenPGP test from mutt" | mutt -s "PGP test" -e "set crypt_autosign=yes; set crypt_autoencrypt=yes" recipient@example.com
```

## Public Key Distribution Guidance

Use more than one channel so recipients can both fetch and verify your key.

### Recommended distribution stack

1. Publish to keyserver: `keys.openpgp.org` for machine discovery.
2. Attach `publickey.asc` in onboarding/security docs for direct import.
3. Publish the full fingerprint in email signature, website contact page, and support docs.
4. If you control a domain, host OpenPGP WKD under `/.well-known/openpgpkey/`.

### Verification protocol for recipients

1. Recipient fetches key from keyserver or provided `.asc` file.
2. Recipient compares fingerprint against a second channel (voice call, Signal, in-person, or verified website).
3. Recipient imports and trusts key only after fingerprint match.
4. First exchange is signed-only; move to signed+encrypted after signature checks pass.

### Rotation and revocation distribution

- Announce key rotations with a message signed by the old key containing the new fingerprint.
- Keep old key active during overlap window to avoid delivery failures.
- If compromised, publish revocation immediately and notify trusted contacts via verified channels.

## Key Exchange Workflows

### Workflow A: New recipient onboarding

1. Exchange fingerprints over a second channel (voice call, Signal, in-person).
2. Import each other's public keys.
3. Verify fingerprint before setting trust.
4. Send signed-only test message.
5. Send signed+encrypted message after signature verification succeeds.

```bash
# Import recipient key
gpg --import recipient-publickey.asc

# Verify fingerprint (out-of-band confirmation required)
gpg --fingerprint recipient@example.com

# Optionally mark trust after verification
gpg --edit-key recipient@example.com
# then use: trust -> save

# Encrypt + sign test payload
echo "confidential test" | gpg --armor --encrypt --sign --recipient recipient@example.com
```

### Workflow B: Rotating your key

1. Publish new key and keep old key active during migration window.
2. Send signed announcement from old key containing new fingerprint.
3. Ask recipients to confirm fingerprint over secondary channel.
4. Start signing with new key, then deprecate old key on schedule.

### Workflow C: Suspected compromise

1. Revoke compromised key using revocation certificate.
2. Publish revocation to keyserver.
3. Notify trusted contacts using an already verified channel.
4. Generate replacement key pair and repeat onboarding flow.

```bash
# Import and publish revocation certificate
gpg --import revoke-your-email.asc
gpg --keyserver hkps://keys.openpgp.org --send-keys YOUR_LONG_KEY_ID
```

## Agent-Assisted Encryption Commands

Use the agent to draft safe commands and check config state, but keep secret values out of chat transcripts.

WARNING: Never paste secret values into AI chat. Run commands in your terminal and enter secrets at hidden prompts.

### Safe prompts for command generation

- "Generate a GPG key rotation checklist for `user@example.com` with 30-day overlap."
- "Draft `gpg` commands to export only my public key and fingerprint."
- "Generate Mutt troubleshooting steps for missing recipient public keys."

### Local assistant wrapper pattern

```bash
# 1) Ask for command plan (no secrets in prompt)
opencode run --dir ~/Git/aidevops \
  "Draft OpenPGP onboarding commands for Thunderbird + Mutt using placeholder emails"

# 2) Execute commands locally with real identities in terminal only
gpg --armor --export your@email.com > publickey.asc
gpg --fingerprint your@email.com
```

### Safety boundaries for agent assistance

- Do not ask the agent to display private key material.
- Do not paste `privatekey.asc`, passphrases, or tokenized URLs into chat.
- Ask for key names/fingerprints and procedural steps, not raw secret values.

## Verification Matrix

| Check | Command or action | Expected result |
|------|--------------------|-----------------|
| Key exists locally | `gpg --list-secret-keys --keyid-format long` | Secret key present for target identity |
| Fingerprint captured | `gpg --fingerprint your@email.com` | Fingerprint recorded in docs/contact card |
| Keyserver published | `gpg --keyserver hkps://keys.openpgp.org --search-keys your@email.com` | Key visible from public lookup |
| Thunderbird signing | Send signed test mail | Recipient sees valid signature |
| Mutt encryption | Send test mail with autosign+autoencrypt | Recipient decrypts and verifies signature |

## Common Failure Modes

- **Can encrypt but recipient cannot decrypt**: recipient is using stale key; refresh and verify fingerprint.
- **Signature shows unknown**: key not trusted yet; verify fingerprint then assign trust.
- **Mutt sends plaintext unexpectedly**: recipient key missing; enforce `postpone_encrypt` and verify recipient key presence.
- **Keyserver lookup fails**: temporary network/keyserver issue or email verification not completed at keyserver.
