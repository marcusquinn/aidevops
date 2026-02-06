---
description: API key setup with secure local storage
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

# API Key Setup Guide - Secure Local Storage

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Recommended**: `aidevops secret set NAME` (gopass encrypted, AI-safe)
- **Plaintext fallback**: `~/.config/aidevops/credentials.sh` (600 permissions)
- **Working Dirs**: `~/.aidevops/` (agno, stagehand, reports)
- **Setup**: `bash ~/Git/aidevops/.agents/scripts/setup-local-api-keys.sh setup`

**Encrypted storage** (recommended):

- `aidevops secret init` - Initialize gopass store
- `aidevops secret set NAME` - Store secret (hidden input, GPG-encrypted)
- `aidevops secret list` - List names (never values)
- `aidevops secret run CMD` - Inject secrets + redact output

**Plaintext storage** (fallback):

- `set <service-name> <VALUE>` - Store API key (converts to UPPER_CASE export)
- `add 'export VAR="value"'` - Parse and store export command
- `get <service-name>` - Retrieve key value
- `list` - Show configured services (keys redacted)

**Common Services**: codacy-project-token, sonar-token, coderabbit-api-key, hcloud-token-*, openai-api-key

**Security**: NEVER accept secret values in AI conversation. Instruct users to run `aidevops secret set NAME` at their terminal.
<!-- AI-CONTEXT-END -->

## Directory Structure

AI DevOps uses two directories for different purposes:

| Location | Purpose | Permissions |
|----------|---------|-------------|
| `~/.config/aidevops/` | **Secrets & credentials** | 700 (dir), 600 (files) |
| `~/.aidevops/` | **Working directories** (agno, stagehand, reports) | Standard |

## Security Principle

**API keys are stored ONLY in `~/.config/aidevops/credentials.sh`, NEVER in repository files.**

This file is automatically sourced by your shell (zsh and bash) on startup.

## Setup Instructions

### 1. Initialize Secure Storage

```bash
bash ~/Git/aidevops/.agents/scripts/setup-local-api-keys.sh setup
```

This will:

- Create `~/.config/aidevops/` with secure permissions
- Create `credentials.sh` for storing API keys
- Add sourcing to your shell configs (`.zshrc`, `.bashrc`, `.bash_profile`)

### 2. Store API Keys

#### Method A: Using the helper script

```bash
# Service name format (converted to UPPER_CASE)
bash .agents/scripts/setup-local-api-keys.sh set vercel-token YOUR_TOKEN
# Result: export VERCEL_TOKEN="YOUR_TOKEN"

bash .agents/scripts/setup-local-api-keys.sh set sonar YOUR_TOKEN
# Result: export SONAR="YOUR_TOKEN"
```

#### Method B: Paste export commands from services

Many services give you an export command like:

```bash
export VERCEL_TOKEN="abc123"
```

Use the `add` command to parse and store it:

```bash
bash .agents/scripts/setup-local-api-keys.sh add 'export VERCEL_TOKEN="abc123"'
```

#### Method C: Direct env var name

```bash
bash .agents/scripts/setup-local-api-keys.sh set SUPABASE_KEY abc123
# Result: export SUPABASE_KEY="abc123"
```

### 3. Common Services

```bash
# Codacy - https://app.codacy.com/account/api-tokens
bash .agents/scripts/setup-local-api-keys.sh set codacy-project-token YOUR_TOKEN

# SonarCloud - https://sonarcloud.io/account/security
bash .agents/scripts/setup-local-api-keys.sh set sonar-token YOUR_TOKEN

# CodeRabbit - https://app.coderabbit.ai/settings
bash .agents/scripts/setup-local-api-keys.sh set coderabbit-api-key YOUR_KEY

# Hetzner Cloud - https://console.hetzner.cloud/projects/*/security/tokens
bash .agents/scripts/setup-local-api-keys.sh set hcloud-token-projectname YOUR_TOKEN

# OpenAI - https://platform.openai.com/api-keys
bash .agents/scripts/setup-local-api-keys.sh set openai-api-key YOUR_KEY
```

### 4. Verify Storage

```bash
# List configured services (keys are not shown)
bash .agents/scripts/setup-local-api-keys.sh list

# Get a specific key
bash .agents/scripts/setup-local-api-keys.sh get sonar-token

# View the file directly (redacted)
cat ~/.config/aidevops/credentials.sh | sed 's/=.*/=<REDACTED>/'
```

## How It Works

1. **credentials.sh** contains all API keys as shell exports:

   ```bash
   export SONAR_TOKEN="xxx"
   export OPENAI_API_KEY="xxx"
   ```

2. **Shell startup** sources this file automatically:

   ```bash
   # In ~/.zshrc and ~/.bashrc:
   [[ -f ~/.config/aidevops/credentials.sh ]] && source ~/.config/aidevops/credentials.sh
   ```

3. **All processes** (terminals, scripts, MCPs) get access to the env vars

## Storage Locations

### Secrets (Secure - 600 permissions)

- `~/.config/aidevops/credentials.sh` - All API keys and tokens

### Working Directories (Standard permissions)

- `~/.aidevops/agno/` - Agno AI framework
- `~/.aidevops/agent-ui/` - Agent UI frontend
- `~/.aidevops/stagehand/` - Browser automation
- `~/.aidevops/reports/` - Generated reports
- `~/.aidevops/mcp/` - MCP configurations

### NEVER Store In

- Repository files (any file in `~/Git/aidevops/`)
- Documentation or code examples
- Git-tracked configuration files

## Security Features

### File Permissions

```bash
# Verify permissions
ls -la ~/.config/aidevops/
# drwx------ (700) for directory
# -rw------- (600) for credentials.sh
```

### Fix Permissions

```bash
chmod 700 ~/.config/aidevops
chmod 600 ~/.config/aidevops/credentials.sh
```

## Troubleshooting

### Key Not Found

```bash
# Check if stored
bash .agents/scripts/setup-local-api-keys.sh get service-name

# Check environment
echo $SERVICE_NAME

# Re-add if missing
bash .agents/scripts/setup-local-api-keys.sh set service-name YOUR_KEY
```

### Changes Not Taking Effect

```bash
# Reload shell config
source ~/.zshrc  # or ~/.bashrc

# Or restart terminal
```

### Shell Integration Missing

```bash
# Re-run setup to add sourcing to shell configs
bash .agents/scripts/setup-local-api-keys.sh setup
```

## Multi-Tenant Support

For managing multiple accounts (clients, environments, organizations):

```bash
# Initialize multi-tenant storage
credential-helper.sh init

# Create per-client tenants
credential-helper.sh create client-acme
credential-helper.sh set GITHUB_TOKEN ghp_xxx --tenant client-acme

# Switch globally or per-project
credential-helper.sh switch client-acme
credential-helper.sh use client-acme  # per-project override
```

See `multi-tenant.md` for full documentation.

## Best Practices

1. **Use gopass** - Prefer `aidevops secret set` for encrypted storage
2. **Single source** - Always add keys via `aidevops secret set`, `setup-local-api-keys.sh`, or `credential-helper.sh`
3. **Regular rotation** - Rotate API keys every 90 days
4. **Minimal permissions** - Use tokens with minimal required scopes
5. **Monitor usage** - Check API usage in provider dashboards
6. **Never commit** - API keys should never appear in git history
7. **Use tenants** - Separate client/environment credentials with multi-tenant storage
8. **AI-safe** - Never accept secret values in AI conversation context

## Encrypted Storage (Recommended)

For encrypted secret storage with gopass, see `tools/credentials/gopass.md`.

```bash
# Quick start
aidevops secret init              # One-time setup
aidevops secret set API_KEY       # Store (hidden input)
aidevops secret run some-command  # Use (injected + redacted)
```
