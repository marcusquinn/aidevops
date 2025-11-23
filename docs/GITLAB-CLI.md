# GitLab CLI Helper Documentation

## Overview

The GitLab CLI Helper provides a comprehensive interface for managing GitLab projects, issues, merge requests, and branches directly from the command line. It leverages the `glab` CLI tool to offer a seamless experience for developers working with GitLab.com and self-hosted instances.

## Prerequisites

1. **GitLab CLI (`glab`)**: Must be installed.
    - **macOS**: `brew install glab`
    - **Ubuntu/Debian**: `sudo apt install glab`
    - **Other**: See [GitLab CLI Installation](https://glab.readthedocs.io/en/latest/installation/)
2. **`jq`**: JSON processor (required for configuration parsing).
3. **Authentication**: You must authenticate `glab` with your GitLab instance(s).

## Configuration

The helper uses a JSON configuration file located at `configs/gitlab-cli-config.json`.

### Setup

1. Copy the template:

    ```bash
    cp configs/gitlab-cli-config.json.txt configs/gitlab-cli-config.json
    ```

2. Edit `configs/gitlab-cli-config.json` with your account details.

### Multi-Account/Instance Support

The configuration supports multiple accounts and instances (e.g., `primary` for GitLab.com, `work` for self-hosted).

**1. Authenticate `glab`:**

```bash
# For GitLab.com
glab auth login

# For Self-Hosted
glab auth login --hostname gitlab.company.com
```

**2. Update `configs/gitlab-cli-config.json`:**

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

## Usage

Run the helper script:

```bash
./providers/gitlab-cli-helper.sh [command] [account] [arguments]
```

### Project Management
- **List Projects**:

    ```bash
    ./providers/gitlab-cli-helper.sh list-projects primary
    ```
- **Create Project**:

    ```bash
    # Usage: create-project <account> <name> [desc] [visibility] [init]
    ./providers/gitlab-cli-helper.sh create-project primary my-new-project "Description" private true
    ```
- **Get Project Details**:

    ```bash
    ./providers/gitlab-cli-helper.sh get-project primary my-new-project
    ```
- **Delete Project**:

    ```bash
    ./providers/gitlab-cli-helper.sh delete-project primary my-new-project
    ```

### Issue Management
- **List Issues**:

    ```bash
    ./providers/gitlab-cli-helper.sh list-issues primary my-project opened
    ```
- **Create Issue**:

    ```bash
    ./providers/gitlab-cli-helper.sh create-issue primary my-project "Bug Title" "Issue description"
    ```
- **Close Issue**:

    ```bash
    ./providers/gitlab-cli-helper.sh close-issue primary my-project 1
    ```

### Merge Request Management
- **List Merge Requests**:

    ```bash
    ./providers/gitlab-cli-helper.sh list-mrs primary my-project opened
    ```
- **Create Merge Request**:

    ```bash
    # Usage: create-mr <account> <project> <title> <source> [target] [desc]
    ./providers/gitlab-cli-helper.sh create-mr primary my-project "Feature X" feature-branch main "Description"
    ```
- **Merge Merge Request**:

    ```bash
    # Usage: merge-mr <account> <project> <mr_number> [method]
    ./providers/gitlab-cli-helper.sh merge-mr primary my-project 1 squash
    ```

### Branch Management
- **List Branches**:

    ```bash
    ./providers/gitlab-cli-helper.sh list-branches primary my-project
    ```
- **Create Branch**:

    ```bash
    # Usage: create-branch <account> <project> <new_branch> [source_branch]
    ./providers/gitlab-cli-helper.sh create-branch primary my-project feature-branch main
    ```

## Troubleshooting
- **"GitLab CLI is not authenticated"**: Run `glab auth status` to check your login status for the configured hostname.
- **"Instance URL not configured"**: Check `configs/gitlab-cli-config.json` and ensure the `instance_url` is correct for the account you are using.
