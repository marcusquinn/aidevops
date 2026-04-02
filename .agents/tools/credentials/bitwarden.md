---
description: Bitwarden password manager CLI integration
mode: subagent
tools:
  read: true
  bash: true
---

# Bitwarden CLI

<!-- AI-CONTEXT-START -->
- **Purpose**: Official Bitwarden CLI (`bw`)
- **Install**: `brew install bitwarden-cli` | `npm install -g @bitwarden/cli`
- **Docs**: https://bitwarden.com/help/cli/
- **Auth**: `bw login` | `BW_SESSION`
<!-- AI-CONTEXT-END -->

## Security
- Keep `BW_SESSION` in env vars; tokens expire.
- Run `bw lock` after use. CI/Server: prefer `bws`.

## Usage
```bash
bw login && export BW_SESSION=$(bw unlock --raw)
bw sync
bw list items --search "github"
bw get item "GitHub Token" | jq -r '.login.password'
bw get totp "GitHub"
bw create item "$(bw get template item | jq '.name="New Item" | .login.username="user" | .login.password="pass"')"
```

## Automation
```bash
export BW_SESSION=$(bw unlock --passwordenv BW_PASSWORD --raw)
DB_PASSWORD=$(bw get item "Production DB" | jq -r '.login.password')
bw list items --folderid "$(bw get folder 'Servers' | jq -r '.id')"
```

## Related
- `tools/credentials/gopass.md` (default)
- `tools/credentials/vaultwarden.md`
- `tools/credentials/api-key-setup.md`
