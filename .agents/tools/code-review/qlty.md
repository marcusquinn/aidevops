---
description: Qlty CLI for multi-linter code quality
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

# Qlty CLI Configuration Guide

<!-- AI-CONTEXT-START -->

## Quick Reference

- Qlty: Universal code quality for 40+ languages, 70+ tools
- Credential priority: Account API Key (`qltp_...`) > Coverage Token (`qltcw_...`) > Workspace ID (UUID)
- Store credentials: `bash .agents/scripts/setup-local-api-keys.sh set qlty-account-api-key KEY`
- Organization-specific: `set qlty-ORGNAME TOKEN`, `set qlty-ORGNAME-workspace-id UUID`
- Commands: `bash .agents/scripts/qlty-cli.sh install|init|check|fmt --all|smells --all [ORG]`
- Storage: `~/.config/aidevops/api-keys` (600 permissions)
- Path: Ensure `~/.qlty/bin` in PATH

<!-- AI-CONTEXT-END -->

## Credentials

Three types, selected in priority order:

| Type | Key format | Scope |
|------|-----------|-------|
| Account API Key | `qltp_...` | Account-wide (preferred) |
| Coverage Token | `qltcw_...` | Org-specific fallback |
| Workspace ID | UUID | Context identifier (optional) |

Storage format in `~/.config/aidevops/api-keys`:

```bash
qlty-account-api-key=qltp_your_account_api_key_here
qlty-ORGNAME=qltcw_your_coverage_token_here
qlty-ORGNAME-workspace-id=your-workspace-uuid-here
```

## Setup

```bash
# Store credentials
bash .agents/scripts/setup-local-api-keys.sh set qlty-account-api-key YOUR_ACCOUNT_API_KEY
bash .agents/scripts/setup-local-api-keys.sh set qlty-ORGNAME YOUR_COVERAGE_TOKEN        # org fallback
bash .agents/scripts/setup-local-api-keys.sh set qlty-ORGNAME-workspace-id YOUR_UUID     # optional context

# Install and initialise
bash .agents/scripts/qlty-cli.sh install
bash .agents/scripts/qlty-cli.sh init

# Verify
bash .agents/scripts/setup-local-api-keys.sh list
bash .agents/scripts/qlty-cli.sh help
```

## Usage

```bash
# Default org
bash .agents/scripts/qlty-cli.sh check
bash .agents/scripts/qlty-cli.sh fmt --all
bash .agents/scripts/qlty-cli.sh smells --all

# Specific org
bash .agents/scripts/qlty-cli.sh check 10 ORGNAME
bash .agents/scripts/qlty-cli.sh fmt --all ORGNAME
bash .agents/scripts/qlty-cli.sh smells --all ORGNAME
```

## Multi-Org

Naming convention: `qlty-ORGNAME` (token), `qlty-ORGNAME-workspace-id` (UUID). Commands accept `ORGNAME` as last argument.

To add an org: obtain Coverage Token + Workspace ID from Qlty dashboard, store with `setup-local-api-keys.sh`.

## Integration

```bash
# Via Quality CLI Manager
bash .agents/scripts/quality-cli-manager.sh install all
bash .agents/scripts/quality-cli-manager.sh analyze qlty
```

GitHub Actions: use Coverage Token and Workspace ID as repository secrets.

## Troubleshooting

| Problem | Fix |
|---------|-----|
| Token not found | `setup-local-api-keys.sh list` |
| CLI not found | Add `~/.qlty/bin` to PATH |
| Permission denied | Check `~/.config/aidevops/api-keys` is mode 600 |
| Org not recognised | Verify `qlty-ORGNAME` naming matches command arg |

```bash
qlty --version
bash .agents/scripts/qlty-cli.sh check 1 ORGNAME
```
