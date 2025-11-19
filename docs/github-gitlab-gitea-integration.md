# GitHub, GitLab, and Gitea CLI Integration

## Overview
Added comprehensive CLI helper scripts for managing GitHub, GitLab, and Gitea repositories through their respective CLI tools.

## Scripts Created

### GitHub CLI Helper
- **File**: `providers/github-cli-helper.sh`
- **Dependencies**: GitHub CLI (gh), jq
- **Features**:
  - Repository management (create, delete, list, get info)
  - Issue management (create, close, list)
  - Pull request management (create, merge, list)
  - Branch management (create, list)
  - Multi-account support

### GitLab CLI Helper
- **File**: `providers/gitlab-cli-helper.sh`
- **Dependencies**: GitLab CLI (glab), jq
- **Features**:
  - Project management (create, delete, list, get details)
  - Issue management (create, close, list)
  - Merge request management (create, merge, list)
  - Branch management (create, list)
  - Multi-instance support (GitLab.com, self-hosted)

### Gitea CLI Helper
- **File**: `providers/gitea-cli-helper.sh`
- **Dependencies**: Gitea CLI (tea), jq, curl
- **Features**:
  - Repository management (create, delete, list, get info)
  - Issue management (create, close, list)
  - Pull request management (create, merge, list)
  - Branch management (create, list)
  - Multi-instance support (Gitea.com, self-hosted)

## Configuration Templates

Created configuration templates:

- `configs/github-cli-config.json.txt` - GitHub account configuration
- `configs/gitlab-cli-config.json.txt` - GitLab instance configuration
- `configs/gitea-cli-config.json.txt` - Gitea instance configuration

## Main Script Integration

Updated `scripts/servers-helper.sh` to include Git platforms:

- Added github, gitlab, gitea as server options
- Integrated CLI helper delegation
- Updated help documentation

## Usage Examples

### GitHub CLI Helper
```bash
# List configured accounts
./providers/github-cli-helper.sh list-accounts

# List repositories for account
./providers/github-cli-helper.sh list-repos marcusquinn

# Create new repository
./providers/github-cli-helper.sh create-repo marcusquinn my-project My awesome project public true

# List issues
./providers/github-cli-helper.sh list-issues marcusquinn my-repo open

# Create pull request
./providers/github-cli-helper.sh create-pr marcusquinn my-repo Fix bug main bugfix-branch
```

### GitLab CLI Helper
```bash
# List projects
./providers/gitlab-cli-helper.sh list-projects marcusquinn

# Create new project
./providers/gitlab-cli-helper.sh create-project marcusquinn my-project My GitLab project private true

# List issues
./providers/gitlab-cli-helper.sh list-issues marcusquinn my-project opened

# Create merge request
./providers/gitlab-cli-helper.sh create-mr marcusquinn my-project Fix feature fix-branch main
```

### Gitea CLI Helper
```bash
# List repositories
./providers/gitea-cli-helper.sh list-repos marcusquinn

# Create new repository
./providers/gitea-cli-helper.sh create-repo marcusquinn my-gitea-project My Gitea project private true

# List issues
./providers/gitea-cli-helper.sh list-issues marcusquinn my-repo open

# Create pull request
./providers/gitea-cli-helper.sh create-pr marcusquinn my-repo Fix bug bugfix-branch main
```

## Setup Instructions

1. Install required CLI tools:
   - GitHub CLI: `brew install gh` or https://cli.github.com/manual/installation
   - GitLab CLI: `brew install glab` or https://glab.readthedocs.io/en/latest/installation/
   - Gitea CLI: `go install code.gitea.io/tea/cmd/tea@latest` or https://dl.gitea.io/tea/

2. Configure authentication:
   - GitHub: `gh auth login`
   - GitLab: `glab auth login`
   - Gitea: `tea login add` or configure API token in config

3. Copy and customize configuration templates:
   ```bash
   cp configs/github-cli-config.json.txt configs/github-cli-config.json
   cp configs/gitlab-cli-config.json.txt configs/gitlab-cli-config.json
   cp configs/gitea-cli-config.json.txt configs/gitea-cli-config.json
   ```

4. Edit configuration files with your account details and tokens

## Quality Standards

All scripts pass ShellCheck validation and follow framework coding patterns:
- Comprehensive error handling
- Consistent command patterns
- Multi-account support
- Detailed help documentation
- Secure credential management

## Integration with Existing Framework

- Integrated with main servers-helper.sh
- Follows established provider patterns
- Uses consistent configuration structure
- Maintains framework quality standards

