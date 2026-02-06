---
description: gopass encrypted secret management with AI-native wrapper
mode: subagent
tools:
  read: true
  write: false
  edit: false
  bash: true
  glob: false
  grep: false
  webfetch: false
  task: false
---

# gopass - Encrypted Secret Management

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Backend**: gopass (GPG/age encrypted, git-versioned, team-shareable)
- **CLI**: `aidevops secret <command>` or `secret-helper.sh <command>`
- **Store path**: `~/.local/share/gopass/stores/root/aidevops/`
- **Fallback**: `~/.config/aidevops/credentials.sh` (plaintext, chmod 600)

**Commands**:

- `aidevops secret set NAME` -- Store secret (interactive hidden input)
- `aidevops secret list` -- List names only (never values)
- `aidevops secret run CMD` -- Inject all secrets, redact output
- `aidevops secret NAME -- CMD` -- Inject specific secrets, redact output
- `aidevops secret init` -- Initialize gopass store
- `aidevops secret import-credentials` -- Migrate from credentials.sh
- `aidevops secret status` -- Show backend status

**CRITICAL**: NEVER use `gopass show`, `gopass cat`, or any command that prints secret values in agent context. Use `aidevops secret run` for subprocess injection with automatic output redaction.

<!-- AI-CONTEXT-END -->

## Why gopass

| Feature | gopass | credentials.sh |
|---------|--------|----------------|
| Encryption at rest | GPG/age | None (plaintext) |
| Team sharing | Git sync + GPG recipients | Manual copy |
| Audit trail | Git history | None |
| AI-safe | Subprocess injection + redaction | Agent can `cat` the file |
| Breach detection | `gopass audit` + HIBP | None |

## Installation

```bash
# macOS
brew install gopass

# Linux (Debian/Ubuntu)
apt install gopass

# Linux (Arch)
pacman -S gopass

# Or via aidevops
aidevops secret init  # Auto-installs if missing
```

### Prerequisites

- **GPG**: Required for encryption (`brew install gnupg`)
- **pinentry-mac**: Required on macOS for passphrase entry (`brew install pinentry-mac`)
- **git**: Required for versioned storage (already required by aidevops)

## Setup

```bash
# Initialize gopass (creates GPG key if needed)
aidevops secret init

# Import existing credentials from credentials.sh
aidevops secret import-credentials

# Verify
aidevops secret list
aidevops secret status
```

## Usage

### Storing Secrets

```bash
# Interactive hidden input (value never visible)
aidevops secret set GITHUB_TOKEN
aidevops secret set OPENAI_API_KEY
aidevops secret set STRIPE_SECRET_KEY
```

### Using Secrets in Commands

```bash
# Inject all secrets into a command (output redacted)
aidevops secret run npx some-mcp-server

# Inject specific secrets only
aidevops secret GITHUB_TOKEN -- gh api /user
aidevops secret STRIPE_SECRET_KEY -- curl https://api.stripe.com/v1/charges

# MCP server with secrets (replaces: source credentials.sh && npx server)
aidevops secret run npx @anthropic/mcp-server-github
```

### Listing Secrets

```bash
# Names only (never values)
aidevops secret list

# Backend status
aidevops secret status
```

## Team Sharing

gopass uses GPG recipients for team access:

```bash
# Add team member's GPG key
gpg --import teammate-public-key.asc

# Add as gopass recipient
gopass recipients add teammate@example.com

# Sync via git
gopass sync
```

## Agent Instructions

When an AI agent needs a secret:

1. Agent instructs user: "Please run: `aidevops secret set SECRET_NAME`"
2. User runs command at terminal (value entered with hidden input)
3. Agent uses secret via: `aidevops secret SECRET_NAME -- command`
4. Output is automatically redacted

**Prohibited commands** (NEVER run in agent context):

- `gopass show` / `gopass cat` -- prints secret values
- `cat ~/.config/aidevops/credentials.sh` -- exposes plaintext
- `echo $SECRET_NAME` -- leaks to agent context
- `env | grep` -- exposes environment variables

## psst Alternative

For solo developers who prefer simplicity, [psst](https://github.com/nicholasgasior/psst) is a documented alternative:

- Simpler setup (Bun-based, no GPG)
- AI-native design (built for agent workflows)
- Trade-offs: v0.3.0, 61 stars, no team features, Bun dependency

See `tools/credentials/psst.md` for psst documentation.

## Architecture

```text
                    User Terminal (interactive)
                           |
                    aidevops secret set NAME
                           |
                    gopass insert aidevops/NAME
                           |
              ~/.local/share/gopass/stores/root/
              (GPG-encrypted files, git-versioned)
                           |
              aidevops secret NAME -- command
                           |
              1. gopass show -o aidevops/NAME
              2. Inject into subprocess env
              3. Execute command
              4. Redact output
              5. Return exit code
```

## Related

- `tools/credentials/api-key-setup.md` -- Plaintext credential setup
- `tools/credentials/multi-tenant.md` -- Multi-tenant credential storage
- `tools/credentials/psst.md` -- psst alternative for solo devs
- `tools/credentials/list-keys.md` -- List configured keys
- `.agents/scripts/secret-helper.sh` -- Implementation
- `.agents/scripts/credential-helper.sh` -- Multi-tenant plaintext backend
