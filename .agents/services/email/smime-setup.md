---
description: S/MIME certificate setup — acquisition (free and paid CAs), installation in Thunderbird/Apple Mail/Outlook, key backup and recovery, agent-assisted signing and encryption, cross-client compatibility
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

# S/MIME Certificate Setup

<!-- AI-CONTEXT-START -->

## Quick Reference

| | |
|---|---|
| **Standard** | S/MIME v3.2 (RFC 5751); PKCS#12 (`.p12`/`.pfx`) for import, PEM for inspection |
| **Free CA** | Actalis (1-year) — https://www.actalis.com/s-mime.aspx |
| **Paid CAs** | Sectigo (~$12/yr), DigiCert (~$25/yr), GlobalSign (~$59/yr) |
| **Verify cert** | `openssl x509 -in cert.pem -text -noout` |
| **Check expiry** | `openssl x509 -in cert.pem -enddate -noout` |
| **Related** | `services/email/email-security.md`, `tools/credentials/encryption-stack.md` |

**Decision:** Free/personal → Actalis; enterprise/compliance → DigiCert or GlobalSign.

<!-- AI-CONTEXT-END -->

## Certificate Acquisition

**Actalis (free):** https://www.actalis.com/s-mime.aspx → "Get a free email certificate" → verify email → download `.p12` → store password in gopass immediately.

**Self-signed (testing only):**

```bash
openssl req -x509 -newkey rsa:4096 -keyout smime-key.pem -out smime-cert.pem \
    -days 365 -nodes \
    -subj "/CN=Your Name/emailAddress=you@example.com" \
    -addext "subjectAltName=email:you@example.com" \
    -addext "keyUsage=digitalSignature,keyEncipherment" \
    -addext "extendedKeyUsage=emailProtection"
openssl pkcs12 -export -in smime-cert.pem -inkey smime-key.pem \
    -out smime-self-signed.p12 -name "Your Name (self-signed)" -passout pass:changeme
```

## Certificate Installation

### Apple Mail

```bash
security import smime-cert.p12 -k ~/Library/Keychains/login.keychain-db
# Mail detects it automatically — lock/checkmark icons appear in compose toolbar
```

**iOS:** Email `.p12` to yourself → tap attachment → Install → Settings → Mail → [account] → Advanced → S/MIME.

### Thunderbird

Settings → Account Settings → [account] → End-to-End Encryption → Manage S/MIME Certificates → Your Certificates → Import → select `.p12` → assign under "Personal certificate for digital signing".

```bash
certutil -L -d ~/.thunderbird/*.default-release/  # verify import
```

### Outlook

Double-click `.p12` → Certificate Import Wizard → Current User → Personal. Then: File → Options → Trust Center → Trust Center Settings → Email Security → Settings → choose certificate. Set Hash: SHA-256, Encryption: AES-256.

```powershell
Get-ChildItem Cert:\CurrentUser\My | Where-Object { $_.EnhancedKeyUsageList -match "Email" }
```

### Gmail / OWA

Gmail S/MIME requires Google Workspace Enterprise Standard+. OWA requires Microsoft 365 E3/E5 and only works in legacy Edge/IE. **Use desktop clients for S/MIME.**

## Key Backup and Recovery

**Critical:** losing your private key makes encrypted emails permanently unreadable. Do NOT delete expired certs — needed to decrypt historical emails.

```bash
# Export
security export -k ~/Library/Keychains/login.keychain-db -t identities -f pkcs12 -o smime-backup.p12
openssl pkcs12 -in smime-backup.p12 -noout -info  # verify
gopass insert email/smime-cert-password
# Restore
security import smime-backup.p12 -k ~/Library/Keychains/login.keychain-db  # macOS
pk12util -i smime-backup.p12 -d ~/.thunderbird/*.default-release/           # Thunderbird
```

## Agent-Assisted Signing and Encryption

```bash
# Sign
openssl smime -sign -in message.txt -signer cert.pem -inkey private-key.pem \
    -out signed.eml -text -md sha256
# Encrypt to recipient (requires their public cert)
openssl smime -encrypt -in message.txt -out encrypted.eml -aes256 recipient-cert.pem
# Decrypt
openssl smime -decrypt -in encrypted.eml -recip cert.pem -inkey private-key.pem -out decrypted.txt
# Verify signature and extract signer cert (use their-signed.eml to extract a contact's cert)
openssl smime -verify -in signed.eml -noverify -signer signer-cert.pem -out /dev/null 2>/dev/null
```

**Secret-safe usage:**

```bash
gopass insert email/smime-p12-password
SMIME_P12=~/.config/smime/cert.p12 \
SMIME_P12_PASS=$(gopass show -o email/smime-p12-password) \
  smime-helper.sh sign message.txt signed.eml
```

## Cross-Client Compatibility

Apple Mail, Thunderbird, and Outlook interoperate fully. Known issues:
- Outlook may wrap signed messages in `winmail.dat` (TNEF) — fix: set message format to "Internet Format (HTML)"
- Thunderbird 78+ rejects SHA-1 certs — use SHA-256+
- Actalis root CA trusted in macOS 12+; older systems need manual trust in Keychain Access
- Gmail S/MIME only works within Google Workspace — not for personal `@gmail.com`

**Algorithm recommendations:** SHA-256+ signatures, AES-256-CBC encryption, RSA 2048-bit minimum (4096 preferred). Avoid SHA-1, 3DES, RC2, 1024-bit keys.

## Related

- `services/email/email-security.md` — Email security overview
- `tools/credentials/encryption-stack.md` — gopass, SOPS, gocryptfs
- `tools/security/opsec.md` — Operational security and threat modeling
- `tools/security/tamper-evident-audit.md` — Audit logging for security events
