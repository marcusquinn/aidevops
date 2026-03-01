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

# Common slow culprits:
# - nvm (Node Version Manager) - lazy-load instead
# - conda init - lazy-load instead
# - rbenv/pyenv init - lazy-load instead
# - oh-my-zsh plugins - reduce to essentials
# - compinit (zsh completion) - cache with zcompdump
```

### Lazy-Loading Pattern

```bash
# Instead of: eval "$(nvm init)"
# Use lazy-load:
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
| `grep` | `ripgrep (rg)` | 5-20x | `brew install ripgrep` |
| `grep` in PDFs/docs | `ripgrep-all (rga)` | N/A (new capability) | `brew install ripgrep-all` |
| `cat` | `bat` | Syntax highlighting | `brew install bat` |
| `ls` | `eza` | Better output | `brew install eza` |
| `du` | `dust` | Visual tree | `brew install dust` |
| `top` | `btop` | Better UI | `brew install btop` |
| `diff` | `delta` | Syntax-aware | `brew install git-delta` |
| `sed` | `sd` | Simpler syntax | `brew install sd` |
| `curl` | `xh` | Colorized HTTP | `brew install xh` |
| `man` | `tldr` | Quick examples | `brew install tldr` |

### Search Tool Hierarchy

`fd`, `rg`, and `rga` are complementary — same ecosystem, same `.gitignore` awareness:

| Tool | Purpose | Use when |
|------|---------|----------|
| `fd` | Find files by **name, type, size, date** | "Find all `.ts` files modified today" |
| `rg` | Search **text file contents** by pattern | "Find where `handleAuth` is called" |
| `rga` | Search **inside non-text files** (PDF, DOCX, SQLite, zip, tar) | "Find 'invoice' in downloaded PDFs" |

- `fd` replaces `find` — file discovery by metadata
- `rg` replaces `grep` — content search in source/text files
- `rga` extends `rg` — same syntax, but reaches inside binary/document formats

`rga` supported formats: PDF, DOCX/XLSX/PPTX, ODT, SQLite, compressed archives (zip, tar, gz), and more via adapters.

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

```bash
# tmux essentials
brew install tmux

# Minimal .tmux.conf
set -g mouse on
set -g history-limit 50000
set -g default-terminal "screen-256color"
bind | split-window -h -c "#{pane_current_path}"
bind - split-window -v -c "#{pane_current_path}"
```

## Audit Report Format

When running `/terminal-optimize`, output:

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
