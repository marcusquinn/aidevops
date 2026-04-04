---
description: Terminal environment optimization - shell config, aliases, performance tuning
mode: subagent
tools:
  read: true
  write: true
  edit: true
  bash: true
  glob: true
  grep: true
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Terminal Optimization

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Purpose**: Audit and optimize terminal environment (shell startup, aliases, PATH, tools)
- **Command**: `/terminal-optimize` or `@terminal-optimization`
- **Scope**: Shell config (.bashrc/.zshrc), PATH dedup, tool recommendations, startup profiling

**Quick audit**:

```bash
# Profile shell startup time
time zsh -i -c exit    # or: time bash -i -c exit

# Count PATH entries (duplicates waste lookup time)
echo "$PATH" | tr ':' '\n' | sort | uniq -c | sort -rn | head

# Check shell config size
wc -l ~/.zshrc ~/.bashrc ~/.profile 2>/dev/null
```

<!-- AI-CONTEXT-END -->

## Optimization Checklist

### 1. Shell Startup Time

Target: <200ms for interactive shell.

```bash
# Profile zsh startup
zsh -xvs 2>&1 | ts -i '%.s' | head -50
# Profile bash startup
bash --norc --noprofile -c 'time bash -i -c exit'
```

Common slow culprits: nvm, conda init, rbenv/pyenv init, oh-my-zsh plugins, compinit (cache with zcompdump).

**Lazy-load pattern** (apply to nvm, conda, rbenv, pyenv):

```bash
nvm() {
    unset -f nvm node npm npx
    export NVM_DIR="$HOME/.nvm"
    [ -s "$NVM_DIR/nvm.sh" ] && source "$NVM_DIR/nvm.sh"
    nvm "$@"
}
```

### 2. PATH Optimization

```bash
# Deduplicate PATH
typeset -U PATH  # zsh built-in
# or for bash:
PATH=$(echo "$PATH" | tr ':' '\n' | awk '!seen[$0]++' | tr '\n' ':' | sed 's/:$//')

# Remove non-existent directories
PATH=$(echo "$PATH" | tr ':' '\n' | while read -r dir; do
    [ -d "$dir" ] && echo "$dir"
done | tr '\n' ':' | sed 's/:$//')
```

### 3. Modern Tool Replacements

| Classic | Modern | Speedup | Install |
|---------|--------|---------|---------|
| `find` | `fd` | 5-10x | `brew install fd` |
| `grep` | `rg` (ripgrep) | 5-20x | `brew install ripgrep` |
| `grep` (PDFs/docs) | `rga` (ripgrep-all) | new capability | `brew install ripgrep-all` |
| `cat` | `bat` | Syntax highlighting | `brew install bat` |
| `ls` | `eza` | Better output | `brew install eza` |
| `du` | `dust` | Visual tree | `brew install dust` |
| `top` | `btop` | Better UI | `brew install btop` |
| `diff` | `delta` | Syntax-aware | `brew install git-delta` |
| `sed` | `sd` | Simpler syntax | `brew install sd` |
| `curl` | `xh` | Colorized HTTP | `brew install xh` |
| `man` | `tldr` | Quick examples | `brew install tldr` |

`fd`/`rg`/`rga` share the same ecosystem and `.gitignore` awareness: `fd` = files by metadata, `rg` = text content, `rga` = inside non-text files (PDF, DOCX/XLSX/PPTX, ODT, SQLite, zip/tar/gz).

### 4. Shell Aliases

```bash
# Git shortcuts
alias gs='git status'
alias gd='git diff'
alias gl='git log --oneline -20'
alias gp='git pull --rebase'

# Navigation
alias ..='cd ..'
alias ...='cd ../..'
alias ll='eza -la --git'

# Safety
alias rm='rm -i'
alias cp='cp -i'
alias mv='mv -i'

# aidevops
alias ad='aidevops'
alias ads='aidevops status'
alias adu='aidevops update'
```

### 5. Completion and History

```bash
# Zsh: better history search
bindkey '^R' history-incremental-search-backward
HISTSIZE=50000
SAVEHIST=50000
setopt SHARE_HISTORY
setopt HIST_IGNORE_DUPS
setopt HIST_IGNORE_SPACE

# fzf integration (fuzzy history search)
# brew install fzf && $(brew --prefix)/opt/fzf/install
```

### 6. Terminal Multiplexer

Install: `brew install tmux`. Minimal `~/.tmux.conf`:

```bash
set -g mouse on
set -g history-limit 50000
set -g default-terminal "screen-256color"
bind | split-window -h -c "#{pane_current_path}"
bind - split-window -v -c "#{pane_current_path}"
```

## Audit Report Format (`/terminal-optimize`)

```text
Terminal Optimization Report
============================
Shell: zsh 5.9
Startup time: 342ms (target: <200ms)
PATH entries: 23 (4 duplicates, 2 missing)
Config size: .zshrc 187 lines

Issues Found:
1. [SLOW] nvm init adds 180ms - suggest lazy-load
2. [DUP] /usr/local/bin appears 3x in PATH
3. [MISSING] /opt/homebrew/bin not in PATH but Homebrew installed
4. [TOOL] Using grep instead of ripgrep (5-20x slower)

Recommendations:
1. Lazy-load nvm (saves ~180ms)
2. Deduplicate PATH (saves ~5ms lookup)
3. Install: fd, ripgrep, bat, eza
4. Add fzf for fuzzy history search
```

## Related

- `tools/terminal/terminal-title.md` - Terminal title management
