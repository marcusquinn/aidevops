# API Key Setup Guide - Secure Local Storage

## Directory Structure

AI DevOps uses two directories for different purposes:

| Location | Purpose | Permissions |
|----------|---------|-------------|
| `~/.config/aidevops/` | **Secrets & credentials** | 700 (dir), 600 (files) |
| `~/.aidevops/` | **Working directories** (agno, stagehand, reports) | Standard |

## Security Principle

**API keys are stored ONLY in `~/.config/aidevops/mcp-env.sh`, NEVER in repository files.**

This file is automatically sourced by your shell (zsh and bash) on startup.

## Setup Instructions

### 1. Initialize Secure Storage

```bash
bash ~/git/aidevops/.agent/scripts/setup-local-api-keys.sh setup
```

This will:

- Create `~/.config/aidevops/` with secure permissions
- Create `mcp-env.sh` for storing API keys
- Add sourcing to your shell configs (`.zshrc`, `.bashrc`, `.bash_profile`)

### 2. Store API Keys

#### Method A: Using the helper script

```bash
# Service name format (converted to UPPER_CASE)
bash .agent/scripts/setup-local-api-keys.sh set vercel-token YOUR_TOKEN
# Result: export VERCEL_TOKEN="YOUR_TOKEN"

bash .agent/scripts/setup-local-api-keys.sh set sonar YOUR_TOKEN
# Result: export SONAR="YOUR_TOKEN"
```

#### Method B: Paste export commands from services

Many services give you an export command like:

```bash
export VERCEL_TOKEN="abc123"
```

Use the `add` command to parse and store it:

```bash
bash .agent/scripts/setup-local-api-keys.sh add 'export VERCEL_TOKEN="abc123"'
```

#### Method C: Direct env var name

```bash
bash .agent/scripts/setup-local-api-keys.sh set SUPABASE_KEY abc123
# Result: export SUPABASE_KEY="abc123"
```

### 3. Common Services

```bash
# Codacy - https://app.codacy.com/account/api-tokens
bash .agent/scripts/setup-local-api-keys.sh set codacy-project-token YOUR_TOKEN

# SonarCloud - https://sonarcloud.io/account/security
bash .agent/scripts/setup-local-api-keys.sh set sonar-token YOUR_TOKEN

# CodeRabbit - https://app.coderabbit.ai/settings
bash .agent/scripts/setup-local-api-keys.sh set coderabbit-api-key YOUR_KEY

# Hetzner Cloud - https://console.hetzner.cloud/projects/*/security/tokens
bash .agent/scripts/setup-local-api-keys.sh set hcloud-token-projectname YOUR_TOKEN

# OpenAI - https://platform.openai.com/api-keys
bash .agent/scripts/setup-local-api-keys.sh set openai-api-key YOUR_KEY
```

### 4. Verify Storage

```bash
# List configured services (keys are not shown)
bash .agent/scripts/setup-local-api-keys.sh list

# Get a specific key
bash .agent/scripts/setup-local-api-keys.sh get sonar-token

# View the file directly (redacted)
cat ~/.config/aidevops/mcp-env.sh | sed 's/=.*/=<REDACTED>/'
```

## How It Works

1. **mcp-env.sh** contains all API keys as shell exports:

   ```bash
   export SONAR_TOKEN="xxx"
   export OPENAI_API_KEY="xxx"
   ```

2. **Shell startup** sources this file automatically:

   ```bash
   # In ~/.zshrc and ~/.bashrc:
   [[ -f ~/.config/aidevops/mcp-env.sh ]] && source ~/.config/aidevops/mcp-env.sh
   ```

3. **All processes** (terminals, scripts, MCPs) get access to the env vars

## Storage Locations

### Secrets (Secure - 600 permissions)

- `~/.config/aidevops/mcp-env.sh` - All API keys and tokens

### Working Directories (Standard permissions)

- `~/.aidevops/agno/` - Agno AI framework
- `~/.aidevops/agent-ui/` - Agent UI frontend
- `~/.aidevops/stagehand/` - Browser automation
- `~/.aidevops/reports/` - Generated reports
- `~/.aidevops/mcp/` - MCP configurations

### NEVER Store In

- Repository files (any file in `~/git/aidevops/`)
- Documentation or code examples
- Git-tracked configuration files

## Security Features

### File Permissions

```bash
# Verify permissions
ls -la ~/.config/aidevops/
# drwx------ (700) for directory
# -rw------- (600) for mcp-env.sh
```

### Fix Permissions

```bash
chmod 700 ~/.config/aidevops
chmod 600 ~/.config/aidevops/mcp-env.sh
```

## Troubleshooting

### Key Not Found

```bash
# Check if stored
bash .agent/scripts/setup-local-api-keys.sh get service-name

# Check environment
echo $SERVICE_NAME

# Re-add if missing
bash .agent/scripts/setup-local-api-keys.sh set service-name YOUR_KEY
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
bash .agent/scripts/setup-local-api-keys.sh setup
```

## Best Practices

1. **Single source** - Always add keys via `setup-local-api-keys.sh`, never paste directly into `.zshrc`
2. **Regular rotation** - Rotate API keys every 90 days
3. **Minimal permissions** - Use tokens with minimal required scopes
4. **Monitor usage** - Check API usage in provider dashboards
5. **Never commit** - API keys should never appear in git history
