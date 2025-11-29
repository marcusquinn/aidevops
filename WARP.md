# WARP.md

This file provides guidance to WARP (warp.dev) when working with code in this repository.

## Overview

**AI DevOps Framework** - A comprehensive DevOps infrastructure management framework designed specifically for AI agent automation across 30+ services including hosting providers, DNS, security, Git platforms, and monitoring tools.

This is a **shell script-based framework** (18,000+ lines) with enterprise-grade quality standards, maintained across multiple quality platforms (SonarCloud, CodeFactor, Codacy, CodeRabbit, Qlty).

## Essential Reading

**ALWAYS read `AGENTS.md` first** - This is the authoritative single source of truth for all AI assistant instructions, operational patterns, security practices, and framework capabilities. All development work must follow the guidance in AGENTS.md.

## Common Commands

### Setup & Installation

```bash
# Initial setup (run once after cloning)
./setup.sh

# Setup specific Git CLI tools
# GitHub CLI
gh auth login
cp configs/github-cli-config.json.txt configs/github-cli-config.json

# GitLab CLI
glab auth login
cp configs/gitlab-cli-config.json.txt configs/gitlab-cli-config.json

# Gitea CLI
tea login add
cp configs/gitea-cli-config.json.txt configs/gitea-cli-config.json
```

### Quality Assurance (MANDATORY)

**Before any commits, run quality checks:**

```bash
# Comprehensive multi-platform quality validation
bash .agent/scripts/quality-check.sh

# Run all quality CLI tools
bash .agent/scripts/quality-cli-manager.sh analyze all

# Individual quality tools
bash .agent/scripts/coderabbit-cli.sh review      # AI-powered code review
bash .agent/scripts/codacy-cli.sh analyze         # Multi-tool analysis
bash .agent/scripts/codacy-cli.sh analyze --fix   # Auto-fix issues
bash .agent/scripts/qlty-cli.sh check             # 70+ tools, 40+ languages
bash .agent/scripts/qlty-cli.sh fmt --all         # Universal auto-formatting
bash .agent/scripts/sonarscanner-cli.sh analyze   # SonarCloud analysis

# ShellCheck validation (MANDATORY for shell scripts)
find providers/ -name "*.sh" -exec shellcheck {} \;
```

### Development & Testing

```bash
# List all available servers and services
./.agent/scripts/servers-helper.sh list

# Test specific provider connections
./providers/hostinger-helper.sh list
./providers/hetzner-helper.sh list
./providers/github-cli-helper.sh list-accounts

# Test TOON format (AI-optimized data format)
./providers/toon-helper.sh info

# Test DSPy integration (prompt optimization)
./providers/dspy-helper.sh test

# Run linter detection and setup
bash .agent/scripts/linter-manager.sh detect
bash .agent/scripts/linter-manager.sh install-detected
```

### Provider Management

```bash
# Server operations (examples)
./providers/hostinger-helper.sh [command] [site] [options]
./providers/hetzner-helper.sh [command] [account] [server] [options]
./providers/coolify-helper.sh [command] [account] [project] [options]

# DNS management
./providers/dns-helper.sh [provider] [command] [domain] [options]

# Git platform operations
./providers/github-cli-helper.sh [command] [account] [options]
./providers/gitlab-cli-helper.sh [command] [account] [options]
./providers/gitea-cli-helper.sh [command] [account] [options]

# Domain purchasing and management
./providers/spaceship-helper.sh [command] [domain] [options]
./providers/101domains-helper.sh [command] [domain] [options]

# Monitoring
./providers/updown-helper.sh list                  # Uptime monitoring
./providers/pagespeed-helper.sh [command] [url]    # Performance auditing
```

### AI Assistant Configuration

```bash
# Setup AI CLI tools to read AGENTS.md automatically
bash .agent/scripts/ai-cli-config.sh

# Setup API keys for quality/monitoring services
bash .agent/scripts/setup-local-api-keys.sh setup

# View available AI memory files
ls -la ~/ | grep -E "CLAUDE|GEMINI|WINDSURF|DROID"
```

## Architecture

### Directory Structure

```
aidevops/
├── AGENTS.md                 # ⚠️ AUTHORITATIVE guidance (read first!)
├── README.md                 # User-facing documentation
├── setup.sh                  # Main setup script
├── providers/                # 30+ service helper scripts (core functionality)
│   ├── shared-constants.sh   # Common constants and error messages
│   ├── *-helper.sh           # Individual provider scripts
│   └── standard-functions.sh # Reusable script patterns
├── scripts/
│   └── servers-helper.sh     # Unified server access across providers
├── configs/                  # Configuration templates (*.json.txt)
├── docs/                     # Service-specific documentation
├── .agent/                   # AI agent development tools
│   ├── scripts/              # Quality automation and development tools
│   │   ├── quality-check.sh      # Multi-platform validation
│   │   ├── quality-fix.sh        # Universal automated fixes
│   │   ├── quality-cli-manager.sh # Unified quality tool interface
│   │   ├── coderabbit-cli.sh     # AI-powered code review
│   │   ├── codacy-cli.sh         # Multi-tool analysis
│   │   ├── qlty-cli.sh           # Universal linting/formatting
│   │   └── sonarscanner-cli.sh   # SonarCloud analysis
│   ├── spec/                 # Technical specifications
│   │   └── code-quality.md   # Quality standards reference
│   └── wiki/                 # Internal knowledge base
├── ssh/                      # SSH key management utilities
└── templates/                # Deployment templates for AI assistants
```

### Provider Script Architecture

All provider scripts follow a **unified command pattern**:

```bash
./providers/[service]-helper.sh [command] [account/instance] [target] [options]
```

**Common Commands Available:**

- `help` - Show service-specific help
- `accounts` or `instances` - List configured accounts/instances
- `list` - List resources (servers, domains, repos, etc.)
- `connect` or `ssh` - Connect to resource
- `exec` - Execute commands remotely
- `monitor` or `status` - Service monitoring
- `create` - Create new resources
- `delete` - Remove resources

### Key Architectural Patterns

1. **Shared Constants** (`providers/shared-constants.sh`):
   - HTTP headers, status codes
   - Common error/success messages
   - Validation patterns and timeouts
   - Color codes for consistent output

2. **Configuration Management**:
   - Templates in `configs/*.json.txt` (committed to git)
   - Actual configs in `configs/*.json` (gitignored, contains credentials)
   - JSON-based with jq for parsing

3. **Security-First Design**:
   - Credentials stored in separate config files
   - Ed25519 SSH keys recommended
   - Vaultwarden integration for secure retrieval
   - Never expose credentials in logs or output

4. **Multi-Account Support**:
   - Each provider supports multiple accounts/instances
   - Account-specific configurations in JSON
   - CLI tools (gh, glab, tea) for enhanced Git platform management

## Coding Standards (MANDATORY)

### Shell Script Quality Requirements

**⚠️ These patterns are REQUIRED to maintain A-grade quality:**

#### 1. Function Structure (ALL functions must follow this pattern)

```bash
function_name() {
    # ALWAYS assign positional parameters to local variables first
    local param1="$1"
    local param2="$2"
    local optional_param="${3:-default_value}"
    
    # Function logic here
    
    # ALWAYS add explicit return statement
    return 0
}
```

#### 2. Main Function Pattern

```bash
main() {
    # ALWAYS assign positional parameters to local variables
    local command="${1:-help}"
    local account_name="$2"
    local target="$3"
    
    case "$command" in
        "list")
            list_items "$account_name"
            ;;
        "create")
            create_item "$account_name" "$target"
            ;;
        *)
            show_help
            ;;
    esac
    return 0
}
```

#### 3. String Literal Management

```bash
# Define constants at top of file for repeated strings (3+ occurrences)
readonly ERROR_ACCOUNT_REQUIRED="Account name is required"
readonly ERROR_CONFIG_NOT_FOUND="Configuration file not found"
readonly SUCCESS_OPERATION_COMPLETE="Operation completed successfully"

# Use constants instead of repeated string literals
print_error "$ERROR_ACCOUNT_REQUIRED"
```

#### 4. Variable Usage

```bash
# Only declare variables that are actually used
function_name() {
    local used_variable="$1"
    # Don't declare: local unused_variable="$2"  # This causes S1481 violation
    echo "$used_variable"
    return 0
}
```

### Quality Rule Compliance (Zero Tolerance)

- **S7682**: Every function MUST end with explicit `return 0` or `return 1`
- **S7679**: NEVER use `$1`, `$2`, `$3` directly - always assign to local variables first
- **S1192**: Define constants for any string used 3+ times
- **S1481**: Remove unused variable declarations immediately
- **ShellCheck**: Zero violations across all scripts

### Source Shared Constants

When creating new provider scripts, source shared constants:

```bash
#!/bin/bash
# Source shared constants for consistency
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/shared-constants.sh"
```

## Quality Standards

### Current Status

- **SonarCloud**: 0 issues (Target: <50) ✅ EXCELLENCE ACHIEVED
- **CodeFactor**: A+ rating maintained
- **Codacy**: A+ rating achieved  
- **Critical Issues**: S7679 & S1481 = 0 (Zero violations)
- **Security**: All GitHub Actions pinned to commit SHA

### Quality Workflow

**Before making changes:**

1. Read `AGENTS.md` for authoritative guidance
2. Run `bash .agent/scripts/quality-check.sh` to establish baseline
3. Review `.agent/spec/code-quality.md` for detailed patterns

**After making changes:**

1. Run quality checks again to verify improvements
2. Fix any violations using automated tools
3. Run ShellCheck on modified scripts
4. Commit with quality metrics in commit message

### Automated Quality Tools

- **Codacy Auto-Fix**: `bash .agent/scripts/codacy-cli.sh analyze --fix`
- **Qlty Auto-Format**: `bash .agent/scripts/qlty-cli.sh fmt --all`
- **Universal Fixes**: `bash .agent/scripts/quality-fix.sh`
- **Pre-commit Hook**: `bash .agent/scripts/pre-commit-hook.sh`

## Configuration

### API Keys & Credentials

**Setup local API keys securely:**

```bash
# Setup API key manager
bash .agent/scripts/setup-local-api-keys.sh setup

# Add service-specific keys
bash .agent/scripts/setup-local-api-keys.sh set coderabbit YOUR_API_KEY
bash .agent/scripts/setup-local-api-keys.sh set codacy YOUR_TOKEN
bash .agent/scripts/setup-local-api-keys.sh set qlty-account-api-key YOUR_KEY

# List configured keys (shows masked values)
bash .agent/scripts/setup-local-api-keys.sh list
```

### Provider Configuration

1. **Copy template**: `cp configs/service-config.json.txt configs/service-config.json`
2. **Edit with credentials**: Use your actual API keys, tokens, passwords
3. **Set permissions**: Configs are automatically set to 600 (secure)
4. **Never commit**: Real config files are gitignored

## Git Platform CLI Integration

This framework provides **enhanced CLI helpers** for Git platforms:

### GitHub CLI (gh)

```bash
# Enhanced operations via framework helper
./providers/github-cli-helper.sh list-repos <account>
./providers/github-cli-helper.sh create-repo <account> <repo-name>
./providers/github-cli-helper.sh list-issues <account> <repo>
./providers/github-cli-helper.sh create-pr <account> <repo> <title>
```

### GitLab CLI (glab)

```bash
# Enhanced operations via framework helper
./providers/gitlab-cli-helper.sh list-projects <account>
./providers/gitlab-cli-helper.sh create-project <account> <name>
./providers/gitlab-cli-helper.sh list-issues <account> <project>
./providers/gitlab-cli-helper.sh create-mr <account> <project> <title>
```

### Gitea CLI (tea)

```bash
# Enhanced operations via framework helper
./providers/gitea-cli-helper.sh list-repos <account>
./providers/gitea-cli-helper.sh create-repo <account> <repo-name>
./providers/gitea-cli-helper.sh list-issues <account> <repo>
./providers/gitea-cli-helper.sh create-pr <account> <repo> <title>
```

## MCP (Model Context Protocol) Integrations

10 MCP servers available for real-time AI integration:

```bash
# Install all MCP integrations
bash .agent/scripts/setup-mcp-integrations.sh all

# Install specific integration
bash .agent/scripts/setup-mcp-integrations.sh chrome-devtools
bash .agent/scripts/setup-mcp-integrations.sh playwright
bash .agent/scripts/setup-mcp-integrations.sh ahrefs

# Validate integrations
bash .agent/scripts/validate-mcp-integrations.sh
```

**Available MCPs:**

- Chrome DevTools, Playwright, Cloudflare Browser Rendering (browser automation)
- Ahrefs, Perplexity, Google Search Console (SEO & research)
- PageSpeed Insights (performance auditing)
- Next.js DevTools, Context7, LocalWP (development tools)

## Security Best Practices

1. **Never commit credentials** - Use config templates, gitignore actual configs
2. **Use Ed25519 SSH keys** - Modern, secure, fast
3. **Set proper permissions** - Configs are 600, scripts are executable
4. **Regular rotation** - Rotate API tokens and SSH keys periodically
5. **MFA everywhere** - Enable multi-factor authentication on all accounts
6. **Monitor activity** - Use quality tools to audit code for security issues

## TOON Format

**Token-Oriented Object Notation** - AI-optimized data format:

```bash
# Convert JSON to TOON (20-60% token reduction)
./providers/toon-helper.sh encode data.json output.toon

# Compare efficiency
./providers/toon-helper.sh compare large-dataset.json

# Decode back to JSON
./providers/toon-helper.sh decode output.toon restored.json
```

## Working Directories for AI Agents

**⚠️ CRITICAL**: Use these directories for AI operations:

- **`~/.agent/tmp/`** - Temporary files during operations (session-specific)
- **`~/.agent/memory/`** - Persistent memory across sessions (patterns, preferences)

**DO NOT** store credentials or sensitive data in these directories.

## Version Management

```bash
# Validate version consistency across all files
bash .agent/scripts/validate-version-consistency.sh

# Bump version (auto-updates all files)
bash .agent/scripts/auto-version-bump.sh
```

Current version: **1.9.0** (tracked in README.md, package.json, sonar-project.properties, setup.sh)

## Important Notes

- This framework achieves **industry-leading quality** with 0 SonarCloud issues
- All changes must follow patterns in `AGENTS.md` and `.agent/spec/code-quality.md`
- Use **bulk operations** for universal fixes across multiple files
- **ShellCheck compliance** is mandatory for all shell scripts
- Git platform CLI helpers provide **enhanced capabilities** beyond basic git operations
- **Multi-account support** enables managing multiple instances of each service
- Quality tools provide **automated fixes** (Codacy, Qlty) to accelerate development

## References

- **Authoritative Guide**: `AGENTS.md` (single source of truth)
- **Quality Standards**: `.agent/spec/code-quality.md`
- **Provider Patterns**: `providers/shared-constants.sh`
- **Service Documentation**: `docs/` directory
- **AI Tools Reference**: `docs/AI-CLI-TOOLS.md`
- **MCP Integrations**: `docs/MCP-INTEGRATIONS.md`
- **API Integrations**: `docs/API-INTEGRATIONS.md`
