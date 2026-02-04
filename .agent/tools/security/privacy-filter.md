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

Mandatory privacy filter before contributing to public repositories. Detects and optionally redacts privacy-sensitive content including credentials, personal information, and internal URLs.

## Why This Matters

When contributing improvements to public repositories (including aidevops itself), you must ensure:

1. **No credentials** - API keys, tokens, passwords
2. **No personal data** - Email addresses, usernames, paths
3. **No internal URLs** - localhost, staging servers, internal domains
4. **No private keys** - SSH keys, certificates, signing keys

This filter runs automatically in the self-improving agent system (t116) before creating PRs.

## Usage

### Scan for Issues

```bash
# Scan current directory
privacy-filter-helper.sh scan

# Scan specific path
privacy-filter-helper.sh scan ./src

# Scan staged changes only
git diff --cached --name-only | xargs privacy-filter-helper.sh scan
```

### Preview Redactions

```bash
# See what would be redacted (dry-run)
privacy-filter-helper.sh filter

# Preview specific files
privacy-filter-helper.sh filter ./config
```

### Apply Redactions

```bash
# Apply redactions (creates .privacy-backup files)
privacy-filter-helper.sh apply

# Review and commit
git diff
git add -p
```

## Detected Patterns

### Credentials

| Pattern | Example |
|---------|---------|
| API keys | `sk-abc123...`, `pk-xyz789...` |
| AWS keys | `AKIAIOSFODNN7EXAMPLE` |
| GitHub tokens | `ghp_xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx` |
| Stripe keys | `sk_live_...`, `pk_test_...` |
| Slack tokens | `xoxb-...` |
| JWT tokens | `eyJhbGciOiJIUzI1NiIs...` |
| Bearer tokens | `Bearer eyJ...` |

### Personal Information

| Pattern | Example |
|---------|---------|
| Email addresses | `user@example.com` |
| Home paths | `/Users/john/`, `/home/jane/` |
| Windows paths | `C:\Users\admin\` |

### Internal URLs

| Pattern | Example |
|---------|---------|
| Localhost | `localhost:3000`, `127.0.0.1:8080` |
| Database URLs | `mongodb://user:pass@host/db` |
| Internal domains | Custom patterns via config |

### Private Keys

| Pattern | Example |
|---------|---------|
| RSA keys | `-----BEGIN RSA PRIVATE KEY-----` |
| EC keys | `-----BEGIN EC PRIVATE KEY-----` |
| OpenSSH keys | `-----BEGIN OPENSSH PRIVATE KEY-----` |

## Custom Patterns

### Global Patterns

Add patterns that apply to all projects:

```bash
# Add a pattern
privacy-filter-helper.sh patterns add 'mycompany\.internal'

# Edit patterns file
privacy-filter-helper.sh patterns edit
```

Location: `~/.aidevops/config/privacy-patterns.txt`

### Project Patterns

Add patterns specific to a project:

```bash
# Add project pattern
privacy-filter-helper.sh patterns add-project 'staging\.example\.com'

# Edit project patterns
privacy-filter-helper.sh patterns edit-project
```

Location: `.aidevops/privacy-patterns.txt`

### Pattern Format

Patterns use POSIX extended regular expressions:

```text
# Comments start with #
# Each line is a regex pattern

# Internal domains
staging\.mycompany\.com
dev\.mycompany\.com

# Project-specific secrets
MY_PROJECT_[A-Z]+_KEY

# Custom usernames
(john|jane|admin)@mycompany\.com
```

## Integration with Self-Improving Agents

The privacy filter is mandatory in the PR phase (t116.4) of the self-improving agent system:

```bash
# In self-improve-helper.sh pr command:

# 1. Run privacy filter
if ! privacy-filter-helper.sh scan "$worktree_path"; then
    echo "Privacy issues detected. Review and fix before PR."
    exit 1
fi

# 2. Show redacted diff for approval
privacy-filter-helper.sh filter "$worktree_path"
read -p "Approve PR creation? [y/N] " approval

# 3. Create PR only if approved
if [[ "$approval" == "y" ]]; then
    gh pr create ...
fi
```

## Integration with Git Hooks

Add to pre-commit hook for automatic scanning:

```bash
# .git/hooks/pre-commit
#!/bin/bash

# Run privacy filter on staged files
staged_files=$(git diff --cached --name-only)
if [[ -n "$staged_files" ]]; then
    echo "$staged_files" | xargs ~/.aidevops/agents/scripts/privacy-filter-helper.sh scan
    if [[ $? -ne 0 ]]; then
        echo "Privacy issues detected. Fix before committing."
        exit 1
    fi
fi
```

## Secretlint Integration

The privacy filter uses Secretlint for credential detection:

```bash
# Install secretlint
npm install -g secretlint @secretlint/secretlint-rule-preset-recommend

# Or use npx (automatic)
# The filter falls back to npx if secretlint isn't installed
```

Secretlint provides more comprehensive credential detection than regex patterns alone.

## Troubleshooting

### False Positives

If legitimate content is flagged:

1. Review the pattern causing the match
2. Add an exception to `.aidevops/privacy-patterns.txt`:

```text
# Exclude test fixtures
!test/fixtures/
```

3. Or modify the content to avoid the pattern

### Missing Detections

If sensitive content isn't detected:

1. Add a custom pattern:

```bash
privacy-filter-helper.sh patterns add 'my_secret_pattern'
```

2. Report the gap for inclusion in default patterns

### Performance

For large codebases:

```bash
# Install ripgrep for faster scanning
brew install ripgrep  # macOS
apt install ripgrep   # Ubuntu

# The filter automatically uses rg if available
```

## Related Documentation

- `tools/code-review/secretlint.md` - Secretlint configuration
- `tools/code-review/security-analysis.md` - Security scanning
- `workflows/pr.md` - PR creation workflow
- `aidevops/architecture.md` - Self-improving agent system
