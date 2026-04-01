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

- **CLI**: `lumen` — visual git diffs, AI commit drafts, change explanations
- **Install**: `brew install jnsahaj/lumen/lumen` or `cargo install lumen`
- **Config**: `~/.config/lumen/lumen.config.json` or `lumen configure`
- **Repo**: https://github.com/jnsahaj/lumen (Rust, MIT)
- **Note**: `lumen diff` works without AI config; AI features need a provider

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

## Setup

```bash
brew install jnsahaj/lumen/lumen   # macOS/Linux
cargo install lumen                # Any platform with Rust
brew install fzf mdcat             # Optional: picker + pretty output
```

Run `lumen configure`, or create `~/.config/lumen/lumen.config.json`:

```json
{
  "provider": "openai",
  "model": "gpt-5-mini",
  "api_key": "your-key-here"
}
```

Config precedence: CLI flags > `--config` file > project `lumen.config.json` > global config > env vars > defaults.

Reuse keys already in `~/.config/aidevops/credentials.sh`, or set env vars:

```bash
export LUMEN_AI_PROVIDER="openai"   # or claude, gemini, groq, etc.
export LUMEN_API_KEY="your-key"
export LUMEN_AI_MODEL="gpt-5-mini"  # optional, uses provider default
```

Providers: `openai` (default), `claude`, `gemini`, `groq`, `deepseek`, `xai`, `ollama`, `openrouter`.

## Common Workflows

```bash
lumen diff --watch                  # Auto-refresh on file changes
lumen diff main..feature --stacked  # Review commits one by one
lumen diff --file src/main.rs       # Filter to specific files
lumen diff --theme dracula          # Custom colour theme
lumen draft | git commit -F -       # Pipe commit message directly
lumen explain --query "impact?"     # Ask specific questions about changes
lumen explain --list                # Interactive commit picker (requires fzf)
```

- **Pre-commit review**: `lumen diff`, then `lumen draft`
- **PR review**: `lumen diff --pr 123` alongside `gh pr view`
- **AI-generated changes**: `lumen explain --staged` before committing
- **Commit messages**: `lumen draft --context "task description"`
- **Complex git ops**: `lumen operate "description"`
- **Conflict resolution**: use `lumen diff`; see `conflict-resolution.md`

Diff keybindings: `j/k` navigate, `{/}` jump hunks, `tab` sidebar, `space` mark viewed, `i` annotate, `e` open in editor, `?` all keys.

## See Also

- `conflict-resolution.md` - Git conflict resolution strategies
- `github-cli.md` - GitHub CLI for PRs, issues, and releases
