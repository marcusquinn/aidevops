---
description: SOPS encrypted config file management for git-safe secret storage
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

# SOPS - Encrypted Config File Management

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Purpose**: Encrypt structured config files (YAML, JSON, ENV, INI) for safe git storage
- **Backend**: Mozilla SOPS with age (preferred) or GPG encryption
- **CLI**: `sops-helper.sh <command>` or `sops <command>` directly
- **Config**: `.sops.yaml` in repository root
- **Key storage**: `~/.config/sops/age/keys.txt` (age) or GPG keyring

**Commands**:

- `sops-helper.sh init` -- Initialize SOPS for current repo (generates age key)
- `sops-helper.sh encrypt <file>` -- Encrypt a config file in-place
- `sops-helper.sh decrypt <file>` -- Decrypt to stdout (never stored on disk)
- `sops-helper.sh edit <file>` -- Edit encrypted file (decrypt/edit/re-encrypt)
- `sops-helper.sh rotate <file>` -- Rotate encryption keys
- `sops-helper.sh status` -- Show SOPS status and encrypted files
- `sops-helper.sh install` -- Install SOPS and age

**CRITICAL**: Decrypted content should NEVER be written to unencrypted files on disk. Use `sops decrypt` to stdout or `sops edit` for in-place editing.

<!-- AI-CONTEXT-END -->

## When to Use SOPS vs gopass vs gocryptfs

| Tool | Use Case | Storage |
|------|----------|---------|
| **gopass** | Individual secrets (API keys, tokens) | GPG-encrypted store |
| **SOPS** | Structured config files committed to git | Encrypted in-place in repo |
| **gocryptfs** | Entire directories of sensitive data | FUSE encrypted filesystem |

**Use SOPS when**:

- Config files need to be version-controlled (git) but contain secrets
- Team members need to review config structure without seeing secret values
- You need key rotation without re-creating files
- CI/CD needs to decrypt configs during deployment

**Use gopass when**:

- Individual API keys or tokens
- Secrets that should never appear in git
- AI agent subprocess injection

**Use gocryptfs when**:

- Protecting entire directories at rest
- Workspace-level encryption
- Data that doesn't need git versioning

## Installation

```bash
# Install SOPS + age (recommended backend)
sops-helper.sh install

# Or manually:
# macOS
brew install sops age

# Linux (Debian/Ubuntu)
sudo apt-get install -y age
# SOPS: download from https://github.com/getsops/sops/releases

# Linux (Arch)
sudo pacman -S sops age
```

## Setup

```bash
# Initialize SOPS with age backend (recommended)
sops-helper.sh init

# Or with GPG backend
sops-helper.sh init --backend gpg

# Verify
sops-helper.sh status
```

This creates:

1. An age key pair at `~/.config/sops/age/keys.txt`
2. A `.sops.yaml` config in the repository root
3. A git diff driver for transparent decrypted diffs

## Usage

### Encrypting Config Files

```bash
# Create a config file with secrets
cat > database.enc.yaml << 'EOF'
database:
  host: db.example.com
  port: 5432
  username: admin
  password: super-secret-password
  ssl: true
EOF

# Encrypt it (in-place)
sops-helper.sh encrypt database.enc.yaml

# The file is now safe to commit
git add database.enc.yaml
git commit -m "feat: add encrypted database config"
```

### Viewing Decrypted Content

```bash
# Decrypt to stdout (never writes to disk)
sops-helper.sh decrypt database.enc.yaml

# Pipe to other commands
sops-helper.sh decrypt database.enc.yaml | yq '.database.host'
```

### Editing Encrypted Files

```bash
# Opens $EDITOR with decrypted content, re-encrypts on save
sops-helper.sh edit database.enc.yaml
```

### Key Rotation

```bash
# Rotate data encryption key (re-encrypts with new DEK)
sops-helper.sh rotate database.enc.yaml
```

## File Naming Convention

SOPS matches files based on `.sops.yaml` creation rules. The default config uses:

| Pattern | Example |
|---------|---------|
| `*.enc.yaml` | `database.enc.yaml` |
| `*.enc.json` | `config.enc.json` |
| `*.enc.env` | `.env.enc.env` |
| `*.enc.ini` | `settings.enc.ini` |
| `secrets/*` | `secrets/production.yaml` |

## .sops.yaml Configuration

```yaml
creation_rules:
  # Age encryption (recommended)
  - path_regex: \.enc\.(yaml|yml|json|env|ini)$
    age: >-
      age1ql3z7hjy54pw3hyww5ayyfg7zqgvc7w3j2elw8zmrj2kg5sfn9aqmcac8p

  # GPG encryption (alternative)
  - path_regex: secrets/.*\.(yaml|yml|json|env|ini)$
    pgp: >-
      FBC7B9E2A4F9289AC0C1D4843D16CEE4A27381B4

  # AWS KMS (for cloud deployments)
  - path_regex: deploy/.*\.enc\.yaml$
    kms: >-
      arn:aws:kms:us-east-1:123456789:key/abc-def-ghi
```

## Team Sharing

### Adding Team Members (age)

```bash
# Team member generates their age key
age-keygen -o ~/.config/sops/age/keys.txt

# They share their PUBLIC key (safe to share)
grep "public key:" ~/.config/sops/age/keys.txt

# Add their public key to .sops.yaml
# Multiple keys = any key holder can decrypt
creation_rules:
  - path_regex: \.enc\.(yaml|yml|json|env|ini)$
    age: >-
      age1abc...your-key,
      age1def...teammate-key
```

### Adding Team Members (GPG)

```bash
# Import teammate's public key
gpg --import teammate-public-key.asc

# Add their fingerprint to .sops.yaml
creation_rules:
  - path_regex: \.enc\.(yaml|yml|json|env|ini)$
    pgp: >-
      YOUR_FINGERPRINT,
      TEAMMATE_FINGERPRINT

# Re-encrypt existing files with new recipients
sops updatekeys database.enc.yaml
```

## Git Integration

### Diff Driver

The `sops-helper.sh init` command configures a git diff driver:

```bash
# .gitattributes
*.enc.* diff=sopsdiffer

# git config
git config diff.sopsdiffer.textconv "sops decrypt"
```

This shows decrypted diffs in `git diff` and `git log -p`.

### Pre-commit Hook

```bash
# Prevent committing unencrypted files that should be encrypted
# Add to .pre-commit-config.yaml or git hooks
for file in $(git diff --cached --name-only | grep '\.enc\.'); do
    if ! grep -q '"sops"' "$file" 2>/dev/null && ! grep -q "sops:" "$file" 2>/dev/null; then
        echo "ERROR: $file appears unencrypted. Run: sops-helper.sh encrypt $file"
        exit 1
    fi
done
```

## CI/CD Integration

### GitHub Actions

```yaml
- name: Decrypt configs
  env:
    SOPS_AGE_KEY: ${{ secrets.SOPS_AGE_KEY }}
  run: |
    sops decrypt config.enc.yaml > config.yaml
    # Use decrypted config...
    rm config.yaml  # Clean up
```

### Environment Variable

```bash
# Set SOPS_AGE_KEY for non-interactive decryption
export SOPS_AGE_KEY=$(cat ~/.config/sops/age/keys.txt)
sops decrypt config.enc.yaml
```

## Agent Instructions

When an AI agent needs to work with SOPS-encrypted files:

1. **Never decrypt to disk** -- Use `sops decrypt <file>` to stdout
2. **Never expose age private keys** -- The key file is at `~/.config/sops/age/keys.txt`
3. **Use sops-helper.sh** -- Wrapper handles common operations safely
4. **Check encryption status** -- `sops-helper.sh status <file>` before operations

**Prohibited commands** (NEVER run in agent context):

- `cat ~/.config/sops/age/keys.txt` -- exposes private key
- `sops decrypt <file> > plaintext.yaml` -- writes secrets to disk
- `echo $SOPS_AGE_KEY` -- leaks key material

## Architecture

```text
                    Repository (.sops.yaml)
                           |
                    *.enc.yaml files
                    (encrypted in git)
                           |
              sops-helper.sh encrypt/decrypt
                           |
              age key (~/.config/sops/age/keys.txt)
              or GPG keyring
                           |
              Decrypted content (stdout only)
              Never written to unencrypted files
```

## Related

- `tools/credentials/gopass.md` -- Individual secret management
- `tools/credentials/gocryptfs.md` -- Directory-level encryption
- `tools/credentials/api-key-setup.md` -- API key storage
- `.agents/scripts/sops-helper.sh` -- Implementation
