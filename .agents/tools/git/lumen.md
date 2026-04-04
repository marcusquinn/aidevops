---
description: Lumen - AI-powered git diffs, commit generation, and change explanations
mode: subagent
tools:
  read: true
  write: false
  edit: false
  bash: true
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

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

Optional deps: `brew install fzf mdcat` (picker + pretty output).

Configure via `lumen configure`, env vars, or `~/.config/lumen/lumen.config.json`:

```bash
export LUMEN_AI_PROVIDER="openai"   # or claude, gemini, groq, deepseek, xai, ollama, openrouter
export LUMEN_API_KEY="your-key"     # reuse keys from ~/.config/aidevops/credentials.sh
export LUMEN_AI_MODEL="gpt-5-mini"  # optional, uses provider default
```

Precedence: CLI flags > `--config` file > project config > global config > env vars > defaults.

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

Typical flows: `lumen diff` then `lumen draft` (pre-commit review) | `lumen diff --pr 123` with `gh pr view` (PR review) | `lumen explain --staged` (review AI-generated changes) | `lumen operate "description"` (complex git ops) | `lumen diff` for conflict resolution (see `conflict-resolution.md`).

Diff keybindings: `j/k` navigate, `{/}` jump hunks, `tab` sidebar, `space` mark viewed, `i` annotate, `e` open in editor, `?` all keys.

## See Also

- `conflict-resolution.md` - Git conflict resolution strategies
- `github-cli.md` - GitHub CLI for PRs, issues, and releases
