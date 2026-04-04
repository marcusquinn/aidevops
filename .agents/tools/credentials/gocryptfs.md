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

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

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

## Installation

```bash
# Recommended
gocryptfs-helper.sh install

# Manual — macOS (requires macFUSE)
brew install gocryptfs
brew install --cask macfuse
# May require restart + Security & Privacy approval for macFUSE

# Manual — Linux (Debian/Ubuntu)
sudo apt-get install -y gocryptfs fuse3

# Manual — Linux (Arch)
sudo pacman -S gocryptfs
```

**Prerequisites**: FUSE kernel module — macOS: [macFUSE](https://osxfuse.github.io/), Linux: fuse3.

## Workspace Vaults

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

### Storage Layout

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
gocryptfs-helper.sh init /path/to/encrypted
gocryptfs-helper.sh mount /path/to/encrypted /path/to/mount
cp sensitive-file.txt /path/to/mount/
gocryptfs-helper.sh unmount /path/to/mount
```

## Use Cases

- **Agent workspace protection** -- Encrypted workspace per project for sensitive intermediate files
- **Database dump protection** -- Vault for `pg_dump`/`mysqldump` output, encrypted at rest when closed
- **Client data isolation** -- Per-client vaults (`client-acme`, `client-globex`), open only what you need

All follow the same pattern: `create <name>` → `open <name>` → work → `close <name>`.

## Security Properties

| Property | Detail |
|----------|--------|
| **Algorithm** | AES-256-GCM (hardware-accelerated on modern CPUs) |
| **File names** | Encrypted (EME wide-block encryption) |
| **File sizes** | Slightly padded (reveals approximate size) |
| **Integrity** | GCM authentication prevents tampering |
| **Key derivation** | scrypt (memory-hard, resistant to brute force) |
| **Forward secrecy** | Each file has unique nonce |

**Protects against**: disk theft/loss, unauthorized access when locked, file name leakage, tampering.

**Does NOT protect against**: access while mounted, memory forensics while mounted, root access on running system, weak passwords.

## Agent Instructions

1. **Never accept vault passwords** -- Passwords are entered interactively by the user
2. **Check mount status** -- `gocryptfs-helper.sh status` before operations
3. **Close vaults after use** -- `gocryptfs-helper.sh close <name>` when done
4. **Use workspace vaults** -- Prefer named vaults over raw init/mount

**Prohibited** (NEVER run in agent context):

- Accepting or storing vault passwords
- `cat gocryptfs.conf` -- contains encrypted master key
- Leaving vaults mounted indefinitely

## Troubleshooting

### macFUSE Not Found (macOS)

```bash
brew install --cask macfuse
# May require system restart and Security & Privacy approval
```

### Permission Denied on Mount

```bash
# Check FUSE permissions (Linux)
ls -la /dev/fuse

# Add user to fuse group (Linux) — requires logout/login
sudo usermod -aG fuse $USER
```

### Unmount Fails (Device Busy)

```bash
# Check what's using the mount
lsof +D /path/to/mount

# Force unmount
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
