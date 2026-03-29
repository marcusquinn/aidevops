---
description: Gitea CLI (tea) for repos, PRs, and issues
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

# Gitea CLI Helper

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Install**: `brew install tea` | `go install code.gitea.io/tea/cmd/tea@latest` | [dl.gitea.io](https://dl.gitea.io/tea/)
- **Auth**: `tea login add --name <name> --url <url> --token <token>`
- **Config**: `configs/gitea-cli-config.json` (copy from `configs/gitea-cli-config.json.txt`)
- **Script**: `.agents/scripts/gitea-cli-helper.sh`
- **Requires**: `jq`

**Usage**: `./providers/gitea-cli-helper.sh [command] [account] [args]`

**Commands**: `list-repos|create-repo|get-repo|delete-repo|list-issues|create-issue|close-issue|list-prs|create-pr|merge-pr|list-branches|create-branch`

**Multi-account**: Account name in config MUST match `tea` login name. Token in JSON used for API calls `tea` doesn't support (e.g., branch creation).

<!-- AI-CONTEXT-END -->

## Configuration

Account names in `configs/gitea-cli-config.json` must match `tea` login names:

```bash
tea login add --name work --url https://git.company.com --token <your_token>
tea login add --name personal --url https://gitea.com --token <your_token>
```

```json
{
  "accounts": {
    "work": {
      "api_url": "https://git.company.com/api/v1",
      "owner": "your-work-username",
      "token": "<your_token>",
      "default_visibility": "private"
    },
    "personal": {
      "api_url": "https://gitea.com/api/v1",
      "owner": "your-personal-username",
      "token": "<your_token>",
      "default_visibility": "public"
    }
  }
}
```

## Commands

### Repositories

```bash
./providers/gitea-cli-helper.sh list-repos personal
./providers/gitea-cli-helper.sh get-repo personal my-repo
# create-repo <account> <name> [desc] [visibility] [auto_init]
./providers/gitea-cli-helper.sh create-repo personal my-repo "Description" private true
./providers/gitea-cli-helper.sh delete-repo personal my-repo
```

### Issues

```bash
./providers/gitea-cli-helper.sh list-issues personal my-repo open
./providers/gitea-cli-helper.sh create-issue personal my-repo "Bug Title" "Issue body"
./providers/gitea-cli-helper.sh close-issue personal my-repo 1
```

### Pull Requests

```bash
./providers/gitea-cli-helper.sh list-prs personal my-repo open
# create-pr <account> <repo> <title> <head_branch> [base_branch] [body]
./providers/gitea-cli-helper.sh create-pr personal my-repo "Feature X" feature-branch main "Description"
# merge-pr <account> <repo> <pr_number> [method]
./providers/gitea-cli-helper.sh merge-pr personal my-repo 1 squash
```

### Branches

```bash
./providers/gitea-cli-helper.sh list-branches personal my-repo
# create-branch <account> <repo> <new_branch> [source_branch]
./providers/gitea-cli-helper.sh create-branch personal my-repo feature-branch main
```

## Troubleshooting

- **"Gitea CLI is not authenticated"**: `tea login list` — account name must match a configured login.
- **"Owner not configured"**: Set `owner` in `configs/gitea-cli-config.json` for the account.
- **API Errors**: Verify token has sufficient scopes.
