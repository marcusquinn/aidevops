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

- **Purpose**: Retrieve credentials via Enpass CLI for automation when Enpass is the user's primary password manager
- **Install**: `brew install enpass-cli` (macOS) or `pip install enpass-cli` (community CLI)
- **Docs**: https://www.enpass.io/docs/
- **Storage**: Local vault (SQLite + SQLCipher), optional cloud sync
- **Note**: CLI tools are community-maintained, not official Enpass

<!-- AI-CONTEXT-END -->

## Setup

```bash
# macOS (recommended)
brew install enpass-cli

# Alternative: https://github.com/hauntedhost/enpass-cli
pip install enpass-cli

# Use with explicit vault path
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

| Platform | Path |
|----------|------|
| macOS | `~/Library/Containers/in.sinew.Enpass-Desktop/Data/Documents/Walletx/` |
| Linux | `~/.local/share/Enpass/Walletx/` |

## Security Notes

- Local-first: master password never leaves the device
- Sync options: iCloud, Dropbox, Google Drive, OneDrive, WebDAV, Box

## Related

- `tools/credentials/bitwarden.md` — Bitwarden CLI
- `tools/credentials/gopass.md` — GPG-encrypted secrets (aidevops default)
- `tools/credentials/vaultwarden.md` — Self-hosted Bitwarden
