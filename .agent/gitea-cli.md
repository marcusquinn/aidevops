# Gitea CLI Helper Documentation

## Overview

The Gitea CLI Helper provides a comprehensive interface for managing Gitea repositories, issues, pull requests, and branches directly from the command line. It leverages the `tea` CLI tool and the Gitea API to offer a seamless experience for developers working with one or multiple Gitea instances.

## Prerequisites

1. **Gitea CLI (`tea`)**: Must be installed.
    - **Homebrew (macOS/Linux)**: `brew install tea`
    - **Go**: `go install code.gitea.io/tea/cmd/tea@latest`
    - **Binary**: Download from [dl.gitea.io](https://dl.gitea.io/tea/)
2. **`jq`**: JSON processor (required for configuration parsing).
3. **Authentication**: You must authenticate `tea` with your Gitea instance(s).

## Configuration

The helper uses a JSON configuration file located at `configs/gitea-cli-config.json`.

### Setup

1. Copy the template:

    ```bash
    cp configs/gitea-cli-config.json.txt configs/gitea-cli-config.json
    ```

2. Edit `configs/gitea-cli-config.json` with your account details.

### Multi-Account Support

The configuration supports multiple accounts (e.g., `primary`, `work`, `selfhosted`). Each account in the JSON config MUST match a login name configured in `tea`.

**1. Authenticate `tea`:**

```bash
tea login add --name work --url https://git.company.com --token <your_token>
tea login add --name personal --url https://gitea.com --token <your_token>
```

**2. Update `configs/gitea-cli-config.json`:**

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

*Note: The `token` in the JSON is primarily used for API calls that `tea` doesn't support yet (e.g., creating branches).*

## Usage

Run the helper script:

```bash
./providers/gitea-cli-helper.sh [command] [account] [arguments]
```

### Repository Management

- **List Repositories**:

    ```bash
    ./providers/gitea-cli-helper.sh list-repos personal
    ```

- **Create Repository**:

    ```bash
    # Usage: create-repo <account> <name> [desc] [visibility] [auto_init]
    ./providers/gitea-cli-helper.sh create-repo personal my-new-repo "Description" private true
    ```

- **Get Repository Details**:

    ```bash
    ./providers/gitea-cli-helper.sh get-repo personal my-new-repo
    ```

- **Delete Repository**:

    ```bash
    ./providers/gitea-cli-helper.sh delete-repo personal my-new-repo
    ```

### Issue Management

- **List Issues**:

    ```bash
    ./providers/gitea-cli-helper.sh list-issues personal my-repo open
    ```

- **Create Issue**:

    ```bash
    ./providers/gitea-cli-helper.sh create-issue personal my-repo "Bug Title" "Issue description body"
    ```

- **Close Issue**:

    ```bash
    ./providers/gitea-cli-helper.sh close-issue personal my-repo 1
    ```

### Pull Request Management

- **List Pull Requests**:

    ```bash
    ./providers/gitea-cli-helper.sh list-prs personal my-repo open
    ```

- **Create Pull Request**:

    ```bash
    # Usage: create-pr <account> <repo> <title> <head_branch> [base_branch] [body]
    ./providers/gitea-cli-helper.sh create-pr personal my-repo "Feature X" feature-branch main "Description"
    ```

- **Merge Pull Request**:

    ```bash
    # Usage: merge-pr <account> <repo> <pr_number> [method]
    ./providers/gitea-cli-helper.sh merge-pr personal my-repo 1 squash
    ```

### Branch Management

- **List Branches**:

    ```bash
    ./providers/gitea-cli-helper.sh list-branches personal my-repo
    ```

- **Create Branch**:

    ```bash
    # Usage: create-branch <account> <repo> <new_branch> [source_branch]
    ./providers/gitea-cli-helper.sh create-branch personal my-repo feature-branch main
    ```

## Troubleshooting

- **"Gitea CLI is not authenticated"**: Run `tea login list` to see configured logins. Ensure the `account` name you use in the script command matches one of these logins.
- **"Owner not configured"**: Check `configs/gitea-cli-config.json` and ensure the `owner` field is set for the account you are using.
- **API Errors**: Verify your `token` in the configuration file is correct and has sufficient scopes.
