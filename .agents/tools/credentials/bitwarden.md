---
description: Bitwarden password manager CLI integration for credential management
mode: subagent
tools:
  read: true
  write: false
  edit: false
  bash: true
---

# Bitwarden CLI Integration

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Purpose**: Manage credentials via Bitwarden's official CLI (`bw`)
- **Install**: `brew install bitwarden-cli` or `npm install -g @bitwarden/cli`
- **Docs**: https://bitwarden.com/help/cli/
- **Auth**: `bw login` (interactive) or `BW_SESSION` env var

**When to use**: Retrieving passwords/secrets for automation, syncing credentials across environments, bulk credential operations.

<!-- AI-CONTEXT-END -->

## Setup

```bash
# Install
brew install bitwarden-cli
# or
npm install -g @bitwarden/cli

# Login and unlock
bw login
export BW_SESSION=$(bw unlock --raw)

# Verify
bw status | jq .
```

## Common Commands

```bash
# Search for items
bw list items --search "github"

# Get specific item
bw get item "GitHub Token" | jq -r '.login.password'

# Get TOTP code
bw get totp "GitHub"

# Create item
bw create item "$(bw get template item | jq '.name="New Item" | .login.username="user" | .login.password="pass"')"

# Sync vault
bw sync
```

## Automation Patterns

```bash
# Non-interactive session (for scripts)
export BW_SESSION=$(bw unlock --passwordenv BW_PASSWORD --raw)

# Retrieve secret for deployment
DB_PASSWORD=$(bw get item "Production DB" | jq -r '.login.password')

# List all items in a folder
bw list items --folderid "$(bw get folder 'Servers' | jq -r '.id')"
```

## Security Notes

- Never store `BW_SESSION` in files -- use env vars only
- Session tokens expire after inactivity (configurable)
- Use `bw lock` when done with automation
- For server/CI use: Bitwarden Secrets Manager (`bws`) is preferred over vault CLI

## Related

- `tools/credentials/gopass.md` - GPG-encrypted secrets (aidevops default)
- `tools/credentials/vaultwarden.md` - Self-hosted Bitwarden server
- `tools/credentials/api-key-setup.md` - API key management
