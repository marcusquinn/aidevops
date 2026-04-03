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

- **Command**: `/list-keys` or `@list-keys` or `api-keys list`
- **Script**: `~/.aidevops/agents/scripts/list-keys-helper.sh`
- **Security**: Names and locations only — never values. To confirm a specific key exists: `echo "${KEY_NAME:0:10}..."`. Credential files must have 600 permissions.

**Key sources** (checked in order):
1. `~/.config/aidevops/credentials.sh` — primary credential store (600 perms)
2. Shell configs (`~/.zshrc`, `~/.bashrc`, etc.) — exported credential patterns
3. Environment variables — session-only keys such as `*_KEY`, `*_TOKEN`, `*_SECRET`
4. `~/.config/coderabbit/api_key` — CodeRabbit CLI token
5. `configs/*-config.json` — repo-specific configs (gitignored)

<!-- AI-CONTEXT-END -->

## Output

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
| `[loaded]` | Valid value loaded in session |
| `[placeholder]` | Placeholder detected: `YOUR_*_HERE`, `REPLACE_*`, `CHANGEME`, `FIXME`, `TODO`, `example`, `sample`, `test-key`, `dummy`, `fake`, `xxx`/`yyy`/`zzz`, `placeholder`, `none`, `null`, template markers (`<...>`, `{...}`, `[...]`), repeated chars (`xxxx`, `0000`) |
| `[not loaded]` | Defined but not loaded in current session |
| `[configured]` | Present in a config file |
