---
description: AI assistant guide for setup.sh script
mode: subagent
tools:
  read: true
  write: true
  edit: true
  bash: true
  glob: true
  grep: true
  webfetch: false
---

# Setup Guide - AI Assistant for setup.sh

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Script**: `~/Git/aidevops/setup.sh`
- **Run**: `cd ~/Git/aidevops && ./setup.sh`
- **Update**: `git pull && ./setup.sh` (backs up existing configs automatically)
- **Agents**: `~/.aidevops/agents/` | **Backups**: `~/.aidevops/config-backups/` | **Credentials**: `~/.config/aidevops/credentials.sh`

**What setup.sh does**: checks required deps (`jq`, `curl`, `ssh`, `sqlite3`) and optional deps (`sshpass`, `gh`, `glab`, `tea`); copies `.agents/` → `~/.aidevops/agents/` with timestamped config backups; injects AGENTS.md pointer into `~/.opencode/AGENTS.md`, `~/.cursor/AGENTS.md`, `~/.claude/AGENTS.md`, `~/.config/cursor/AGENTS.md`; updates OpenCode agent paths in `~/.config/opencode/opencode.json`.

<!-- AI-CONTEXT-END -->

## Deployed Structure

```text
~/.aidevops/
├── agents/
│   ├── AGENTS.md             # User entry point
│   ├── aidevops/             # Subagent folders
│   ├── tools/
│   ├── services/
│   ├── workflows/
│   └── scripts/              # Helper scripts
└── config-backups/[YYYYMMDD_HHMMSS]/
```

## Manual Configuration

If setup.sh doesn't support your AI assistant, add to its AGENTS.md or config:

```text
Add ~/.aidevops/agents/AGENTS.md to context for AI DevOps capabilities.
```

Then point agent configurations to `~/.aidevops/agents/[agent].md`.

## Troubleshooting

**Missing deps:**

```bash
brew install jq curl sqlite3    # macOS
apt-get install jq curl sqlite3 # Ubuntu/Debian
```

**OpenCode not finding agents:** Check `~/.config/opencode/opencode.json` paths; verify `~/.aidevops/agents/` exists. See `tools/opencode/opencode.md`.

**Permissions:**

```bash
chmod 600 ~/.config/aidevops/credentials.sh
chmod 755 ~/.aidevops/agents/scripts/*.sh
```
