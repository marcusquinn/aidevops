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

- **Purpose**: Retrieve credentials via Enpass CLI (`enpass-cli`) for automation when Enpass is the user's primary password manager
- **Install**: `brew install enpass-cli` or download from https://www.enpass.io/
- **Docs**: https://www.enpass.io/docs/
- **Storage**: Local vault (SQLite + SQLCipher), optional sync via cloud providers

<!-- AI-CONTEXT-END -->

## Setup

```bash
brew install enpass-cli

# Community CLI alternative: https://github.com/hauntedhost/enpass-cli
pip install enpass-cli

# Initialize with vault path
enpass-cli --vault ~/Documents/Enpass/Vaults/primary
```

## Common Commands

```bash
enpass-cli list
enpass-cli search "github"
enpass-cli get "GitHub Token" --field password
enpass-cli get "GitHub Token" --field password | pbcopy
```

## Vault Locations

```bash
# macOS
~/Library/Containers/in.sinew.Enpass-Desktop/Data/Documents/Walletx/

# Linux
~/.local/share/Enpass/Walletx/
```

## Security Notes

- Local-first (no mandatory cloud); master password never leaves the device
- Sync options: iCloud, Dropbox, Google Drive, OneDrive, WebDAV, Box
- CLI tools are community-maintained (not official Enpass)

## Related

- `tools/credentials/bitwarden.md` - Bitwarden CLI
- `tools/credentials/gopass.md` - GPG-encrypted secrets (aidevops default)
- `tools/credentials/vaultwarden.md` - Self-hosted Bitwarden
