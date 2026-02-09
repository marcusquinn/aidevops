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

aidevops provides three complementary encryption tools, each for a different use case:

| Tool | Purpose | Scope | Git-safe | AI-safe |
|------|---------|-------|----------|---------|
| **gopass** | Individual secrets (API keys, tokens) | Per-secret | No (separate store) | Yes (subprocess injection) |
| **SOPS** | Structured config files | Per-file | Yes (encrypted in repo) | Yes (stdout only) |
| **gocryptfs** | Directory-level encryption at rest | Per-directory | No (filesystem overlay) | Yes (mount/unmount) |

**Decision tree**:

1. Single API key or token? -> `aidevops secret set NAME` (gopass)
2. Config file with secrets to commit to git? -> `sops-helper.sh encrypt file.enc.yaml` (SOPS)
3. Directory of sensitive files at rest? -> `gocryptfs-helper.sh create vault-name` (gocryptfs)

<!-- AI-CONTEXT-END -->

## Tool Comparison

### gopass (Individual Secrets)

- **What**: GPG/age-encrypted key-value store
- **When**: API keys, tokens, passwords, connection strings
- **How**: `aidevops secret set NAME` / `aidevops secret run CMD`
- **Storage**: `~/.local/share/gopass/stores/root/aidevops/`
- **Fallback**: `~/.config/aidevops/credentials.sh` (plaintext, 600 perms)
- **Docs**: `tools/credentials/gopass.md`

### SOPS (Config File Encryption)

- **What**: Encrypts structured files (YAML, JSON, ENV, INI) in-place
- **When**: Config files that need git versioning but contain secrets
- **How**: `sops-helper.sh encrypt config.enc.yaml`
- **Storage**: Encrypted files committed to git
- **Backends**: age (preferred), GPG, AWS KMS, GCP KMS, Azure Key Vault
- **Docs**: `tools/credentials/sops.md`

### gocryptfs (Directory Encryption)

- **What**: FUSE encrypted filesystem overlay
- **When**: Protecting entire directories of sensitive data at rest
- **How**: `gocryptfs-helper.sh create vault-name`
- **Storage**: `~/.aidevops/.agent-workspace/vaults/`
- **Algorithm**: AES-256-GCM (hardware-accelerated)
- **Docs**: `tools/credentials/gocryptfs.md`

## Common Workflows

### New Project Setup

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

### CI/CD Pipeline

```bash
# gopass: inject secrets into build
aidevops secret run docker build .

# SOPS: decrypt config for deployment
sops decrypt config.enc.yaml > /tmp/config.yaml
deploy --config /tmp/config.yaml
rm /tmp/config.yaml
```

### Team Onboarding

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

1. **Never expose secrets in AI context** -- All tools support AI-safe operation
2. **Encryption at rest** -- All three tools encrypt data when not in active use
3. **Minimal exposure** -- Decrypt only what you need, when you need it
4. **Key separation** -- Each tool uses independent key material
5. **Audit trail** -- gopass and SOPS changes are git-versioned

## Related

- `tools/credentials/gopass.md` -- gopass documentation
- `tools/credentials/sops.md` -- SOPS documentation
- `tools/credentials/gocryptfs.md` -- gocryptfs documentation
- `tools/credentials/api-key-setup.md` -- API key setup guide
- `tools/credentials/multi-tenant.md` -- Multi-tenant credential storage
