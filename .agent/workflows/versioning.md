# Version Management for AI DevOps Framework

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Get version**: `./.agent/scripts/version-manager.sh get`
- **Bump**: `./.agent/scripts/version-manager.sh bump [major|minor|patch]`
- **Full release**: `./.agent/scripts/version-manager.sh release [major|minor|patch]`
- **Validate**: `./.agent/scripts/version-manager.sh validate`
- **Create tag**: `./.agent/scripts/version-manager.sh tag`
- **GitHub release**: `./.agent/scripts/version-manager.sh github-release`
- **Auto-bump**: `./.agent/scripts/auto-version-bump.sh "commit message"`
- **Files updated**: VERSION, README.md badge, sonar-project.properties, setup.sh
- **Commit patterns**: BREAKING/MAJOR (major), FEATURE/NEW (minor), FIX/PATCH (patch)
- **Skip patterns**: docs, style, test, chore, ci, WIP, SKIP VERSION
<!-- AI-CONTEXT-END -->

**Professional semantic versioning with automated GitHub release creation**

## Overview

The AI DevOps Framework uses professional semantic versioning with automated tools for version bumping, git tagging, and GitHub release creation. This ensures consistent versioning across all framework components and provides clear release tracking.

## Version Management Tools

### Primary Tool: version-manager.sh

- **Location**: `.agent/scripts/version-manager.sh`
- **Purpose**: Manual version control with comprehensive features
- **Capabilities**: Version bumping, file updates, git tagging, GitHub releases

### Automation Tool: auto-version-bump.sh

- **Location**: `.agent/scripts/auto-version-bump.sh`
- **Purpose**: Intelligent version detection from commit messages
- **Capabilities**: Automatic version bumping based on commit patterns

### GitHub Integration

GitHub releases are created via `gh` CLI (preferred) or GitHub API fallback:
- **Primary**: `gh release create` with keyring-based authentication
- **Fallback**: GitHub API with `GITHUB_TOKEN` environment variable
- **Managed by**: `version-manager.sh github-release` command

## Usage Guide

### **Manual Version Control**

#### **Get Current Version**

```bash
./.agent/scripts/version-manager.sh get
```

#### **Bump Version**

```bash
# Patch version (1.3.0 → 1.3.1)
./.agent/scripts/version-manager.sh bump patch

# Minor version (1.3.0 → 1.4.0)
./.agent/scripts/version-manager.sh bump minor

# Major version (1.3.0 → 2.0.0)
./.agent/scripts/version-manager.sh bump major
```

#### **Create Git Tag**

```bash
./.agent/scripts/version-manager.sh tag
```

#### **Create GitHub Release**

```bash
./.agent/scripts/version-manager.sh github-release
```

#### **Complete Release Process**

```bash
# Bump version, update files, validate consistency, create tag, and create GitHub release
./.agent/scripts/version-manager.sh release minor
```

#### **Version Validation**

```bash
# Validate current version consistency across all files
./.agent/scripts/version-manager.sh validate

# Or use the standalone validator
./.agent/scripts/validate-version-consistency.sh

# Validate specific version
./.agent/scripts/validate-version-consistency.sh 1.6.0
```

### **Automatic Version Detection**

#### **Commit Message Patterns**

**MAJOR Version (Breaking Changes):**

- `BREAKING`, `MAJOR`, `💥`, `🚨 BREAKING`
- Example: `💥 BREAKING: Change API structure`

**MINOR Version (New Features):**

- `FEATURE`, `FEAT`, `NEW`, `ADD`, `✨`, `🚀`, `📦`, `🎯 NEW/ADD`
- Example: `✨ FEATURE: Add Agno integration`

**PATCH Version (Bug Fixes/Improvements):**

- `FIX`, `PATCH`, `BUG`, `IMPROVE`, `UPDATE`, `ENHANCE`, `🔧`, `🐛`, `📝`, `🎨`, `♻️`, `⚡`, `🔒`, `📊`
- Example: `🔧 FIX: Resolve badge display issue`

**SKIP Version Bump:**

- `docs`, `style`, `test`, `chore`, `ci`, `build`, `WIP`, `SKIP VERSION`, `NO VERSION`

#### **Usage**

```bash
# Analyze commit message and bump version accordingly
./.agent/scripts/auto-version-bump.sh "🚀 FEATURE: Add new integration"
```

## Automated File Updates

### Files Updated Automatically

1. **VERSION**: Central version file
2. **README.md**: Version badge
3. **sonar-project.properties**: SonarCloud version
4. **setup.sh**: Script version header

### **Version Validation & Consistency**

The framework now includes comprehensive version validation to ensure all version references stay synchronized:

#### **Automatic Validation**

- **Release Process**: Validates version consistency before creating releases
- **Improved Regex**: Handles single and multi-digit version numbers correctly
- **Error Detection**: Identifies mismatched versions across files
- **Validation Feedback**: Clear success/error messages for each file

#### **Manual Validation**

```bash
# Validate current version consistency
./.agent/scripts/validate-version-consistency.sh

# Validate specific version
./.agent/scripts/validate-version-consistency.sh 1.6.0

# Through version manager
./.agent/scripts/version-manager.sh validate
```

#### **Validation Coverage**

- ✅ **VERSION file**: Central version source
- ✅ **README.md badge**: Version display badge
- ✅ **sonar-project.properties**: SonarCloud integration
- ✅ **setup.sh**: Script version header
- ⚠️ **Optional files**: Warns if missing but doesn't fail

### **Update Process**

- Version bumping automatically updates all version references
- Cross-file synchronization ensures consistency
- Git staging includes all updated files

## GitHub Release Creation

### Multiple Methods Supported

#### **1. GitHub CLI (Preferred)**

```bash
# Install GitHub CLI
brew install gh  # macOS
# or visit https://cli.github.com/

# Authenticate
gh auth login

# Releases will be created automatically
```

#### **2. GitHub API (Fallback)**

```bash
# Set GitHub token (only needed if gh CLI not authenticated)
export GITHUB_TOKEN=your_personal_access_token

# Create release via version-manager
./.agent/scripts/version-manager.sh github-release
```

#### **3. Manual Creation**

If neither method is available, the system will skip GitHub release creation with helpful instructions.

### **Release Notes Generation**

- Automatic generation based on version and framework status
- Includes changelog links, documentation references, and quick start guides
- Professional formatting with emojis and clear structure

## Version History Tracking

Version history is maintained in CHANGELOG.md. Key milestones:

- **v1.x**: Initial framework with version management, Pandoc, Agno integration
- **v2.x**: Enhanced agent architecture, code quality automation, MCP integrations

### **Semantic Versioning Rules**

- **MAJOR**: Breaking changes, API modifications, architectural changes
- **MINOR**: New features, service integrations, significant enhancements
- **PATCH**: Bug fixes, documentation updates, minor improvements

## Configuration

### Environment Variables

```bash
# GitHub API access (optional)
export GITHUB_TOKEN=your_personal_access_token

# Custom version file location (optional)
export VERSION_FILE=/path/to/VERSION

# Custom repository information (optional)
export REPO_OWNER=marcusquinn
export REPO_NAME=aidevops
```

### **Customization**

- Edit version-manager.sh to customize file update patterns
- Modify release note templates in generate_release_notes function
- Adjust commit message patterns in auto-version-bump.sh

## Troubleshooting

### Common Issues

#### **GitHub CLI Not Authenticated**

```bash
gh auth login
# Follow the prompts to authenticate
```

#### **GitHub Token Issues**

```bash
# Check token permissions
curl -H "Authorization: token $GITHUB_TOKEN" https://api.github.com/user

# Token needs 'repo' scope for release creation
```

#### **Version File Not Found**

```bash
# Ensure VERSION file exists in repository root
echo "1.3.0" > VERSION
```

#### **Permission Issues**

```bash
# Fix script permissions
chmod +x .agent/scripts/*.sh
```

### **Validation**

```bash
# Check current version
./.agent/scripts/version-manager.sh get

# Verify GitHub releases
curl -s https://api.github.com/repos/marcusquinn/aidevops/releases | jq '.[].tag_name'

# Test version bump (dry run)
./.agent/scripts/auto-version-bump.sh "🔧 TEST: Version bump test"
```

## Best Practices

### Version Bumping

1. **Use semantic versioning**: Follow MAJOR.MINOR.PATCH format
2. **Clear commit messages**: Use conventional commit patterns
3. **Test before release**: Verify functionality before version bumps
4. **Document changes**: Include meaningful release notes

### **Release Management**

1. **Consistent timing**: Regular release cycles
2. **Quality gates**: Ensure all tests pass before release
3. **Documentation**: Update docs with each release
4. **Communication**: Clear release announcements

### **Automation**

1. **Commit patterns**: Use consistent emoji and keyword patterns
2. **CI/CD integration**: Automate version bumping in pipelines
3. **Quality checks**: Validate version consistency across files
4. **Backup**: Maintain version history and tags

---

**Professional version management for enterprise-grade AI DevOps automation.**
