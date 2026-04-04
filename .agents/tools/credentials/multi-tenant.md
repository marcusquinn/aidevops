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

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Multi-Tenant Credential Storage

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Script**: `credential-helper.sh` (`bash ~/.aidevops/agents/scripts/credential-helper.sh <cmd>` if not on PATH)
- **Storage**: `~/.config/aidevops/tenants/{tenant}/credentials.sh`
- **Priority**: Project (`.aidevops-tenant`) > Global (`active-tenant`) > `default`
- **Backward compatible**: Existing `credentials.sh` migrates to `default` on `init`

**Commands**: `init` | `create <n>` | `switch <n>` | `use <n>` | `status` | `list` | `keys` | `set/get/remove <KEY>` | `copy <src> <dst>` | `delete <n>` | `export`

<!-- AI-CONTEXT-END -->

Manages separate credential sets for multiple clients, environments, or accounts. For encrypted storage, see `tools/credentials/gopass.md` — use `aidevops secret` for encrypted secrets alongside `credential-helper.sh` for tenant switching.

## Architecture

```text
~/.config/aidevops/
├── credentials.sh          # Loader (sources active tenant)
├── active-tenant           # Global active tenant name
└── tenants/
    ├── default/credentials.sh
    └── client-acme/credentials.sh
```

## Setup

```bash
credential-helper.sh init                                          # migrate legacy credentials.sh → default
credential-helper.sh create client-acme                           # new tenant
credential-helper.sh set GITHUB_TOKEN ghp_xxx --tenant client-acme
credential-helper.sh switch client-acme                           # global switch
cd ~/projects/acme && credential-helper.sh use client-acme        # per-project
```

## Usage Patterns

**Agency/Freelance**:
```bash
credential-helper.sh create client-acme
credential-helper.sh set VERCEL_TOKEN xxx --tenant client-acme
cd ~/projects/acme-webapp && credential-helper.sh use client-acme
```

**Environment separation**:
```bash
credential-helper.sh set DATABASE_URL "postgres://prod..." --tenant production
credential-helper.sh set DATABASE_URL "postgres://staging..." --tenant staging
```

**Copy keys between tenants**:
```bash
credential-helper.sh copy default client-acme --key OPENAI_API_KEY
credential-helper.sh copy default client-acme   # copy all
```

## Commands Reference

| Command | Description |
|---------|-------------|
| `init` | Initialize, migrate legacy |
| `status` | Show active tenant, list all |
| `create <name>` | New tenant |
| `switch <name>` | Set global active tenant |
| `use [<name>\|--clear]` | Set/clear project-level tenant |
| `list` | List tenants with key counts |
| `keys [--tenant <n>]` | Show key names |
| `set <KEY> <val> [--tenant <n>]` | Set credential |
| `get <KEY> [--tenant <n>]` | Get credential value |
| `remove <KEY> [--tenant <n>]` | Remove credential |
| `copy <src> <dest> [--key K]` | Copy keys between tenants |
| `delete <name>` | Delete tenant (not default) |
| `export [--tenant <n>]` | Output exports for eval |

## Integration

**Shell**: After switching, reload with `source ~/.zshrc` or `exec $SHELL`.

**Script**: `source <(bash ~/.aidevops/agents/scripts/credential-helper.sh export --tenant client-acme)`

**CI/CD**: Use GitHub Secrets — multi-tenant is for local development only.

**MCP** (`api-keys` tool): `action:list` reads active tenant; `action:set service:KEY_NAME` sets in active tenant.

## Security

- Tenant dirs: `700`; credential files: `600`
- `.aidevops-tenant` auto-added to `.gitignore`
- Tenant names: alphanumeric, hyphens, underscores only; `default` cannot be deleted
- Key values never shown by `list`/`keys`/`status`
