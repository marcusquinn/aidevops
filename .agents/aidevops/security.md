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

- **Never commit API tokens or secrets to version control**
- Store in `~/.config/aidevops/credentials.sh` (600 permissions) or gopass
- Use environment variables for CI/CD; add config files to `.gitignore`
- Rotate tokens quarterly; use least-privilege principle per project/environment
- Store SSH passwords in separate files (never in scripts), permissions 600

## SSH Security

```bash
# Generate secure Ed25519 key
ssh-keygen -t ed25519 -C "your-email@domain.com"

# Set proper permissions
chmod 600 ~/.ssh/id_ed25519
chmod 644 ~/.ssh/id_ed25519.pub

# Add passphrase protection
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

Server hardening: disable root login, use non-standard SSH ports, implement fail2ban, monitor SSH logs.

## Access Control

- Grant minimum necessary permissions; use separate tokens per project/environment
- Enable MFA on all cloud accounts; use hardware security keys where available
- Use VPNs or bastion hosts for production; implement IP whitelisting
- Use TLS 1.2+ for all API communications; rotate certificates regularly

## File Permissions

```bash
# Configuration files
chmod 600 configs/.*.json

# SSH keys
chmod 600 ~/.ssh/id_*
chmod 644 ~/.ssh/id_*.pub
chmod 600 ~/.ssh/config
chmod 700 ~/.ssh/

# Password files
chmod 600 ~/.ssh/*_password

# Scripts
chmod 755 *.sh
chmod 755 .agents/scripts/*.sh
```

```bash
# .gitignore entries
echo "configs/.*.json" >> .gitignore
echo "*.password" >> .gitignore
echo ".env" >> .gitignore
echo "*.key" >> .gitignore
echo "*.pem" >> .gitignore
```

## Script Security

```text
.agents/
├── scripts/              # Shared (committed to Git)
│   └── [helper].sh       # Use placeholders: YOUR_API_KEY_HERE
└── scripts-private/      # Private (gitignored, never committed)
    └── [custom].sh       # Real credentials OK here
```

**Shared scripts (`scripts/`):** Use placeholders (`readonly API_TOKEN="YOUR_API_TOKEN_HERE"`); load from secure storage via `setup-local-api-keys.sh get service`. Never hardcode credentials.

**Private scripts (`scripts-private/`):** Safe for real API keys (gitignored). Create from templates in `scripts/`. Never share outside secure channels.

```bash
# Verify private scripts are gitignored
git status --ignored | grep scripts-private
# Should show: .agents/scripts-private/ (ignored)
```

## Monitoring and Incident Response

```bash
# Enable SSH logging — add to /etc/ssh/sshd_config
LogLevel VERBOSE

# Monitor SSH access
tail -f /var/log/auth.log | grep ssh
```

Monitor API rate limits and usage; set up alerts for unusual activity; log all API calls in production.

**Incident response:**

1. **Immediate** — disable compromised credentials, block suspicious IPs, isolate affected systems
2. **Investigate** — analyze logs for attack vectors, identify scope, document findings
3. **Recover** — rotate all potentially compromised credentials, patch systems, restore from clean backups if needed
4. **Prevent** — implement additional controls, update procedures, conduct security training

## Security Tools

```bash
# SSH security audit
ssh-audit server-ip

# Network scanning
nmap -sS -sV target

# SSL/TLS testing
testssl.sh target

# File integrity monitoring
aide --init && aide --check

# Firewall (SSH example)
iptables -A INPUT -p tcp --dport 22 -s trusted-ip -j ACCEPT
iptables -A INPUT -p tcp --dport 22 -j DROP

# Fail2ban status
fail2ban-client status
```

## Security Checklist

**Initial setup:**
- [ ] Generate Ed25519 SSH keys with passphrases
- [ ] Set file permissions on all sensitive files
- [ ] Configure secure SSH client settings
- [ ] Add sensitive files to `.gitignore`
- [ ] Enable MFA on all cloud accounts

**Regular maintenance:**
- [ ] Rotate API tokens quarterly
- [ ] Audit SSH keys and remove unused ones
- [ ] Review and update access permissions
- [ ] Monitor logs for suspicious activity
- [ ] Update and patch all systems
