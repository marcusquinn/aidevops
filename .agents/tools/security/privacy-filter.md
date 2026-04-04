---
description: Privacy filter for public PR contributions
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

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Privacy Filter

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Script**: `~/.aidevops/agents/scripts/privacy-filter-helper.sh`
- **Scan**: `privacy-filter-helper.sh scan [path]`
- **Preview**: `privacy-filter-helper.sh filter [path]`
- **Apply**: `privacy-filter-helper.sh apply [path]`
- **Patterns**: `privacy-filter-helper.sh patterns [show|add|edit]`
- **Global config**: `~/.aidevops/config/privacy-patterns.txt`
- **Project config**: `.aidevops/privacy-patterns.txt`

<!-- AI-CONTEXT-END -->

Mandatory before contributing to public repos. Detects and redacts credentials, personal data, internal URLs, and private keys. Runs automatically in the self-improving agent system (t116) before PR creation.

## Usage

```bash
# Scan current directory or specific path
privacy-filter-helper.sh scan
privacy-filter-helper.sh scan ./src

# Scan staged changes only
git diff --cached --name-only | xargs privacy-filter-helper.sh scan

# Preview redactions (dry-run)
privacy-filter-helper.sh filter [path]

# Apply redactions (creates .privacy-backup files)
privacy-filter-helper.sh apply [path]
git diff && git add -p
```

## Detected Patterns

| Category | Patterns | Examples |
|----------|----------|---------|
| API keys | `sk-`, `pk-`, AWS `AKIA*`, Stripe `sk_live_`/`pk_test_` | `sk-abc123...`, `AKIAIOSFODNN7EXAMPLE` |
| Tokens | GitHub `ghp_*`, Slack `xoxb-*`, JWT `eyJ*`, `Bearer eyJ*` | `ghp_xxxx...`, `xoxb-...` |
| Personal info | Email addresses, home paths (`/Users/*/`, `/home/*/`, `C:\Users\*\`) | `user@example.com` |
| Internal URLs | `localhost:*`, `127.0.0.1:*`, DB connection strings, custom domains | `mongodb://user:pass@host/db` |
| Private keys | RSA, EC, OpenSSH key headers | `-----BEGIN RSA PRIVATE KEY-----` |

## Custom Patterns

Patterns use POSIX extended regular expressions, one per line (`#` for comments).

```bash
# Global patterns (all projects)
privacy-filter-helper.sh patterns add 'mycompany\.internal'
privacy-filter-helper.sh patterns edit
# Location: ~/.aidevops/config/privacy-patterns.txt

# Project-specific patterns
privacy-filter-helper.sh patterns add-project 'staging\.example\.com'
privacy-filter-helper.sh patterns edit-project
# Location: .aidevops/privacy-patterns.txt
```

Example pattern file:

```text
# Internal domains
staging\.mycompany\.com
dev\.mycompany\.com

# Project-specific secrets
MY_PROJECT_[A-Z]+_KEY

# Custom usernames
(john|jane|admin)@mycompany\.com
```

## Integrations

### Self-Improving Agent System (t116.4)

```bash
# In self-improvement PR workflow:
# 1. Scan — fail if issues found
if ! privacy-filter-helper.sh scan "$worktree_path"; then
    echo "Privacy issues detected. Review and fix before PR."
    exit 1
fi
# 2. Preview redacted diff for approval
privacy-filter-helper.sh filter "$worktree_path"
read -p "Approve PR creation? [y/N] " approval
# 3. Create PR only if approved
[[ "$approval" == "y" ]] && gh pr create ...
```

### Git Pre-Commit Hook

```bash
# .git/hooks/pre-commit
#!/bin/bash
staged_files=$(git diff --cached --name-only)
if [[ -n "$staged_files" ]]; then
    echo "$staged_files" | xargs ~/.aidevops/agents/scripts/privacy-filter-helper.sh scan
    if [[ $? -ne 0 ]]; then
        echo "Privacy issues detected. Fix before committing."
        exit 1
    fi
fi
```

### Secretlint

Uses Secretlint for credential detection (more comprehensive than regex alone):

```bash
npm install -g secretlint @secretlint/secretlint-rule-preset-recommend
# Falls back to npx if not installed globally
```

## Troubleshooting

**False positives**: Add exception to `.aidevops/privacy-patterns.txt` (prefix with `!` for exclusions, e.g., `!test/fixtures/`), or modify content to avoid the pattern.

**Missing detections**: Add custom pattern via `privacy-filter-helper.sh patterns add 'pattern'`. Report gaps for inclusion in defaults.

**Performance**: Install `ripgrep` (`brew install ripgrep` / `apt install ripgrep`) — the filter uses `rg` automatically when available.

## Related

- `tools/code-review/secretlint.md` — Secretlint configuration
- `tools/code-review/security-analysis.md` — Security scanning
- `workflows/pr.md` — PR creation workflow
- `aidevops/architecture.md` — Self-improving agent system
