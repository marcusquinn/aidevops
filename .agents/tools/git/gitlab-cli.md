---
description: GitLab CLI (glab) for repos, MRs, issues, and pipelines
mode: subagent
tools:
  read: true
  write: false
  edit: false
  bash: true
  glob: true
  grep: true
  webfetch: true
  task: true
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# GitLab CLI Helper

<!-- AI-CONTEXT-START -->

## Quick Reference

- **CLI**: `glab` — install: `brew install glab` (macOS) | `apt install glab` (Ubuntu)
- **Auth**: `glab auth login` (GitLab.com) | `glab auth login --hostname gitlab.company.com` (self-hosted)
- **Config**: `configs/gitlab-cli-config.json` (copy from `configs/gitlab-cli-config.json.txt`)
- **Script**: `.agents/scripts/gitlab-cli-helper.sh` — requires `jq`
- **Usage**: `./providers/gitlab-cli-helper.sh [command] [account] [args]`
- **Multi-instance**: GitLab.com + self-hosted via `instance_url` in config

<!-- AI-CONTEXT-END -->

## Configuration

Multi-account config (`configs/gitlab-cli-config.json`):

```json
{
  "accounts": {
    "primary": {
      "instance_url": "https://gitlab.com",
      "owner": "your-username",
      "default_visibility": "public"
    },
    "work": {
      "instance_url": "https://gitlab.company.com",
      "owner": "work-username",
      "default_visibility": "private"
    }
  }
}
```

Authenticate each instance: `glab auth login [--hostname gitlab.company.com]`

## Commands

| Command | Example |
|---------|---------|
| `list-projects <account>` | `./providers/gitlab-cli-helper.sh list-projects primary` |
| `create-project <account> <name> [desc] [visibility] [init]` | `... create-project primary my-project "Desc" private true` |
| `get-project <account> <project>` | `... get-project primary my-project` |
| `delete-project <account> <project>` | `... delete-project primary my-project` |
| `list-issues <account> <project> [state]` | `... list-issues primary my-project opened` |
| `create-issue <account> <project> <title> <desc>` | `... create-issue primary my-project "Bug" "Details"` |
| `close-issue <account> <project> <number>` | `... close-issue primary my-project 1` |
| `list-mrs <account> <project> [state]` | `... list-mrs primary my-project opened` |
| `create-mr <account> <project> <title> <source> [target] [desc]` | `... create-mr primary my-project "Feature X" feature-branch main "Desc"` |
| `merge-mr <account> <project> <mr_number> [method]` | `... merge-mr primary my-project 1 squash` |
| `list-branches <account> <project>` | `... list-branches primary my-project` |
| `create-branch <account> <project> <new_branch> [source]` | `... create-branch primary my-project feature-branch main` |

## Troubleshooting

- **"GitLab CLI is not authenticated"**: Run `glab auth status` to check login status for the configured hostname.
- **"Instance URL not configured"**: Verify `instance_url` in `configs/gitlab-cli-config.json` for the account.
