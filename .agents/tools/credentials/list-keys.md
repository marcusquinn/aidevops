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
- **Purpose**: Show available API key names plus source paths
- **Security**: Names and locations only — never values

**Key sources** (checked in order):
1. `~/.config/aidevops/credentials.sh` — primary credential store (600 perms)
2. Shell configs (`~/.zshrc`, `~/.bashrc`, etc.) — exported credential patterns
3. Environment variables — session-only keys such as `*_KEY`, `*_TOKEN`, `*_SECRET`
4. `~/.config/coderabbit/api_key` — CodeRabbit CLI token
5. `configs/*-config.json` — repo-specific configs (gitignored)

<!-- AI-CONTEXT-END -->

## Usage

```bash
~/.aidevops/agents/scripts/list-keys-helper.sh
/list-keys
```

## Output

Shows a table with:
- key name
- source path
- status in the current session

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

| Status | Meaning |
|--------|---------|
| `[loaded]` | Valid value is loaded in the session |
| `[placeholder]` | Placeholder value such as `YOUR_KEY_HERE`, `changeme`, or `xxx` |
| `[not loaded]` | Defined but not loaded in the current session |
| `[configured]` | Present in a config file |

Placeholder detection covers:
- `YOUR_*_HERE`, `REPLACE_*`, `CHANGEME`, `FIXME`, `TODO`
- `example`, `sample`, `test-key`, `dummy`, `fake`
- `xxx`, `yyy`, `zzz`, `placeholder`, `none`, `null`
- template markers: `<...>`, `{...}`, `[...]`
- repeated characters: `xxxx`, `0000`, etc.

## Security Notes

- Never displays actual key values
- Only reports key names and storage locations
- Use `echo "${KEY_NAME:0:10}..."` only to confirm a specific key exists
- Credential files should have 600 permissions

## Integration

Called by:
- `/list-keys`
- `@list-keys`
- `api-keys list` (simplified action)
