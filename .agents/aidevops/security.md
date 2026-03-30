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

# Security Best Practices

## Credential Management

- Never commit API tokens or secrets to version control
- Store in `~/.config/aidevops/credentials.sh` (600 perms) or gopass
- Use env vars for CI/CD; add config files to `.gitignore`
- Rotate tokens quarterly; least-privilege per project/environment
- SSH passwords in separate files (never in scripts), perms 600

## SSH Security

```bash
# Generate Ed25519 key with passphrase
ssh-keygen -t ed25519 -C "your-email@domain.com"
chmod 600 ~/.ssh/id_ed25519 && chmod 644 ~/.ssh/id_ed25519.pub
ssh-keygen -p -f ~/.ssh/id_ed25519
```

```bash
# ~/.ssh/config hardening
Host *
    PasswordAuthentication no
    KexAlgorithms curve25519-sha256@libssh.org,diffie-hellman-group16-sha512
    Ciphers chacha20-poly1305@openssh.com,aes256-gcm@openssh.com
    MACs hmac-sha2-256-etm@openssh.com,hmac-sha2-512-etm@openssh.com
    ForwardX11 no
    ConnectTimeout 10
```

Server: disable root login, non-standard SSH port, fail2ban.

## Access Control

- Minimum necessary permissions; separate tokens per project/environment
- MFA on all cloud accounts; hardware security keys where available
- VPNs or bastion hosts for production; IP whitelisting
- TLS 1.2+ for all API communications; rotate certificates regularly

## File Permissions

```bash
chmod 600 configs/.*.json ~/.ssh/id_* ~/.ssh/config ~/.ssh/*_password
chmod 644 ~/.ssh/id_*.pub
chmod 700 ~/.ssh/
chmod 755 *.sh .agents/scripts/*.sh
```

```bash
# .gitignore entries
printf "configs/.*.json\n*.password\n.env\n*.key\n*.pem\n" >> .gitignore
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

## Monitoring and Incident Response

Monitor API rate limits; alert on unusual activity; log all API calls in production.

**Incident response:**

1. **Immediate** — disable compromised credentials, block suspicious IPs, isolate affected systems
2. **Investigate** — analyze logs, identify scope, document findings
3. **Recover** — rotate all potentially compromised credentials, patch, restore from clean backups
4. **Prevent** — implement additional controls, update procedures

## Security Checklist

**Initial setup:**

- [ ] Ed25519 SSH keys with passphrases
- [ ] File permissions on all sensitive files
- [ ] Secure SSH client config
- [ ] Sensitive files in `.gitignore`
- [ ] MFA on all cloud accounts

**Regular maintenance:**

- [ ] Rotate API tokens quarterly
- [ ] Audit SSH keys, remove unused
- [ ] Review and update access permissions
- [ ] Monitor logs for suspicious activity
- [ ] Update and patch all systems
