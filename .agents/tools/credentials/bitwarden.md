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

- **Purpose**: Manage credentials with Bitwarden's official CLI (`bw`)
- **Install**: `brew install bitwarden-cli` or `npm install -g @bitwarden/cli`
- **Docs**: https://bitwarden.com/help/cli/
- **Auth**: `bw login` or `BW_SESSION`

**When to use**: Retrieve passwords for automation, sync vault state, run bulk item operations.

<!-- AI-CONTEXT-END -->

## Setup

```bash
brew install bitwarden-cli
# or
npm install -g @bitwarden/cli

bw login
export BW_SESSION=$(bw unlock --raw)
bw status | jq .
```

## Common Commands

```bash
bw list items --search "github"
bw get item "GitHub Token" | jq -r '.login.password'
bw get totp "GitHub"
bw create item "$(bw get template item | jq '.name="New Item" | .login.username="user" | .login.password="pass"')"
bw sync
```

## Automation Patterns

```bash
export BW_SESSION=$(bw unlock --passwordenv BW_PASSWORD --raw)

DB_PASSWORD=$(bw get item "Production DB" | jq -r '.login.password')
bw list items --folderid "$(bw get folder 'Servers' | jq -r '.id')"
```

## Security Notes

- Keep `BW_SESSION` in env vars only
- Session tokens expire after inactivity
- Run `bw lock` when automation finishes
- For server or CI use, prefer Bitwarden Secrets Manager (`bws`)

## Related

- `tools/credentials/gopass.md` - GPG-encrypted secrets (aidevops default)
- `tools/credentials/vaultwarden.md` - Self-hosted Bitwarden server
- `tools/credentials/api-key-setup.md` - API key management
