# GitHub CLI Helper Documentation

## Overview

The GitHub CLI Helper provides a comprehensive interface for managing GitHub repositories, issues, pull requests, and branches directly from the command line. It leverages the `gh` CLI tool to offer a seamless experience for developers working with one or multiple GitHub accounts.

## Prerequisites

1. **GitHub CLI (`gh`)**: Must be installed.
    - **macOS**: `brew install gh`
    - **Ubuntu/Debian**: `sudo apt install gh`
    - **Other**: See [GitHub CLI Installation](https://cli.github.com/manual/installation)
2. **`jq`**: JSON processor (required for configuration parsing).
3. **Authentication**: You must authenticate `gh` with your GitHub account(s).

## Configuration

The helper uses a JSON configuration file located at `configs/github-cli-config.json`.

### Setup

1. Copy the template:

    ```bash
    cp configs/github-cli-config.json.txt configs/github-cli-config.json
    ```

2. Edit `configs/github-cli-config.json` with your account details.

### Multi-Account Support

The configuration supports multiple accounts (e.g., `primary`, `work`, `org`).

**1. Authenticate `gh`:**
Due to `gh` limitations with multi-account switching, the helper relies on the configuration file to define the context. You should authenticate with your primary account:

```bash
gh auth login
```

*For true multi-account switching with `gh`, consider using environment variables (GH_TOKEN) or different hostnames if using GitHub Enterprise.*

**2. Update `configs/github-cli-config.json`:**

```json
{
  "accounts": {
    "primary": {
      "owner": "your-username",
      "default_visibility": "public",
      "description": "Personal Account"
    },
    "work": {
      "owner": "work-org",
      "default_visibility": "private",
      "description": "Work Organization"
    }
  }
}
```

## Usage

Run the helper script:

```bash
./providers/github-cli-helper.sh [command] [account] [arguments]
```

### Repository Management

- **List Repositories**:

    ```bash
    ./providers/github-cli-helper.sh list-repos primary
    ```

- **Create Repository**:

    ```bash
    # Usage: create-repo <account> <name> [desc] [visibility] [auto_init]
    ./providers/github-cli-helper.sh create-repo primary my-new-repo "Description" private true
    ```

- **Get Repository Details**:

    ```bash
    ./providers/github-cli-helper.sh get-repo primary my-new-repo
    ```

- **Delete Repository**:

    ```bash
    ./providers/github-cli-helper.sh delete-repo primary my-new-repo
    ```

### Issue Management

- **List Issues**:

    ```bash
    ./providers/github-cli-helper.sh list-issues primary my-repo open
    ```

- **Create Issue**:

    ```bash
    ./providers/github-cli-helper.sh create-issue primary my-repo "Bug Title" "Issue description body"
    ```

- **Close Issue**:

    ```bash
    ./providers/github-cli-helper.sh close-issue primary my-repo 1
    ```

### Pull Request Management

- **List Pull Requests**:

    ```bash
    ./providers/github-cli-helper.sh list-prs primary my-repo open
    ```

- **Create Pull Request**:

    ```bash
    # Usage: create-pr <account> <repo> <title> [base] [head] [body]
    ./providers/github-cli-helper.sh create-pr primary my-repo "Feature X" main feature-branch "Description"
    ```

- **Merge Pull Request**:

    ```bash
    # Usage: merge-pr <account> <repo> <pr_number> [method]
    ./providers/github-cli-helper.sh merge-pr primary my-repo 1 squash
    ```

### Branch Management

- **List Branches**:

    ```bash
    ./providers/github-cli-helper.sh list-branches primary my-repo
    ```

- **Create Branch**:

    ```bash
    # Usage: create-branch <account> <repo> <new_branch> [source_branch]
    ./providers/github-cli-helper.sh create-branch primary my-repo feature-branch main
    ```

## Troubleshooting

- **"GitHub CLI is not authenticated"**: Run `gh auth status` to check your login status.
- **"Owner not configured"**: Check `configs/github-cli-config.json` and ensure the `owner` field is set correctly.
