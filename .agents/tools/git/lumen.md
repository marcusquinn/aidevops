---
description: Lumen - AI-powered git diffs, commit generation, and change explanations
mode: subagent
tools:
  read: true
  write: false
  edit: false
  bash: true
---

# Lumen - AI Git Companion

<!-- AI-CONTEXT-START -->

## Quick Reference

- **CLI Tool**: `lumen` - Beautiful git diff viewer + AI commit messages
- **Install**: `brew install jnsahaj/lumen/lumen` (macOS/Linux) | `cargo install lumen` (any)
- **Config**: `~/.config/lumen/lumen.config.json`
- **Setup**: `lumen configure` (interactive provider/key setup)
- **Repo**: https://github.com/jnsahaj/lumen (Rust, MIT)
- **Note**: `lumen diff` works without AI config; AI features need a provider

**Key Commands**:

```bash
lumen diff                        # Visual side-by-side diff (uncommitted)
lumen diff HEAD~1                 # Diff for specific commit
lumen diff main..feature/A        # Branch comparison
lumen diff --pr 123               # GitHub PR diff
lumen draft                       # Generate commit message from staged changes
lumen draft --context "reason"    # Commit message with context hint
lumen explain                     # AI summary of working directory changes
lumen explain HEAD~3..HEAD        # Explain last 3 commits
lumen operate "squash last 3"     # Natural language to git command
```

<!-- AI-CONTEXT-END -->

## Installation

```bash
brew install jnsahaj/lumen/lumen   # macOS/Linux
cargo install lumen                # Any platform with Rust
brew install fzf mdcat             # Optional: interactive picker + pretty output
```

## Configuration

Run `lumen configure` for interactive setup, or create `~/.config/lumen/lumen.config.json`:

```json
{
  "provider": "openai",
  "model": "gpt-5-mini",
  "api_key": "your-key-here"
}
```

**Precedence** (highest to lowest): CLI flags > `--config` file > project `lumen.config.json` > global config > env vars > defaults.

### API Key Setup

Reuse keys already in `~/.config/aidevops/credentials.sh` or set per-provider env vars:

```bash
# Environment variables (alternative to config file)
export LUMEN_AI_PROVIDER="openai"   # or claude, gemini, groq, etc.
export LUMEN_API_KEY="your-key"
export LUMEN_AI_MODEL="gpt-5-mini"  # optional, uses provider default
```

### Supported Providers

`openai` (default), `claude`, `gemini` (free tier), `groq` (free), `deepseek`, `xai`, `ollama` (local, no key), `openrouter`. Run `lumen configure` to select provider and model interactively.

## Additional Options

`lumen diff` extras beyond Quick Reference:

```bash
lumen diff --watch                  # Auto-refresh on file changes
lumen diff main..feature --stacked  # Review commits one by one
lumen diff --file src/main.rs       # Filter to specific files
lumen diff --theme dracula          # Custom colour theme
lumen draft | git commit -F -       # Pipe commit message directly
lumen explain --query "impact?"     # Ask specific questions about changes
lumen explain --list                # Interactive commit picker (requires fzf)
```

**Diff keybindings**: `j/k` navigate, `{/}` jump hunks, `tab` sidebar, `space` mark viewed, `i` annotate, `e` open in editor, `?` all keys.

## When to Use Lumen

- **Pre-commit review**: `lumen diff` to review, then `lumen draft` for the commit message
- **PR review**: `lumen diff --pr 123` for visual side-by-side review alongside `gh pr view`
- **Understanding AI-generated changes**: `lumen explain --staged` before committing agent output
- **Commit message generation**: `lumen draft --context "task description"` for conventional commits
- **Complex git ops**: `lumen operate "description"` instead of memorising git syntax
- **Stacked review**: `lumen diff main..feature --stacked` to review commits one by one
- **Conflict resolution**: Use `lumen diff` to visualise merge conflicts (see `conflict-resolution.md`)

## See Also

- `conflict-resolution.md` - Git conflict resolution strategies
- `github-cli.md` - GitHub CLI for PRs, issues, and releases
