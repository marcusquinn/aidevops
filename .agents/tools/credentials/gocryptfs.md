---
description: gocryptfs encrypted filesystem for directory-level encryption at rest
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

# gocryptfs - Encrypted Filesystem Overlay

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Purpose**: Encrypt entire directories with transparent FUSE filesystem overlay
- **Backend**: gocryptfs (AES-256-GCM, hardware-accelerated)
- **CLI**: `gocryptfs-helper.sh <command>`
- **Vault storage**: `~/.aidevops/.agent-workspace/vaults/`
- **Mount points**: `~/.aidevops/.agent-workspace/mounts/`

**Commands**:

- `gocryptfs-helper.sh create <name>` -- Create named vault
- `gocryptfs-helper.sh open <name>` -- Mount (unlock) vault
- `gocryptfs-helper.sh close <name>` -- Unmount (lock) vault
- `gocryptfs-helper.sh list` -- List workspace vaults
- `gocryptfs-helper.sh status` -- Show gocryptfs status
- `gocryptfs-helper.sh install` -- Install gocryptfs and FUSE

**CRITICAL**: Vault passwords are entered interactively. NEVER accept vault passwords in AI conversation context.

<!-- AI-CONTEXT-END -->

## When to Use gocryptfs vs gopass vs SOPS

| Tool | Use Case | Storage |
|------|----------|---------|
| **gopass** | Individual secrets (API keys, tokens) | GPG-encrypted store |
| **SOPS** | Structured config files committed to git | Encrypted in-place in repo |
| **gocryptfs** | Entire directories of sensitive data | FUSE encrypted filesystem |

**Use gocryptfs when**:

- Protecting entire directories of sensitive data at rest
- Workspace-level encryption for agent work directories
- Storing files that shouldn't be in git but need encryption
- Protecting database dumps, backups, or exported data
- Creating isolated encrypted workspaces for different projects

**Use gopass when**:

- Individual API keys or tokens
- Secrets that need AI-safe subprocess injection

**Use SOPS when**:

- Config files that need to be version-controlled in git
- Structured data (YAML, JSON) with some encrypted fields

## Installation

```bash
# Install gocryptfs + FUSE
gocryptfs-helper.sh install

# Or manually:
# macOS (requires macFUSE)
brew install gocryptfs
brew install --cask macfuse

# Linux (Debian/Ubuntu)
sudo apt-get install -y gocryptfs fuse3

# Linux (Arch)
sudo pacman -S gocryptfs
```

### Prerequisites

- **FUSE**: Required for transparent filesystem overlay
  - macOS: [macFUSE](https://osxfuse.github.io/) (`brew install --cask macfuse`)
  - Linux: fuse3 (`apt install fuse3`)
- **Kernel support**: FUSE kernel module (included in most Linux distros)

## Workspace Vaults

The simplest way to use gocryptfs with aidevops is through named vaults:

```bash
# Create a vault for sensitive project data
gocryptfs-helper.sh create project-secrets

# Open the vault (prompts for password)
gocryptfs-helper.sh open project-secrets

# Files in the mount point are transparently encrypted
ls ~/.aidevops/.agent-workspace/mounts/project-secrets/
echo "sensitive data" > ~/.aidevops/.agent-workspace/mounts/project-secrets/data.txt

# Close the vault when done (data encrypted at rest)
gocryptfs-helper.sh close project-secrets

# List all vaults
gocryptfs-helper.sh list
```

### Vault Storage Layout

```text
~/.aidevops/.agent-workspace/
├── vaults/                    # Encrypted cipher directories
│   ├── project-secrets/       # gocryptfs.conf + encrypted files
│   └── client-data/
└── mounts/                    # Decrypted mount points (when open)
    ├── project-secrets/       # Transparent access to decrypted files
    └── client-data/
```

## Low-Level Usage

For encrypting arbitrary directories outside the workspace:

```bash
# Initialize an encrypted directory
gocryptfs-helper.sh init /path/to/encrypted

# Mount it
gocryptfs-helper.sh mount /path/to/encrypted /path/to/mount

# Use the mount point normally
cp sensitive-file.txt /path/to/mount/

# Unmount when done
gocryptfs-helper.sh unmount /path/to/mount
```

## Use Cases

### 1. Agent Workspace Protection

Protect the agent workspace directory where sensitive operations happen:

```bash
# Create an encrypted workspace for a specific project
gocryptfs-helper.sh create myproject-workspace

# Open it before starting work
gocryptfs-helper.sh open myproject-workspace

# Agent can now safely store intermediate files
# ~/.aidevops/.agent-workspace/mounts/myproject-workspace/

# Close when session ends
gocryptfs-helper.sh close myproject-workspace
```

### 2. Database Dump Protection

```bash
# Create vault for database exports
gocryptfs-helper.sh create db-exports

# Open and export
gocryptfs-helper.sh open db-exports
pg_dump mydb > ~/.aidevops/.agent-workspace/mounts/db-exports/mydb.sql

# Close - dump is now encrypted at rest
gocryptfs-helper.sh close db-exports
```

### 3. Client Data Isolation

```bash
# Per-client encrypted vaults
gocryptfs-helper.sh create client-acme
gocryptfs-helper.sh create client-globex

# Open only the vault you need
gocryptfs-helper.sh open client-acme
# Work with client data...
gocryptfs-helper.sh close client-acme
```

## Security Properties

| Property | Detail |
|----------|--------|
| **Algorithm** | AES-256-GCM (hardware-accelerated on modern CPUs) |
| **File names** | Encrypted (EME wide-block encryption) |
| **File sizes** | Slightly padded (reveals approximate size) |
| **Integrity** | GCM authentication prevents tampering |
| **Key derivation** | scrypt (memory-hard, resistant to brute force) |
| **Forward secrecy** | Each file has unique nonce |

### What gocryptfs Protects Against

- Disk theft or loss (data encrypted at rest)
- Unauthorized file access when vault is locked
- File name leakage (names are encrypted)
- Tampering detection (GCM authentication)

### What gocryptfs Does NOT Protect Against

- Access while vault is mounted (files are readable)
- Memory forensics while mounted
- Root access on the running system
- Weak passwords (use strong passphrases)

## Agent Instructions

When an AI agent needs to work with gocryptfs:

1. **Never accept vault passwords** -- Passwords are entered interactively by the user
2. **Check mount status** -- `gocryptfs-helper.sh status` before operations
3. **Close vaults after use** -- `gocryptfs-helper.sh close <name>` when done
4. **Use workspace vaults** -- Prefer named vaults over raw init/mount

**Prohibited commands** (NEVER run in agent context):

- Accepting or storing vault passwords
- `cat gocryptfs.conf` -- contains encrypted master key
- Leaving vaults mounted indefinitely

## Troubleshooting

### macFUSE Not Found (macOS)

```bash
# Install macFUSE
brew install --cask macfuse

# May require system restart and Security & Privacy approval
# System Preferences > Security & Privacy > Allow macFUSE
```

### Permission Denied on Mount

```bash
# Check FUSE permissions
ls -la /dev/fuse  # Linux

# Add user to fuse group (Linux)
sudo usermod -aG fuse $USER
# Log out and back in
```

### Unmount Fails (Device Busy)

```bash
# Check what's using the mount
lsof +D /path/to/mount

# Force unmount (use with caution)
# macOS:
diskutil unmount force /path/to/mount
# Linux:
fusermount -uz /path/to/mount
```

## Architecture

```text
                    User enters password
                           |
                    gocryptfs-helper.sh open <name>
                           |
              ~/.aidevops/.agent-workspace/vaults/<name>/
              (AES-256-GCM encrypted files + gocryptfs.conf)
                           |
                    FUSE filesystem mount
                           |
              ~/.aidevops/.agent-workspace/mounts/<name>/
              (transparent read/write access)
                           |
                    gocryptfs-helper.sh close <name>
                           |
              Mount removed, data encrypted at rest
```

## Related

- `tools/credentials/gopass.md` -- Individual secret management
- `tools/credentials/sops.md` -- Config file encryption for git
- `tools/credentials/api-key-setup.md` -- API key storage
- `.agents/scripts/gocryptfs-helper.sh` -- Implementation
