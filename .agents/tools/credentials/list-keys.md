---
description: List all API keys available in the user session with their storage locations
mode: subagent
tools:
  read: true
  write: false
  edit: false
  bash: true
  glob: true
  grep: true
  webfetch: false
  task: false
---

# List Keys - API Key Discovery

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Command**: `/list-keys` or `@list-keys`
- **Script**: `~/.aidevops/agents/scripts/list-keys-helper.sh`
- **Purpose**: Show all API keys available in the session with their file paths
- **Security**: Shows key names only, never exposes actual values

**Key Sources** (checked in order):
1. `~/.config/aidevops/credentials.sh` - Primary credential store (600 permissions)
2. `~/.zshrc`, `~/.bashrc`, etc. - Shell config exports (credential patterns)
3. Environment variables - Session-only keys matching `*_KEY`, `*_TOKEN`, `*_SECRET`, etc.
4. `~/.config/coderabbit/api_key` - CodeRabbit CLI token
5. `configs/*-config.json` - Repository-specific configs (gitignored)

<!-- AI-CONTEXT-END -->

## Usage

```bash
# List all keys with sources
~/.aidevops/agents/scripts/list-keys-helper.sh

# Or use the command
/list-keys
```

## Output Format

The script outputs a table showing:
- Key name (environment variable name)
- Source file path
- Status (loaded/not loaded in current session)

Example output:

```text
API Keys Available in Session
=============================

Source: ~/.config/aidevops/credentials.sh
  OPENAI_API_KEY          [loaded]
  ANTHROPIC_API_KEY       [loaded]
  CLOUDFLARE_API_KEY      [loaded]

Source: Shell configs (~/.zshrc, ~/.bashrc, etc.)
  CUSTOM_API_KEY          [loaded]

Source: Environment (shell session)
  GITHUB_TOKEN            [loaded]
  NPM_TOKEN               [loaded]

Source: ~/.config/coderabbit/api_key
  CODERABBIT_API_KEY      [loaded]

Total: 7 keys from 4 sources
```

## Status Indicators

| Status | Color | Meaning |
|--------|-------|---------|
| `[loaded]` | Green | Key has a valid value in the session |
| `[placeholder]` | Red | Key contains a placeholder value (e.g., `YOUR_KEY_HERE`, `changeme`, `xxx`) |
| `[not loaded]` | Yellow | Key is defined but not loaded in current session |
| `[configured]` | Blue | Key exists in a config file |

### Placeholder Detection

The script detects common placeholder patterns:
- `YOUR_*_HERE`, `REPLACE_*`, `CHANGEME`, `FIXME`, `TODO`
- `example`, `sample`, `test-key`, `dummy`, `fake`
- `xxx`, `yyy`, `zzz`, `placeholder`, `none`, `null`
- Template markers: `<...>`, `{...}`, `[...]`
- Repeated characters: `xxxx`, `0000`, etc.

## Security Notes

- This tool NEVER displays actual key values
- Only shows key names and their storage locations
- Use `echo "${KEY_NAME:0:10}..."` to verify a specific key exists
- All credential files should have 600 permissions

## Integration

This subagent is called by:
- `/list-keys` slash command
- `@list-keys` agent reference
- `api-keys list` tool action (simplified version)
