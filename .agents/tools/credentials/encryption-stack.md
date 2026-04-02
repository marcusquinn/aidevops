---
description: Encryption stack overview - gopass, SOPS, and gocryptfs decision guide
mode: subagent
tools:
  read: true
  write: false
  edit: false
  bash: false
  glob: false
  grep: false
  webfetch: false
  task: false
---

# Encryption Stack Overview

<!-- AI-CONTEXT-START -->

## Quick Reference

Use the smallest tool that fits the problem:

| Tool | Best for | Scope | Git-safe | AI-safe | Commands | Storage | Docs |
|------|----------|-------|----------|---------|----------|---------|------|
| **gopass** | API keys, tokens, passwords | Per secret | No (separate store) | Yes (subprocess injection) | `aidevops secret set NAME` / `aidevops secret run CMD` | `~/.local/share/gopass/stores/root/aidevops/` — fallback: `~/.config/aidevops/credentials.sh` (plaintext, 600 perms) | `tools/credentials/gopass.md` |
| **SOPS** | Structured config files with secrets | Per file | Yes (encrypted in repo) | Yes (stdout only) | `sops-helper.sh encrypt config.enc.yaml` | Encrypted files committed to git — backends: age (preferred), GPG, AWS KMS, GCP KMS, Azure Key Vault | `tools/credentials/sops.md` |
| **gocryptfs** | Sensitive directories at rest | Per directory | No (filesystem overlay) | Yes (mount/unmount) | `gocryptfs-helper.sh create vault-name` | `~/.aidevops/.agent-workspace/vaults/` — AES-256-GCM, hardware accelerated | `tools/credentials/gocryptfs.md` |

1. Single secret → `aidevops secret set NAME`
2. Structured file you must commit → `sops-helper.sh encrypt file.enc.yaml`
3. Sensitive directory at rest → `gocryptfs-helper.sh create vault-name`

<!-- AI-CONTEXT-END -->

## Common Workflows

### New project setup

```bash
# 1. Initialize gopass for API keys
aidevops secret init
aidevops secret set DATABASE_URL
aidevops secret set API_KEY

# 2. Initialize SOPS for config files (two options)
aidevops init sops                    # Project-level: creates .sops.yaml + age key
sops-helper.sh init                   # Standalone: init without aidevops project config
# Create and encrypt config files
sops-helper.sh encrypt config.enc.yaml

# 3. Create encrypted vault for sensitive workspace data
gocryptfs-helper.sh create myproject
gocryptfs-helper.sh open myproject
```

### CI/CD pipeline

```bash
# gopass: inject secrets into build
aidevops secret run docker build .

# SOPS: decrypt config for deployment
sops decrypt config.enc.yaml > /tmp/config.yaml
deploy --config /tmp/config.yaml
rm /tmp/config.yaml
```

### Team onboarding

```bash
# 1. Share gopass store via git
gopass recipients add teammate@example.com
gopass sync

# 2. Add teammate's age key to .sops.yaml
# Edit .sops.yaml to add their public key
sops updatekeys config.enc.yaml

# 3. gocryptfs vaults are per-machine (no sharing needed)
```

## Security Principles

1. **Never expose secrets in AI context** -- use the AI-safe flows above.
2. **Encryption at rest** -- all three tools protect data when idle.
3. **Minimal exposure** -- decrypt only what you need, when you need it.
4. **Key separation** -- each tool uses independent key material.
5. **Audit trail** -- gopass and SOPS changes are git-versioned.

## Related

- `tools/credentials/api-key-setup.md` -- API key setup guide
- `tools/credentials/multi-tenant.md` -- Multi-tenant credential storage
