---
description: Terminal tab/window title integration for git context
mode: subagent
tools:
  read: true
  write: false
  edit: false
  bash: true
  glob: true
  grep: true
  webfetch: false
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Terminal Title Integration

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Purpose**: Sync terminal tab titles with git repo/branch via OSC escape sequences
- **Script**: `~/.aidevops/agents/scripts/terminal-title-helper.sh`
- **Auto-sync**: Runs via `pre-edit-check.sh` on feature branches in git repos
- **Session sync**: OpenCode session titles auto-sync in `pre-edit-check.sh`; force via `session-rename_sync_branch`

**Commands**:

```bash
terminal-title-helper.sh sync              # Sync tab with current repo/branch
terminal-title-helper.sh rename "My Project"  # Set custom title
terminal-title-helper.sh reset             # Reset to default
terminal-title-helper.sh detect            # Check terminal compatibility
```

**Title Formats** (set via `TERMINAL_TITLE_FORMAT`):

| Format | Example |
|--------|---------|
| `repo/branch` (default) | `aidevops/feature/xyz` |
| `branch` | `feature/xyz` |
| `repo` | `aidevops` |
| `branch/repo` | `feature/xyz (aidevops)` |

**Environment Variables**:

| Variable | Default | Description |
|----------|---------|-------------|
| `TERMINAL_TITLE_FORMAT` | `repo/branch` | Title format |
| `TERMINAL_TITLE_ENABLED` | `true` | Set `false` to disable |

<!-- AI-CONTEXT-END -->

## How It Works

Uses OSC escape sequences (`printf '\033]0;%s\007' "title"`). **Full support**: Tabby, iTerm2, Windows Terminal, Kitty, Alacritty, WezTerm, Hyper, GNOME Terminal, Konsole, VS Code Terminal, xterm. **Partial**: Apple Terminal (basic), tmux/screen (requires config).

## Shell Integration

| Shell | Config file | Hook |
|-------|-------------|------|
| Bash | `~/.bashrc` | `PROMPT_COMMAND='terminal-title-helper.sh sync 2>/dev/null'` |
| Zsh | `~/.zshrc` | `precmd() { terminal-title-helper.sh sync 2>/dev/null }` |
| Fish | `~/.config/fish/config.fish` | `function fish_prompt; terminal-title-helper.sh sync 2>/dev/null; end` |

## Troubleshooting

- **Not updating**: Run `terminal-title-helper.sh detect`. Verify git repo (`git rev-parse --is-inside-work-tree`) and `TERMINAL_TITLE_ENABLED != false`.
- **Wrong format**: `echo $TERMINAL_TITLE_FORMAT`
- **tmux** (`~/.tmux.conf`): `set -g set-titles on` + `set -g set-titles-string "#T"`
- **screen** (`~/.screenrc`): `termcapinfo xterm* ti@:te@`
- **VS Code**: Enable "Terminal > Integrated: Allow Workspace Shell"

## Related

- `workflows/git-workflow.md` - Git workflow with branch naming
- `workflows/branch.md` - Branch creation and lifecycle
- `tools/opencode/opencode.md` - OpenCode session management
