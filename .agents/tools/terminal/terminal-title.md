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

# Terminal Title Integration

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Purpose**: Sync terminal tab titles with git repo/branch via OSC escape sequences
- **Script**: `~/.aidevops/agents/scripts/terminal-title-helper.sh`
- **Auto-sync**: Runs automatically via `pre-edit-check.sh` when on a feature branch in a git repo
- **Session sync**: OpenCode session names sync via `session-rename_sync_branch` tool; tab titles via the helper script

**Commands**:

```bash
terminal-title-helper.sh sync      # Sync tab with current repo/branch
terminal-title-helper.sh rename "My Project"  # Set custom title
terminal-title-helper.sh reset     # Reset to default
terminal-title-helper.sh detect    # Check terminal compatibility
```

**Title Formats** (set via `TERMINAL_TITLE_FORMAT`):

| Format | Example Output |
|--------|----------------|
| `repo/branch` (default) | `aidevops/feature/xyz` |
| `branch` | `feature/xyz` |
| `repo` | `aidevops` |
| `branch/repo` | `feature/xyz (aidevops)` |

**Environment Variables**:

| Variable | Default | Description |
|----------|---------|-------------|
| `TERMINAL_TITLE_FORMAT` | `repo/branch` | Title format (see table above) |
| `TERMINAL_TITLE_ENABLED` | `true` | Set to `false` to disable |

<!-- AI-CONTEXT-END -->

## How It Works

Sets terminal titles using OSC (Operating System Command) escape sequences — a standard supported by virtually all modern terminal emulators:

```bash
printf '\033]0;%s\007' "title"   # OSC 0 - Set window title and icon name
printf '\033]2;%s\007' "title"   # OSC 2 - Set window title only
```

## Supported Terminals

**Full support**: Tabby, iTerm2, Windows Terminal, Kitty, Alacritty, WezTerm, Hyper, GNOME Terminal, Konsole, VS Code Terminal, xterm, and most xterm-compatible terminals.

**Partial**: Apple Terminal (basic), tmux/screen (requires config — see Troubleshooting).

## Shell Integration

For automatic tab title updates on every directory change, add to your shell config:

**Bash** (`~/.bashrc`):

```bash
PROMPT_COMMAND='~/.aidevops/agents/scripts/terminal-title-helper.sh sync 2>/dev/null'
```

**Zsh** (`~/.zshrc`):

```zsh
precmd() {
    ~/.aidevops/agents/scripts/terminal-title-helper.sh sync 2>/dev/null
}
```

**Fish** (`~/.config/fish/config.fish`):

```fish
function fish_prompt
    ~/.aidevops/agents/scripts/terminal-title-helper.sh sync 2>/dev/null
    # ... rest of your prompt
end
```

## Troubleshooting

**Tab title not updating**: Run `terminal-title-helper.sh detect` to check compatibility. Verify you're in a git repo (`git rev-parse --is-inside-work-tree`) and that `TERMINAL_TITLE_ENABLED` is not `false`.

**Wrong format**: Check `echo $TERMINAL_TITLE_FORMAT`.

**Terminal-specific config required**:

- **tmux** (`~/.tmux.conf`): `set -g set-titles on` and `set -g set-titles-string "#T"`
- **screen** (`~/.screenrc`): `termcapinfo xterm* ti@:te@`
- **VS Code**: Enable "Terminal > Integrated: Allow Workspace Shell"

## Related

- `workflows/git-workflow.md` - Git workflow with branch naming
- `workflows/branch.md` - Branch creation and lifecycle
- `tools/opencode/opencode.md` - OpenCode session management
