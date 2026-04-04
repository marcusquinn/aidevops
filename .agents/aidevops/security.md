---
description: Security best practices for AI DevOps
mode: subagent
tools:
  read: true
  write: false
  edit: false
  bash: false
  glob: true
  grep: true
  webfetch: false
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Security Best Practices

Core security rules (never expose credentials, gopass/credentials.sh storage, secret-handling): `prompts/build.txt`.
API key compliance, incident response, provider rotation: `aidevops/security-requirements.md`.

## Credential Management

- Store in `~/.config/aidevops/credentials.sh` (600 perms) or gopass — never in source
- Use env vars for CI/CD; add config files to `.gitignore`
- Rotate tokens quarterly; least-privilege per project/environment
- SSH passwords in separate files (never in scripts), perms 600

## File Permissions

```bash
chmod 600 configs/.*.json ~/.ssh/id_* ~/.ssh/config ~/.ssh/*_password
chmod 644 ~/.ssh/id_*.pub
chmod 700 ~/.ssh/
chmod 755 *.sh .agents/scripts/*.sh
# .gitignore entries
printf "configs/.*.json\n*.password\n.env\n*.key\n*.pem\n" >> .gitignore
```

## SSH Hardening

```bash
# Generate Ed25519 key
ssh-keygen -t ed25519 -C "your-email@domain.com"
chmod 600 ~/.ssh/id_ed25519 && chmod 644 ~/.ssh/id_ed25519.pub
# Change passphrase on existing key
ssh-keygen -p -f ~/.ssh/id_ed25519
```

`~/.ssh/config` hardening — disable root login, non-standard port, fail2ban on server:

```text
Host *
    PasswordAuthentication no
    KexAlgorithms curve25519-sha256@libssh.org,diffie-hellman-group16-sha512
    Ciphers chacha20-poly1305@openssh.com,aes256-gcm@openssh.com
    MACs hmac-sha2-256-etm@openssh.com,hmac-sha2-512-etm@openssh.com
    ForwardX11 no
    ConnectTimeout 10
```

## Script Security

```text
.agents/
├── scripts/          # Shared (committed) — placeholders only: YOUR_API_KEY_HERE
└── scripts-private/  # Private (gitignored) — real credentials OK
```

- **Shared scripts**: load credentials via `setup-local-api-keys.sh get service`; never hardcode
- **Private scripts**: safe for real API keys; create from `scripts/` templates; never share outside secure channels
- Verify: `git status --ignored | grep scripts-private` → should show `(ignored)`

## Access Control & Monitoring

- MFA on all cloud accounts; hardware security keys where available
- VPNs or bastion hosts for production; IP whitelisting; TLS 1.2+ for all API communications
- Separate tokens per project/environment
- Monitor API rate limits; alert on unusual activity; log all API calls in production
