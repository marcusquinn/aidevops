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

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# gopass - Encrypted Secret Management

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Backend**: gopass (GPG/age encrypted, git-versioned, team-shareable)
- **CLI**: `aidevops secret <command>` or `secret-helper.sh <command>`
- **Store path**: `~/.local/share/gopass/stores/root/aidevops/`
- **Fallback**: `~/.config/aidevops/credentials.sh` (plaintext, chmod 600)

| Command | Purpose |
|---------|---------|
| `aidevops secret set NAME` | Store secret (interactive hidden input) |
| `aidevops secret list` | List names only (never values) |
| `aidevops secret run CMD` | Inject all secrets, redact output |
| `aidevops secret NAME -- CMD` | Inject specific secret, redact output |
| `aidevops secret init` | Initialize gopass store |
| `aidevops secret import-credentials` | Migrate from credentials.sh |
| `aidevops secret status` | Show backend status |

**CRITICAL**: NEVER use `gopass show`, `gopass cat`, or any command that prints secret values in agent context.

<!-- AI-CONTEXT-END -->

## Installation

```bash
brew install gopass          # macOS
apt install gopass           # Debian/Ubuntu
pacman -S gopass             # Arch
aidevops secret init         # Auto-installs if missing
```

**Prerequisites**: `brew install gnupg pinentry-mac` (macOS); git (already required).

## Setup

```bash
aidevops secret init                 # Creates GPG key if needed
aidevops secret import-credentials  # Migrate from credentials.sh
```

## Usage

### Storing Secrets

Run in your own terminal — never paste values into AI chat:

```bash
aidevops secret set GITHUB_TOKEN     # Enter raw value at hidden prompt
aidevops secret set OPENAI_API_KEY
```

Verify with `aidevops secret list`.

### Using Secrets in Commands

```bash
aidevops secret run npx some-mcp-server          # Inject all secrets, redact output
aidevops secret GITHUB_TOKEN -- gh api /user     # Inject specific secret
```

## Team Sharing

```bash
gpg --import teammate-public-key.asc
gopass recipients add teammate@example.com
gopass sync
```

## Agent Instructions

Warn user before requesting a secret:

> Never paste secret values into AI chat. Run `aidevops secret set SECRET_NAME` in your terminal.

Then use: `aidevops secret SECRET_NAME -- command` (output auto-redacted).

**Env var, not argument**: ALWAYS inject secrets as env vars, never command arguments — args appear in `ps`, error messages, and logs. `aidevops secret NAME -- cmd` handles this automatically. See `reference/secret-handling.md` §8.3.

**Prohibited** (NEVER run in agent context):

- `gopass show` / `gopass cat` — prints secret values
- `cat ~/.config/aidevops/credentials.sh` — exposes plaintext
- `echo $SECRET_NAME` / `env | grep` — leaks to agent context
- `cmd "$SECRET"` — secret as argument, visible in `ps` and error output

## Encryption Stack

gopass handles individual secrets (API keys, tokens, passwords). For other needs:

- **Config files in git**: SOPS — `tools/credentials/sops.md`
- **Directory encryption**: gocryptfs — `tools/credentials/gocryptfs.md`
- **Decision guide**: `tools/credentials/encryption-stack.md`

## Related

- `tools/credentials/encryption-stack.md` — Full encryption stack and decision tree
- `tools/credentials/sops.md` — SOPS config file encryption
- `tools/credentials/gocryptfs.md` — gocryptfs directory encryption
- `tools/credentials/api-key-setup.md` — Plaintext credential setup
- `tools/credentials/multi-tenant.md` — Multi-tenant credential storage
- `tools/credentials/psst.md` — psst alternative for solo devs (no GPG)
- `tools/credentials/list-keys.md` — List configured keys
- `.agents/scripts/secret-helper.sh` — Implementation
- `.agents/scripts/credential-helper.sh` — Multi-tenant plaintext backend
