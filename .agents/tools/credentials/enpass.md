---
description: Enpass password manager CLI integration for credential management
mode: subagent
tools:
  read: true
  write: false
  edit: false
  bash: true
---

# Enpass CLI Integration

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Purpose**: Manage credentials via Enpass CLI (`enpass-cli`)
- **Install**: `brew install enpass-cli` or download from https://www.enpass.io/
- **Docs**: https://www.enpass.io/docs/
- **Storage**: Local vault (no cloud dependency), optional sync via cloud providers

**When to use**: Retrieving passwords for automation when Enpass is the user's primary password manager. Enpass stores vaults locally (SQLite) with optional cloud sync.

<!-- AI-CONTEXT-END -->

## Setup

```bash
# Install CLI
brew install enpass-cli

# Or use the community CLI tool
pip install enpass-cli
# https://github.com/hauntedhost/enpass-cli

# Initialize with vault path
enpass-cli --vault ~/Documents/Enpass/Vaults/primary
```

## Common Commands

```bash
# List all items
enpass-cli list

# Search for items
enpass-cli search "github"

# Get password for specific item
enpass-cli get "GitHub Token" --field password

# Copy password to clipboard
enpass-cli get "GitHub Token" --field password | pbcopy
```

## Vault Access

Enpass uses SQLite with SQLCipher encryption:

```bash
# Vault location (macOS)
~/Library/Containers/in.sinew.Enpass-Desktop/Data/Documents/Walletx/

# Vault location (Linux)
~/.local/share/Enpass/Walletx/
```

## Security Notes

- Enpass vaults are local-first (no mandatory cloud)
- Master password never leaves the device
- Sync options: iCloud, Dropbox, Google Drive, OneDrive, WebDAV, Box
- CLI tools are community-maintained (not official Enpass)

## Related

- `tools/credentials/bitwarden.md` - Bitwarden CLI
- `tools/credentials/gopass.md` - GPG-encrypted secrets (aidevops default)
- `tools/credentials/vaultwarden.md` - Self-hosted Bitwarden
