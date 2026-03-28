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

- **Recommended**: `aidevops secret set NAME` (gopass encrypted, AI-safe) — see `gopass.md`
- **Plaintext fallback**: `~/.config/aidevops/credentials.sh` (600 permissions)
- **Setup**: `bash ~/Git/aidevops/.agents/scripts/setup-local-api-keys.sh setup`
- **Multi-tenant**: `credential-helper.sh` — see `multi-tenant.md`
- **Common Services**: codacy-project-token, sonar-token, coderabbit-api-key, hcloud-token-*, openai-api-key

**Security**: NEVER accept secret values in AI conversation. Instruct users to run `aidevops secret set NAME` at their terminal.

<!-- AI-CONTEXT-END -->

## Storage Layout

| Location | Purpose | Permissions |
|----------|---------|-------------|
| `~/.config/aidevops/credentials.sh` | API keys as shell exports | 600 |
| `~/.config/aidevops/tenants/{tenant}/credentials.sh` | Per-tenant keys (see `multi-tenant.md`) | 600 |
| `~/.config/aidevops/` | Secrets directory | 700 |

**Principle**: API keys are stored ONLY under `~/.config/aidevops/` (default `credentials.sh`, or `tenants/{tenant}/credentials.sh` for multi-tenant) or in gopass — NEVER in repository files. The active credentials file is sourced by your shell on startup.

## Setup

### 1. Initialize

```bash
bash ~/Git/aidevops/.agents/scripts/setup-local-api-keys.sh setup
```

Creates `~/.config/aidevops/` (700), `credentials.sh` (600), and adds sourcing to `.zshrc`/`.bashrc`/`.bash_profile`.

### 2. Store API Keys

Run from the repository root:

```bash
# By service name (auto-converts to UPPER_CASE export)
bash .agents/scripts/setup-local-api-keys.sh set vercel-token YOUR_TOKEN
# → export VERCEL_TOKEN="YOUR_TOKEN"

# By env var name directly
bash .agents/scripts/setup-local-api-keys.sh set SUPABASE_KEY abc123
# → export SUPABASE_KEY="abc123"

# Parse an export command from a service dashboard
bash .agents/scripts/setup-local-api-keys.sh add 'export VERCEL_TOKEN="abc123"'
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

### 4. Verify

```bash
bash .agents/scripts/setup-local-api-keys.sh list   # Services (keys redacted)
bash .agents/scripts/setup-local-api-keys.sh get sonar-token  # Specific key
```

## How It Works

`credentials.sh` contains shell exports (`export SONAR_TOKEN="xxx"`). Shell startup sources it automatically:

```bash
# Added to ~/.zshrc, ~/.bashrc, and ~/.bash_profile by setup:
[[ -f ~/.config/aidevops/credentials.sh ]] && source ~/.config/aidevops/credentials.sh
```

All processes (terminals, scripts, MCPs) inherit these env vars.

## Permissions

```bash
# Verify
ls -la ~/.config/aidevops/
# drwx------ (700) directory, -rw------- (600) credentials.sh

# Fix if needed
chmod 700 ~/.config/aidevops && chmod 600 ~/.config/aidevops/credentials.sh
```

## Troubleshooting

**Key not found**: Check storage (`setup-local-api-keys.sh get service-name`), check env (`echo $SERVICE_NAME`), re-add if missing.

**Changes not taking effect**: `source ~/.zshrc` (or `~/.bashrc`), or restart terminal.

**Shell integration missing**: Re-run `setup-local-api-keys.sh setup` to add sourcing lines.

## Best Practices

1. **Prefer gopass** — `aidevops secret set` for encrypted storage
2. **Single source** — always add keys via `aidevops secret set`, `setup-local-api-keys.sh`, or `credential-helper.sh`
3. **Rotate every 90 days**, use minimal-scope tokens, monitor usage in provider dashboards
4. **Never commit** — API keys must never appear in git history
5. **AI-safe** — never accept secret values in AI conversation context

## Beyond API Keys

- **Encrypted storage (recommended)**: `tools/credentials/gopass.md`
- **Multi-tenant credentials**: `tools/credentials/multi-tenant.md`
- **Config files in git** (YAML/JSON with encrypted values): `tools/credentials/sops.md`
- **Directory encryption at rest**: `tools/credentials/gocryptfs.md`
- **Decision guide**: `tools/credentials/encryption-stack.md`
- **Project setup**: `aidevops init sops` to add SOPS support
