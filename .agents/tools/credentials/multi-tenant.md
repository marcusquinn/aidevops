---
description: Multi-tenant credential storage for managing multiple accounts per service
mode: subagent
tools:
  read: true
  write: true
  edit: true
  bash: true
  glob: true
  grep: true
  webfetch: false
  task: true
---

# Multi-Tenant Credential Storage

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Script**: `.agents/scripts/credential-helper.sh`
- **Storage**: `~/.config/aidevops/tenants/{tenant}/credentials.sh`
- **Active tenant**: `~/.config/aidevops/active-tenant`
- **Project override**: `.aidevops-tenant` (gitignored)
- **Priority**: Project tenant > Global active > "default"
- **Backward compatible**: Existing `credentials.sh` migrates to `default` tenant on first `init`; legacy loader and `setup-local-api-keys.sh`/`list-keys-helper.sh` continue to work.

For encrypted secrets, see `tools/credentials/gopass.md` (can be used alongside tenant switching).

> If `credential-helper.sh` is not on `PATH`, invoke explicitly:
> `bash ~/.aidevops/agents/scripts/credential-helper.sh <command>`
> or via `setup-local-api-keys.sh tenant <command>`

<!-- AI-CONTEXT-END -->

## Architecture

```text
~/.config/aidevops/
├── credentials.sh          # Loader (sources active tenant)
├── active-tenant           # Global active tenant name
└── tenants/
    ├── default/
    │   └── credentials.sh  # Original credentials (migrated)
    ├── client-acme/
    │   └── credentials.sh  # Acme Corp credentials
    └── client-globex/
        └── credentials.sh  # Globex Corp credentials
```

## Setup and Usage

```bash
# Initialize (migrates existing credentials.sh to 'default' tenant)
credential-helper.sh init

# Create tenants
credential-helper.sh create personal
credential-helper.sh create client-acme

# Set credentials (--tenant flag targets specific tenant; omit for active)
credential-helper.sh set GITHUB_TOKEN ghp_personal_xxx --tenant personal
credential-helper.sh set GITHUB_TOKEN ghp_acme_xxx --tenant client-acme
credential-helper.sh set OPENAI_API_KEY sk-xxx

# Switch active tenant globally
credential-helper.sh switch client-acme

# Per-project override (stays in this directory)
cd ~/projects/acme-webapp
credential-helper.sh use client-acme

# Copy keys between tenants (single key or all)
credential-helper.sh copy default client-acme --key OPENAI_API_KEY
credential-helper.sh copy default client-acme
```

## Commands Reference

| Command | Description |
|---------|-------------|
| `init` | Initialize multi-tenant storage, migrate legacy |
| `status` | Show active tenant, list all tenants |
| `create <name>` | Create a new tenant |
| `switch <name>` | Set global active tenant |
| `use [<name>\|--clear]` | Set/clear project-level tenant |
| `list` | List all tenants with key counts |
| `keys [--tenant <n>]` | Show key names in a tenant |
| `set <KEY> <val> [--tenant <n>]` | Set a credential |
| `get <KEY> [--tenant <n>]` | Get a credential value |
| `remove <KEY> [--tenant <n>]` | Remove a credential |
| `copy <src> <dest> [--key K]` | Copy keys between tenants |
| `delete <name>` | Delete a tenant (not default) |
| `export [--tenant <n>]` | Output exports for eval |

## Integration

**Shell** -- After switching tenants, reload: `source ~/.zshrc` or `exec $SHELL`.

**Scripts** -- Load a specific tenant:

```bash
source <(bash ~/.aidevops/agents/scripts/credential-helper.sh export --tenant client-acme)
echo "$AIDEVOPS_ACTIVE_TENANT"  # Check active tenant
```

**MCP tool** -- `api-keys action:list` and `api-keys action:set service:KEY_NAME` operate on the active tenant.

**CI/CD** -- Use GitHub Secrets or environment-specific variables. Multi-tenant is for local development, not CI.

## Security

- All tenant directories: `700` permissions; all `credentials.sh` files: `600`
- `.aidevops-tenant` is automatically added to `.gitignore`
- Tenant names validated (alphanumeric, hyphens, underscores only)
- Cannot delete the `default` tenant
- Key values never displayed by `list`/`keys`/`status` commands
