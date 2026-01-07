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

- **Purpose**: Sync terminal tab titles with git repo/branch
- **Script**: `~/.aidevops/agents/scripts/terminal-title-helper.sh`
- **Auto-sync**: Runs automatically via `pre-edit-check.sh`
- **Compatibility**: Most modern terminals (OSC escape sequences)

**Supported Terminals**:
Tabby, iTerm2, Windows Terminal, Kitty, Alacritty, WezTerm, Hyper, GNOME Terminal, VS Code, Apple Terminal, and most xterm-compatible terminals.

**Commands**:

```bash
# Sync tab with current repo/branch
terminal-title-helper.sh sync

# Set custom title
terminal-title-helper.sh rename "My Project"

# Reset to default
terminal-title-helper.sh reset

# Check terminal compatibility
terminal-title-helper.sh detect
```

**Title Formats** (set via `TERMINAL_TITLE_FORMAT`):

| Format | Example Output |
|--------|----------------|
| `repo/branch` (default) | `aidevops/feature/xyz` |
| `branch` | `feature/xyz` |
| `repo` | `aidevops` |
| `branch/repo` | `feature/xyz (aidevops)` |

<!-- AI-CONTEXT-END -->

## Overview

This integration automatically syncs terminal tab/window titles with the current git repository and branch name using OSC (Operating System Command) escape sequences - a standard supported by most modern terminal emulators.

## How It Works

The integration uses OSC escape sequences:

```bash
# OSC 0 - Set window title and icon name
printf '\033]0;%s\007' "title"

# OSC 2 - Set window title only  
printf '\033]2;%s\007' "title"
```

These sequences are part of the xterm control sequence standard and are supported by virtually all modern terminals.

## Supported Terminals

| Terminal | Platform | Support Level |
|----------|----------|---------------|
| **Tabby** | Cross-platform | Full |
| **iTerm2** | macOS | Full |
| **Windows Terminal** | Windows | Full |
| **Kitty** | Cross-platform | Full |
| **Alacritty** | Cross-platform | Full |
| **WezTerm** | Cross-platform | Full |
| **Hyper** | Cross-platform | Full |
| **GNOME Terminal** | Linux | Full |
| **Konsole** | Linux | Full |
| **VS Code Terminal** | Cross-platform | Full |
| **Apple Terminal** | macOS | Basic |
| **xterm** | Cross-platform | Full |
| **tmux/screen** | Cross-platform | With config |

## Automatic Integration

The `pre-edit-check.sh` script automatically syncs the tab title when:
1. You're in a git repository
2. You're on a feature branch (not main/master)
3. The pre-edit check passes

This means your tab title updates automatically when you start working on a branch.

## Manual Usage

### Sync with Git Context

```bash
~/.aidevops/agents/scripts/terminal-title-helper.sh sync
# Output: [OK] Tab synced: aidevops/feature/my-feature
```

### Set Custom Title

```bash
~/.aidevops/agents/scripts/terminal-title-helper.sh rename "Production Debug"
# Output: [OK] Tab title set to: Production Debug
```

### Reset to Default

```bash
~/.aidevops/agents/scripts/terminal-title-helper.sh reset
# Output: [OK] Tab title reset to default
```

### Check Terminal Compatibility

```bash
~/.aidevops/agents/scripts/terminal-title-helper.sh detect
# Output: [OK] Running in Kitty terminal (full OSC support)
# Returns: TABBY, ITERM2, KITTY, WINDOWS_TERMINAL, COMPATIBLE, etc.
```

## Shell Integration

For automatic tab title updates on every directory change, add to your shell config:

### Bash (`~/.bashrc`)

```bash
# Update tab title on each prompt
PROMPT_COMMAND='~/.aidevops/agents/scripts/terminal-title-helper.sh sync 2>/dev/null'
```

### Zsh (`~/.zshrc`)

```zsh
# Update tab title before each prompt
precmd() {
    ~/.aidevops/agents/scripts/terminal-title-helper.sh sync 2>/dev/null
}
```

### Fish (`~/.config/fish/config.fish`)

```fish
function fish_prompt
    ~/.aidevops/agents/scripts/terminal-title-helper.sh sync 2>/dev/null
    # ... rest of your prompt
end
```

## Configuration

### Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `TERMINAL_TITLE_FORMAT` | `repo/branch` | Title format |
| `TERMINAL_TITLE_ENABLED` | `true` | Set to `false` to disable |

### Format Options

```bash
# Show repo and branch (default)
export TERMINAL_TITLE_FORMAT="repo/branch"
# Result: aidevops/feature/xyz

# Show only branch
export TERMINAL_TITLE_FORMAT="branch"
# Result: feature/xyz

# Show only repo
export TERMINAL_TITLE_FORMAT="repo"
# Result: aidevops

# Show branch with repo in parentheses
export TERMINAL_TITLE_FORMAT="branch/repo"
# Result: feature/xyz (aidevops)
```

## Integration with OpenCode

When using OpenCode with aidevops:

1. **Session names** are synced via `session-rename_sync_branch` tool
2. **Tab titles** are synced via `terminal-title-helper.sh sync`

Both happen automatically when you create a branch and pass the pre-edit check.

## Troubleshooting

### Tab Title Not Updating

1. Check terminal compatibility:
   ```bash
   ~/.aidevops/agents/scripts/terminal-title-helper.sh detect
   ```

2. Verify you're in a git repo:
   ```bash
   git rev-parse --is-inside-work-tree
   ```

3. Check if disabled:
   ```bash
   echo $TERMINAL_TITLE_ENABLED
   ```

### Title Shows Wrong Format

Check your format setting:
```bash
echo $TERMINAL_TITLE_FORMAT
```

### Terminal-Specific Configuration

Some terminals require additional settings:

**tmux** (`~/.tmux.conf`):
```bash
set -g set-titles on
set -g set-titles-string "#T"
```

**screen** (`~/.screenrc`):
```bash
termcapinfo xterm* ti@:te@
```

**VS Code**: Enable "Terminal > Integrated: Allow Workspace Shell"

## Related

- `workflows/git-workflow.md` - Git workflow with branch naming
- `workflows/branch.md` - Branch creation and lifecycle
- `tools/opencode/opencode.md` - OpenCode session management
