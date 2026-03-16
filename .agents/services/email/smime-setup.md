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

# S/MIME Certificate Setup

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Purpose**: End-to-end email encryption and digital signatures using X.509 certificates
- **Standard**: S/MIME v3.2 (RFC 5751), certificates per RFC 5280
- **Key format**: PKCS#12 (`.p12` / `.pfx`) for import; PEM (`.pem`, `.crt`) for inspection
- **Free CA**: Actalis (1-year personal cert, no cost)
- **Paid CAs**: Sectigo, DigiCert, GlobalSign, Entrust
- **Verification**: `openssl x509 -in cert.pem -text -noout`
- **Related**: `services/email/email-security.md` (overview), `tools/credentials/encryption-stack.md`

**Decision tree:**

1. Need free certificate? → [Actalis](#actalis-free) or [Certum](#certum-free)
2. Need enterprise/compliance cert? → [Paid CAs](#paid-certificate-authorities)
3. Installing in Apple Mail? → [Apple Mail](#apple-mail-macos)
4. Installing in Thunderbird? → [Thunderbird](#thunderbird)
5. Installing in Outlook? → [Outlook](#outlook-desktop)
6. Need to back up keys? → [Key Backup and Recovery](#key-backup-and-recovery)
7. Automating sign/encrypt? → [Agent-Assisted Commands](#agent-assisted-signing-and-encryption)
8. Sending to mixed clients? → [Cross-Client Compatibility](#cross-client-compatibility)

<!-- AI-CONTEXT-END -->

## What S/MIME Provides

S/MIME (Secure/Multipurpose Internet Mail Extensions) adds two capabilities to email:

| Capability | What it does | What it proves |
|------------|-------------|----------------|
| **Digital signature** | Signs outbound email with your private key | Recipient can verify the email came from you and was not tampered with |
| **Encryption** | Encrypts email body using recipient's public key | Only the recipient can decrypt and read the content |

**What S/MIME does NOT protect:**

- Email metadata: `To:`, `From:`, `Subject:`, `Date:`, server routing headers — all visible in transit
- Attachments are encrypted only if the email client includes them in the encrypted body (most do)
- Server-side storage: once decrypted by the recipient's client, the plaintext may be stored on their server

For metadata protection, use a privacy-focused provider (Proton Mail, Tutanota) in addition to S/MIME.

## Certificate Acquisition

### Certificate Types

| Type | Validation | Use case |
|------|-----------|---------|
| **Class 1 / Personal** | Email address only | Personal use, basic signing |
| **Class 2 / Individual** | Email + identity documents | Professional use, higher trust |
| **Class 3 / Enterprise** | Organisation vetting | Corporate compliance, regulated industries |

For most personal and small-business use, Class 1 (email-validated) is sufficient.

### Free Certificate Authorities

#### Actalis (Free)

[Actalis](https://www.actalis.com/s-mime.aspx) is an Italian CA offering free 1-year S/MIME certificates. No credit card required.

**Process:**

1. Go to `https://www.actalis.com/s-mime.aspx`
2. Click "Get a free email certificate"
3. Enter your email address and complete the form
4. Verify your email address via the confirmation link
5. Download the `.p12` file — note the password shown on screen (you will need it for import)
6. Store the `.p12` and password in your password manager immediately

**Limitations:**

- 1-year validity — must renew annually
- Class 1 only (email validation, no identity verification)
- Certificate contains your email address but not your full name (unless you provide it)

#### Certum (Free)

[Certum](https://www.certum.eu/en/cert_offer_en/open-source-code-signing/) offers free S/MIME for open-source contributors. For general use, their paid tiers start at ~€15/year.

### Paid Certificate Authorities

| Provider | Product | Cost (approx) | Validity | Notes |
|----------|---------|--------------|---------|-------|
| [Sectigo](https://www.sectigo.com/ssl-certificates-tls/email-smime-certificate) | Personal Email | ~$12/year | 1–3 years | Formerly Comodo; widely trusted |
| [DigiCert](https://www.digicert.com/tls-ssl/client-certificates) | Client Certificate | ~$25/year | 1–3 years | Enterprise-grade; AATL member |
| [GlobalSign](https://www.globalsign.com/en/personal-sign/) | PersonalSign | ~$59/year | 1–3 years | Strong enterprise trust chain |
| [Entrust](https://www.entrust.com/digital-security/certificate-solutions/products/digital-signing/email-certificates) | Email Certificate | ~$30/year | 1–2 years | Common in regulated industries |
| [Comodo/Sectigo via Namecheap](https://www.namecheap.com/security/ssl-certificates/comodo/positivessl-multi-domain/) | Reseller | ~$8/year | 1 year | Cheaper reseller pricing |

**Choosing a CA:**

- For personal use: Actalis (free) or Sectigo (~$12/year)
- For legal/compliance: DigiCert or GlobalSign (broader trust store inclusion)
- For enterprise deployment: DigiCert or Entrust (volume licensing, LDAP/AD integration)
- For regulated industries (healthcare, finance): check whether your compliance framework specifies a CA

### Self-Signed Certificates (Development/Testing Only)

Self-signed certificates work for testing but will show trust warnings in recipients' clients. Do not use in production.

```bash
# Generate a self-signed S/MIME certificate (testing only)
openssl req -x509 -newkey rsa:4096 -keyout smime-key.pem -out smime-cert.pem \
    -days 365 -nodes \
    -subj "/CN=Your Name/emailAddress=you@example.com" \
    -addext "subjectAltName=email:you@example.com" \
    -addext "keyUsage=digitalSignature,keyEncipherment" \
    -addext "extendedKeyUsage=emailProtection"

# Bundle into PKCS#12 for import
openssl pkcs12 -export \
    -in smime-cert.pem \
    -inkey smime-key.pem \
    -out smime-self-signed.p12 \
    -name "Your Name (self-signed)" \
    -passout pass:changeme
```

## Certificate Installation

### Apple Mail (macOS)

**Requirements:** macOS 10.12+, certificate in `.p12` format

**Steps:**

1. **Import into Keychain:**

   ```bash
   # Double-click the .p12 file, or import via command line:
   security import smime-cert.p12 -k ~/Library/Keychains/login.keychain-db
   # Enter the certificate password when prompted
   ```

2. **Verify import:**

   ```bash
   # List S/MIME certificates in login keychain
   security find-certificate -a -c "your@email.com" ~/Library/Keychains/login.keychain-db
   ```

3. **Configure in Mail:**
   - Open Mail → Settings (⌘,) → Accounts → select your account
   - No manual configuration needed — Mail detects the certificate automatically
   - When composing, a lock icon (encrypt) and checkmark icon (sign) appear in the toolbar

4. **Set defaults:**
   - Mail → Settings → Accounts → [account] → Security tab (if visible)
   - Or: compose a new email and use the toolbar icons to set per-message preferences

**iOS (iPhone/iPad):**

1. Email the `.p12` file to yourself (or use AirDrop)
2. Tap the attachment → "Install" → enter the certificate password
3. Settings → General → VPN & Device Management → [certificate] → Install
4. Settings → Mail → [account] → Account → Advanced → S/MIME → enable signing/encryption

### Thunderbird

**Requirements:** Thunderbird 78+ (built-in OpenPGP and S/MIME support; no Enigmail needed)

**Steps:**

1. **Open certificate manager:**
   - Settings → Account Settings → [your account] → End-to-End Encryption
   - Click "Manage S/MIME Certificates"

2. **Import the certificate:**
   - Your Certificates tab → Import
   - Select your `.p12` file → enter the password

3. **Assign to account:**
   - Back in End-to-End Encryption settings
   - Under "S/MIME", click the dropdown next to "Personal certificate for digital signing"
   - Select your imported certificate
   - Optionally set the same certificate for encryption

4. **Set defaults:**
   - "Sign unencrypted messages by default" — recommended for all outbound mail
   - "Require encryption by default" — only if all your recipients have S/MIME certs

5. **Verify:**

   ```bash
   # Thunderbird stores certificates in its profile NSS database
   # List with certutil (part of nss-tools / libnss3-tools)
   certutil -L -d ~/.thunderbird/*.default-release/
   ```

### Outlook (Desktop)

**Requirements:** Outlook 2016+ or Microsoft 365 desktop app

**Steps:**

1. **Import certificate into Windows Certificate Store:**
   - Double-click the `.p12` file → Certificate Import Wizard
   - Store location: Current User → Personal
   - Enter the certificate password
   - Let Windows auto-select the certificate store

2. **Configure in Outlook:**
   - File → Options → Trust Center → Trust Center Settings
   - Email Security tab
   - Under "Encrypted email", click "Settings"
   - Signing Certificate: click "Choose" → select your certificate
   - Encryption Certificate: same certificate (or a separate one if required)
   - Hash Algorithm: SHA-256 (do not use SHA-1 — deprecated)
   - Encryption Algorithm: AES-256 (preferred) or 3DES

3. **Set defaults:**
   - "Encrypt contents and attachments for outgoing messages" — only if recipients have certs
   - "Add digital signature to outgoing messages" — recommended

4. **Verify:**

   ```powershell
   # List personal certificates in Windows Certificate Store
   Get-ChildItem Cert:\CurrentUser\My | Where-Object { $_.EnhancedKeyUsageList -match "Email" }
   ```

### Outlook (Web / OWA)

S/MIME in Outlook Web App requires:

- Microsoft 365 Business Premium, E3, or E5 (not available on basic plans)
- The S/MIME control installed in the browser (Internet Explorer/Edge legacy only — not supported in modern browsers as of 2024)
- For modern browser support, use the Outlook desktop app or a third-party extension

**Practical recommendation:** Use the Outlook desktop app for S/MIME. OWA S/MIME support is limited and browser-dependent.

### Gmail (Google Workspace)

S/MIME in Gmail requires:

- Google Workspace Enterprise Standard, Enterprise Plus, Education Plus, or Frontline Starter/Standard
- Admin console → Apps → Google Workspace → Gmail → User settings → S/MIME → Enable S/MIME

**Admin upload (for all users):**

```bash
# Upload certificate via Google Workspace Admin SDK
# Requires domain admin credentials and googleapis Python client
# See: https://developers.google.com/gmail/api/reference/rest/v1/users.settings.sendAs/smimeInfo
```

**User self-service (if admin enables it):**

1. Gmail Settings → See all settings → Accounts → Send mail as → Edit info
2. Upload certificate → enter password → Save

**Limitation:** Gmail S/MIME only works within Google Workspace — it does not support S/MIME for personal `@gmail.com` accounts.

### Proton Mail

Proton Mail uses its own end-to-end encryption by default. S/MIME is not natively supported in the Proton Mail web interface. Use Proton Mail Bridge (desktop app) with Thunderbird or Apple Mail if you need S/MIME interoperability with external recipients.

## Key Backup and Recovery

**Critical:** Your private key is the only way to decrypt emails encrypted to you. If you lose it, those emails are permanently unreadable. Back up before anything else.

### Backup Procedure

```bash
# 1. Export the full PKCS#12 bundle (certificate + private key)
#    From macOS Keychain:
security export -k ~/Library/Keychains/login.keychain-db \
    -t identities \
    -f pkcs12 \
    -o smime-backup.p12
# Enter a strong export password when prompted

# 2. Verify the backup is intact
openssl pkcs12 -in smime-backup.p12 -noout -info
# Should show: MAC verified OK, certificate and key details

# 3. Store the backup securely
# Option A: gopass (recommended)
gopass binary justfiles smime-backup.p12
# Or store the password separately:
gopass insert email/smime-cert-password

# Option B: Encrypted USB drive (offline backup)
# Copy smime-backup.p12 to an encrypted USB and store offline

# Option C: macOS encrypted disk image
hdiutil create -size 10m -encryption AES-256 -fs HFS+ \
    -volname "SMIMEBackup" smime-backup.dmg
# Mount, copy the .p12, unmount, store the .dmg securely
```

### Recovery Procedure

```bash
# Restore from PKCS#12 backup to macOS Keychain
security import smime-backup.p12 -k ~/Library/Keychains/login.keychain-db
# Enter the backup password when prompted

# Restore to Thunderbird NSS database
pk12util -i smime-backup.p12 -d ~/.thunderbird/*.default-release/
# Enter the backup password when prompted

# Restore to Linux NSS database (e.g., for Thunderbird on Linux)
pk12util -i smime-backup.p12 -d sql:~/.pki/nssdb/
```

### Key Rotation

Certificates expire (typically 1–3 years). Plan rotation before expiry:

```bash
# Check certificate expiry
openssl x509 -in cert.pem -enddate -noout
# Output: notAfter=Mar 16 00:00:00 2027 GMT

# Check expiry of a .p12 file
openssl pkcs12 -in smime-cert.p12 -nokeys -clcerts -passin pass:yourpassword \
    | openssl x509 -enddate -noout

# Set a calendar reminder 30 days before expiry
# When renewing: obtain new cert, import, update all clients, archive old cert
# Keep old cert accessible for decrypting historical emails
```

**Important:** Do not delete expired certificates. You need the private key to decrypt emails that were encrypted to the old certificate. Archive expired certs in your backup store.

### Revocation

If your private key is compromised:

1. Contact your CA immediately — they will revoke the certificate and publish a CRL (Certificate Revocation List) entry
2. Generate a new certificate from the CA
3. Notify frequent correspondents to update your public key
4. For Actalis: log in to the Actalis portal and request revocation

```bash
# Check if a certificate has been revoked (OCSP check)
openssl ocsp \
    -issuer issuer-cert.pem \
    -cert your-cert.pem \
    -url http://ocsp.actalis.it/VA/SMIME \
    -resp_text
# Look for: Cert Status: good (not revoked) or revoked
```

## Agent-Assisted Signing and Encryption

Use `openssl` for command-line S/MIME operations. This is useful for automation, scripting, and verifying signed emails.

### Signing an Email

```bash
# Sign a message (detached signature — most compatible)
openssl smime -sign \
    -in message.txt \
    -signer cert.pem \
    -inkey private-key.pem \
    -out signed-message.eml \
    -text \
    -md sha256

# Sign from a PKCS#12 bundle
openssl pkcs12 -in smime-cert.p12 -passin pass:yourpassword \
    -clcerts -nokeys -out cert.pem
openssl pkcs12 -in smime-cert.p12 -passin pass:yourpassword \
    -nocerts -nodes -out private-key.pem

openssl smime -sign \
    -in message.txt \
    -signer cert.pem \
    -inkey private-key.pem \
    -out signed-message.eml \
    -text \
    -md sha256

# Clean up extracted key immediately
rm -f private-key.pem
```

### Encrypting an Email

```bash
# Encrypt to a recipient (you need their public certificate)
# First, extract their public cert from a signed email they sent you:
openssl smime -verify -in their-signed-email.eml -noverify \
    -signer recipient-cert.pem 2>/dev/null

# Encrypt the message to the recipient
openssl smime -encrypt \
    -in message.txt \
    -out encrypted-message.eml \
    -aes256 \
    recipient-cert.pem

# Encrypt to multiple recipients
openssl smime -encrypt \
    -in message.txt \
    -out encrypted-message.eml \
    -aes256 \
    recipient1-cert.pem recipient2-cert.pem
```

### Decrypting an Email

```bash
# Decrypt an S/MIME encrypted email
openssl smime -decrypt \
    -in encrypted-message.eml \
    -recip cert.pem \
    -inkey private-key.pem \
    -out decrypted-message.txt

# Or from PKCS#12 directly
openssl pkcs12 -in smime-cert.p12 -passin pass:yourpassword \
    -clcerts -nokeys -out cert.pem
openssl pkcs12 -in smime-cert.p12 -passin pass:yourpassword \
    -nocerts -nodes -out private-key.pem

openssl smime -decrypt \
    -in encrypted-message.eml \
    -recip cert.pem \
    -inkey private-key.pem \
    -out decrypted-message.txt

rm -f private-key.pem
```

### Verifying a Signed Email

```bash
# Verify signature and extract signer certificate
openssl smime -verify \
    -in signed-email.eml \
    -CAfile ca-bundle.pem \
    -out verified-message.txt

# Verify without CA chain check (useful for self-signed or unknown CA)
openssl smime -verify \
    -in signed-email.eml \
    -noverify \
    -out verified-message.txt

# Extract the signer's certificate for future encryption
openssl smime -verify \
    -in signed-email.eml \
    -noverify \
    -signer signer-cert.pem \
    -out /dev/null 2>/dev/null
```

### Automation Helper Script

```bash
#!/bin/bash
# smime-helper.sh — S/MIME sign/encrypt/decrypt/verify helper
# Usage: smime-helper.sh <action> [options]
# Actions: sign, encrypt, decrypt, verify, extract-cert

set -euo pipefail

SMIME_CERT="${SMIME_CERT:-}"
SMIME_KEY="${SMIME_KEY:-}"
SMIME_P12="${SMIME_P12:-}"
SMIME_P12_PASS="${SMIME_P12_PASS:-}"

usage() {
    echo "Usage: $0 <sign|encrypt|decrypt|verify|extract-cert> [options]"
    echo ""
    echo "Environment variables:"
    echo "  SMIME_CERT      Path to certificate PEM file"
    echo "  SMIME_KEY       Path to private key PEM file"
    echo "  SMIME_P12       Path to PKCS#12 bundle"
    echo "  SMIME_P12_PASS  Password for PKCS#12 bundle (use env var, not arg)"
    return 0
}

extract_from_p12() {
    local p12_file="$1"
    local cert_out="$2"
    local key_out="$3"
    local pass="$4"

    openssl pkcs12 -in "$p12_file" -passin "pass:${pass}" \
        -clcerts -nokeys -out "$cert_out" 2>/dev/null
    openssl pkcs12 -in "$p12_file" -passin "pass:${pass}" \
        -nocerts -nodes -out "$key_out" 2>/dev/null
    chmod 600 "$key_out"
    return 0
}

action="${1:-}"
case "$action" in
    sign)
        input="${2:-/dev/stdin}"
        output="${3:-signed.eml}"
        tmpkey=$(mktemp)
        tmpcert=$(mktemp)
        extract_from_p12 "$SMIME_P12" "$tmpcert" "$tmpkey" "$SMIME_P12_PASS"
        openssl smime -sign -in "$input" -signer "$tmpcert" \
            -inkey "$tmpkey" -out "$output" -text -md sha256
        rm -f "$tmpkey" "$tmpcert"
        echo "Signed: $output"
        ;;
    encrypt)
        input="${2:-/dev/stdin}"
        output="${3:-encrypted.eml}"
        recipient_cert="${4:?Usage: $0 encrypt <input> <output> <recipient-cert.pem>}"
        openssl smime -encrypt -in "$input" -out "$output" \
            -aes256 "$recipient_cert"
        echo "Encrypted: $output"
        ;;
    decrypt)
        input="${2:?Usage: $0 decrypt <input.eml> [output.txt]}"
        output="${3:-decrypted.txt}"
        tmpkey=$(mktemp)
        tmpcert=$(mktemp)
        extract_from_p12 "$SMIME_P12" "$tmpcert" "$tmpkey" "$SMIME_P12_PASS"
        openssl smime -decrypt -in "$input" -recip "$tmpcert" \
            -inkey "$tmpkey" -out "$output"
        rm -f "$tmpkey" "$tmpcert"
        echo "Decrypted: $output"
        ;;
    verify)
        input="${2:?Usage: $0 verify <signed.eml>}"
        openssl smime -verify -in "$input" -noverify -out /dev/null 2>&1
        ;;
    extract-cert)
        input="${2:?Usage: $0 extract-cert <signed.eml> [output-cert.pem]}"
        output="${3:-signer-cert.pem}"
        openssl smime -verify -in "$input" -noverify \
            -signer "$output" -out /dev/null 2>/dev/null
        echo "Certificate extracted: $output"
        ;;
    *)
        usage
        exit 1
        ;;
esac
```

**Usage with gopass (secret-safe):**

```bash
# Store the P12 password in gopass — never pass as argument
gopass insert email/smime-p12-password

# Use via environment variable (not command argument)
SMIME_P12=~/.config/smime/cert.p12 \
SMIME_P12_PASS=$(gopass show -o email/smime-p12-password) \
  smime-helper.sh sign message.txt signed.eml
```

## Cross-Client Compatibility

### Compatibility Matrix

| Sender \ Recipient | Apple Mail | Thunderbird | Outlook | Gmail (Workspace) | Proton Mail |
|-------------------|-----------|-------------|---------|-------------------|-------------|
| **Apple Mail** | Full | Full | Full | Full (Enterprise) | Partial* |
| **Thunderbird** | Full | Full | Full | Full (Enterprise) | Partial* |
| **Outlook** | Full | Full | Full | Full (Enterprise) | Partial* |
| **Gmail (Workspace)** | Full | Full | Full | Full | Partial* |
| **Proton Mail** | Via Bridge | Via Bridge | Via Bridge | Via Bridge | Native E2E |

*Proton Mail uses its own encryption by default. S/MIME interoperability requires Proton Mail Bridge.

### Known Compatibility Issues

**Outlook and non-Microsoft clients:**

- Outlook uses `application/pkcs7-mime` with `smime-type=enveloped-data` — standard and widely supported
- Older Outlook versions (2010 and earlier) may use 3DES instead of AES-256 — configure explicitly in Trust Center Settings
- Outlook may wrap signed messages in a `winmail.dat` attachment (TNEF format) when sending to non-Outlook clients. Fix: File → Options → Mail → Message format → set to "Internet Format (HTML)" and disable "Use Microsoft Word to edit email messages"

**Apple Mail and certificate trust:**

- Apple Mail requires the signing CA to be trusted in the macOS System Keychain or Login Keychain
- Actalis root CA is included in macOS trust store (as of macOS 12+); older systems may need manual trust
- To manually trust a CA: Keychain Access → import CA cert → Get Info → Trust → "Always Trust"

**Thunderbird and SHA-1:**

- Thunderbird 78+ rejects SHA-1 signed certificates. Ensure your certificate uses SHA-256 or better
- Check: `openssl x509 -in cert.pem -text -noout | grep "Signature Algorithm"`
- Expected: `sha256WithRSAEncryption` or `sha384WithRSAEncryption`

**Gmail and S/MIME:**

- Gmail S/MIME only works within Google Workspace — personal `@gmail.com` accounts cannot use S/MIME
- Gmail strips S/MIME signatures when forwarding outside Google Workspace
- Recipients outside Google Workspace receive the signed/encrypted email correctly if their client supports S/MIME

**Encryption requires recipient's public certificate:**

- You can only encrypt to a recipient if you have their public certificate
- Obtain it by: (a) asking them to send you a signed email (their cert is attached), (b) looking up their cert in a public LDAP directory, or (c) using a CA-provided directory service
- Enterprise environments often use Active Directory or LDAP to distribute certificates automatically

### Algorithm Recommendations

| Parameter | Recommended | Avoid |
|-----------|------------|-------|
| **Signature hash** | SHA-256, SHA-384, SHA-512 | SHA-1 (deprecated), MD5 (broken) |
| **Encryption algorithm** | AES-256-CBC, AES-128-CBC | 3DES (weak), RC2 (broken) |
| **Key size (RSA)** | 2048-bit minimum, 4096-bit preferred | 1024-bit (broken) |
| **Key type** | RSA (universal compatibility) | ECDSA (limited client support) |

### Testing Cross-Client Compatibility

```bash
# Send a test signed email and verify the signature
# 1. Sign a test message
echo "Test S/MIME signature" > test-message.txt
openssl smime -sign \
    -in test-message.txt \
    -signer cert.pem \
    -inkey private-key.pem \
    -out test-signed.eml \
    -text -md sha256

# 2. Verify the signature (simulates what the recipient's client does)
openssl smime -verify \
    -in test-signed.eml \
    -CAfile /etc/ssl/certs/ca-certificates.crt \
    -out /dev/null
# Expected: Verification successful

# 3. Check the certificate details in the signed email
openssl smime -verify -in test-signed.eml -noverify \
    -signer /dev/stdout -out /dev/null 2>/dev/null \
    | openssl x509 -text -noout | grep -E "(Subject|Issuer|Not After|Signature Algorithm)"
```

## Certificate Lifecycle Management

### Annual Renewal Checklist

```bash
# 1. Check current certificate expiry
openssl x509 -in cert.pem -enddate -noout

# 2. Obtain new certificate from CA (30 days before expiry)
# Follow CA-specific renewal process

# 3. Import new certificate to all clients
# (repeat installation steps for each client)

# 4. Archive old certificate (do NOT delete — needed for historical decryption)
mkdir -p ~/.config/smime/archive/
cp smime-cert-old.p12 ~/.config/smime/archive/smime-cert-$(date +%Y).p12

# 5. Update backup store
gopass binary justfiles smime-cert-$(date +%Y).p12

# 6. Notify frequent correspondents of new certificate
# (send them a signed email so they get the new public key)
```

### Monitoring Certificate Expiry

```bash
#!/bin/bash
# Check S/MIME certificate expiry and warn if within 30 days
check_smime_expiry() {
    local cert_file="$1"
    local warn_days="${2:-30}"

    if [[ ! -f "$cert_file" ]]; then
        echo "Certificate not found: $cert_file"
        return 1
    fi

    local expiry_date
    expiry_date=$(openssl x509 -in "$cert_file" -enddate -noout 2>/dev/null \
        | cut -d= -f2)

    local expiry_epoch
    expiry_epoch=$(date -j -f "%b %d %T %Y %Z" "$expiry_date" "+%s" 2>/dev/null \
        || date -d "$expiry_date" "+%s" 2>/dev/null)

    local now_epoch
    now_epoch=$(date "+%s")

    local days_remaining
    days_remaining=$(( (expiry_epoch - now_epoch) / 86400 ))

    if [[ $days_remaining -le 0 ]]; then
        echo "EXPIRED: $cert_file expired $((days_remaining * -1)) days ago"
        return 1
    elif [[ $days_remaining -le $warn_days ]]; then
        echo "WARNING: $cert_file expires in $days_remaining days ($expiry_date)"
        return 1
    else
        echo "OK: $cert_file valid for $days_remaining days ($expiry_date)"
        return 0
    fi
}

check_smime_expiry "${HOME}/.config/smime/cert.pem"
```

## Related

- `services/email/email-security.md` — Email security overview (prompt injection, phishing, S/MIME summary, OpenPGP)
- `tools/credentials/encryption-stack.md` — gopass, SOPS, gocryptfs for credential management
- `tools/security/opsec.md` — Operational security and threat modeling
- `tools/security/tamper-evident-audit.md` — Audit logging for security events
