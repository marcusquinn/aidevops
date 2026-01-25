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

- **Script**: `.agent/scripts/credential-helper.sh`
- **Storage**: `~/.config/aidevops/tenants/{tenant}/mcp-env.sh`
- **Active tenant**: `~/.config/aidevops/active-tenant`
- **Project override**: `.aidevops-tenant` (gitignored)
- **Priority**: Project tenant > Global active > "default"
- **Backward compatible**: Existing `mcp-env.sh` migrates to `default` tenant

**Quick commands**:
- `credential-helper.sh init` - Initialize (migrates existing keys)
- `credential-helper.sh create <name>` - New tenant
- `credential-helper.sh switch <name>` - Change active tenant
- `credential-helper.sh use <name>` - Per-project tenant
- `credential-helper.sh status` - Show current state
<!-- AI-CONTEXT-END -->

## Overview

Multi-tenant credential storage allows managing separate credential sets for:

- **Multiple clients** (client-acme, client-globex)
- **Multiple environments** (production, staging, development)
- **Multiple accounts** (personal, work, freelance)
- **Multiple services** (different GitHub orgs, Cloudflare accounts)

## Architecture

```text
~/.config/aidevops/
├── mcp-env.sh              # Loader (sources active tenant)
├── active-tenant           # Global active tenant name
└── tenants/
    ├── default/
    │   └── mcp-env.sh      # Original credentials (migrated)
    ├── client-acme/
    │   └── mcp-env.sh      # Acme Corp credentials
    └── client-globex/
        └── mcp-env.sh      # Globex Corp credentials
```

### Resolution Priority

1. **Project-level** (`.aidevops-tenant` in project root)
2. **Global active** (`~/.config/aidevops/active-tenant`)
3. **Default** (fallback to `default` tenant)

## Setup

### Initialize

```bash
# First time: migrates existing mcp-env.sh to 'default' tenant
credential-helper.sh init
```

### Create Tenants

```bash
# Create tenants for different contexts
credential-helper.sh create personal
credential-helper.sh create work
credential-helper.sh create client-acme
```

### Add Credentials

```bash
# Add to specific tenant
credential-helper.sh set GITHUB_TOKEN ghp_personal_xxx --tenant personal
credential-helper.sh set GITHUB_TOKEN ghp_work_xxx --tenant work
credential-helper.sh set GITHUB_TOKEN ghp_acme_xxx --tenant client-acme

# Add to active tenant (no --tenant flag)
credential-helper.sh set OPENAI_API_KEY sk-xxx
```

### Switch Tenants

```bash
# Global switch (affects all terminals after reload)
credential-helper.sh switch client-acme

# Per-project (overrides global, stays in this directory)
cd ~/projects/acme-webapp
credential-helper.sh use client-acme
```

## Usage Patterns

### Agency/Freelance

```bash
# Create per-client tenants
credential-helper.sh create client-acme
credential-helper.sh create client-globex

# Each client has their own API keys
credential-helper.sh set VERCEL_TOKEN xxx --tenant client-acme
credential-helper.sh set CLOUDFLARE_TOKEN xxx --tenant client-acme
credential-helper.sh set GITHUB_TOKEN xxx --tenant client-acme

# Set per-project
cd ~/projects/acme-webapp && credential-helper.sh use client-acme
cd ~/projects/globex-api && credential-helper.sh use client-globex
```

### Environment Separation

```bash
# Create environment tenants
credential-helper.sh create production
credential-helper.sh create staging

# Different database credentials per environment
credential-helper.sh set DATABASE_URL "postgres://prod..." --tenant production
credential-helper.sh set DATABASE_URL "postgres://staging..." --tenant staging
```

### Shared Keys

```bash
# Copy common keys (e.g., AI API keys) to new tenants
credential-helper.sh copy default client-acme --key OPENAI_API_KEY
credential-helper.sh copy default client-acme --key ANTHROPIC_API_KEY

# Copy all keys from one tenant to another
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

### Shell Integration

The `mcp-env.sh` loader is sourced by shell startup (`.zshrc`/`.bashrc`). After switching tenants, either:

```bash
source ~/.zshrc          # Reload current shell
# or
exec $SHELL              # Restart shell
```

### Script Integration

```bash
# Load specific tenant in a script
eval $(credential-helper.sh export --tenant client-acme)

# Check active tenant
echo $AIDEVOPS_ACTIVE_TENANT
```

### CI/CD Integration

For CI/CD, use GitHub Secrets or environment-specific variables. Multi-tenant is designed for local development, not CI.

### MCP Tool Integration

The `api-keys` MCP tool supports tenant operations:

```text
api-keys action:list                    # Lists keys from active tenant
api-keys action:set service:KEY_NAME    # Sets in active tenant
```

## Security

- All tenant directories: `700` permissions
- All `mcp-env.sh` files: `600` permissions
- `.aidevops-tenant` is automatically added to `.gitignore`
- Tenant names validated (alphanumeric, hyphens, underscores only)
- Cannot delete the `default` tenant
- Key values never displayed by `list`/`keys`/`status` commands

## Backward Compatibility

- Existing `mcp-env.sh` is automatically migrated to `default` tenant on first `init`
- The legacy `mcp-env.sh` file becomes a loader that sources the active tenant
- `setup-local-api-keys.sh` continues to work (operates on active tenant)
- `list-keys-helper.sh` continues to work (reads from sourced environment)
