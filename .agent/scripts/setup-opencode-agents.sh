#!/bin/bash
# =============================================================================
# AI DevOps Framework - OpenCode Agent Setup
# =============================================================================
# Sets up OpenCode agents for the aidevops framework
# Creates subagents in ~/.config/opencode/agent/ and configures opencode.json
#
# Usage: ./setup-opencode-agents.sh [command]
# Commands:
#   install   - Install agents and update opencode.json
#   status    - Show current agent configuration
#   clean     - Remove aidevops agents (keeps other agents)
#   help      - Show this help message
#
# Version: 2.0.8
# =============================================================================

set -euo pipefail

# Configuration
readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
readonly FRAMEWORK_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)" || exit
readonly OPENCODE_CONFIG_DIR="$HOME/.config/opencode"
readonly OPENCODE_AGENT_DIR="$OPENCODE_CONFIG_DIR/agent"
readonly OPENCODE_JSON="$OPENCODE_CONFIG_DIR/opencode.json"

# Colors
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly NC='\033[0m'

# Agent list for cleanup
readonly AGENT_NAMES=(
    "aidevops"
    "hostinger"
    "hetzner"
    "wordpress"
    "seo"
    "code-quality"
    "browser-automation"
    "context7-mcp-setup"
    "google-search-console-examples"
    "git-platforms"
    "crawl4ai-usage"
    "dns-providers"
    "agent-review"
)

print_header() {
    echo -e "${BLUE}========================================${NC}"
    echo -e "${BLUE}  AI DevOps - OpenCode Agent Setup${NC}"
    echo -e "${BLUE}========================================${NC}"
    echo ""
}

print_success() {
    echo -e "${GREEN}✓${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}⚠${NC} $1"
}

print_error() {
    echo -e "${RED}✗${NC} $1"
}

print_info() {
    echo -e "${BLUE}ℹ${NC} $1"
}

check_prerequisites() {
    local errors=0

    # Check if opencode is installed
    if ! command -v opencode &>/dev/null; then
        print_warning "opencode CLI not found - install from https://opencode.ai"
        # Don't fail - user might install later
    fi

    # Check if framework exists
    if [[ ! -f "$FRAMEWORK_DIR/AGENTS.md" ]]; then
        print_error "aidevops framework not found at $FRAMEWORK_DIR"
        errors=$((errors + 1))
    fi

    # Check if opencode config directory exists
    if [[ ! -d "$OPENCODE_CONFIG_DIR" ]]; then
        print_info "Creating OpenCode config directory..."
        mkdir -p "$OPENCODE_CONFIG_DIR"
    fi

    return $errors
}

create_agent_directory() {
    if [[ ! -d "$OPENCODE_AGENT_DIR" ]]; then
        print_info "Creating agent directory: $OPENCODE_AGENT_DIR"
        mkdir -p "$OPENCODE_AGENT_DIR"
    fi
    return 0
}

generate_agent_files() {
    print_info "Generating agent files with full configurations..."
    
    # ==========================================================================
    # PRIMARY AGENT: aidevops
    # ==========================================================================
    cat > "$OPENCODE_AGENT_DIR/aidevops.md" << 'AGENT_EOF'
---
description: AI DevOps Framework - comprehensive infrastructure automation across 29+ services including Hostinger, Hetzner, Cloudflare, GitHub/GitLab/Gitea, MainWP, code quality tools, and more
mode: primary
temperature: 0.2
tools:
  write: true
  edit: true
  bash: true
  read: true
  glob: true
  grep: true
  webfetch: true
  task: true
  context7_*: true
---

# AI DevOps Framework Agent

You are an AI DevOps automation specialist with access to the comprehensive aidevops framework.

## Framework Location

The authoritative framework is located at: `~/git/aidevops/`

**Always read `~/git/aidevops/AGENTS.md` for complete operational guidance.**

## Quick Reference

- **Scripts**: `.agent/scripts/[service]-helper.sh [command] [account] [target]`
- **Docs**: `.agent/*.md` (82 files with AI-CONTEXT blocks)
- **Configs**: `configs/[service]-config.json` (gitignored, use `.json.txt` templates)

## Working Directories

| Purpose | Location |
|---------|----------|
| Work files | `~/.agent/work/[project]/` |
| Temp files | `~/.agent/tmp/session-*/` |
| Credentials | `~/.config/aidevops/mcp-env.sh` (600 perms) |

## Security Rules

- NEVER create files in `~/` root
- NEVER expose credentials in output/logs
- Confirm destructive operations before execution
- Store secrets ONLY in `~/.config/aidevops/mcp-env.sh`

## When to Use Subagents

Invoke specialized subagents for focused tasks:
- `@hostinger` - Hostinger hosting operations
- `@hetzner` - Hetzner Cloud infrastructure
- `@wordpress` - WordPress/MainWP management
- `@seo` - SEO analysis and Google Search Console
- `@code-quality` - Code quality, security scanning, and learning loop
- `@browser-automation` - Chrome DevTools and Playwright
- `@agent-review` - Session analysis and framework improvement

For detailed guidance on any service, read the corresponding `.agent/[service].md` file.

## End of Session

Always offer to run `@agent-review` at the end of significant sessions to capture improvements.
AGENT_EOF
    print_success "Created aidevops.md (primary agent)"

    # ==========================================================================
    # SUBAGENT: hostinger
    # ==========================================================================
    cat > "$OPENCODE_AGENT_DIR/hostinger.md" << 'AGENT_EOF'
---
description: Hostinger hosting operations - website management, WordPress deployment, DNS configuration, domain management, and billing
mode: subagent
temperature: 0.1
tools:
  write: true
  edit: true
  bash: true
  read: true
  hostinger-api_*: true
---

# Hostinger Operations Agent

Specialized agent for Hostinger hosting platform operations.

## Reference Documentation

Read `~/git/aidevops/.agent/hostinger.md` for complete operational guidance.

## Available MCP Tools

This agent has access to the `hostinger-api` MCP server with tools for:

- **Hosting**: List websites, create websites, deploy WordPress/JS apps
- **Domains**: Check availability, purchase domains, manage DNS
- **DNS**: Get/update/delete DNS records, snapshots, restore
- **Billing**: Subscriptions, payment methods, catalog items

## Key Operations

1. **List websites**: Use `hostinger-api_hosting_listWebsitesV1`
2. **Create website**: Use `hostinger-api_hosting_createWebsiteV1`
3. **Manage DNS**: Use `hostinger-api_DNS_*` tools

## Security

Credentials stored in `~/.config/aidevops/mcp-env.sh` - Variable: `HOSTINGER_API_TOKEN`
AGENT_EOF
    print_success "Created hostinger.md (subagent)"

    # ==========================================================================
    # SUBAGENT: hetzner
    # ==========================================================================
    cat > "$OPENCODE_AGENT_DIR/hetzner.md" << 'AGENT_EOF'
---
description: Hetzner Cloud infrastructure - server management, firewalls, volumes, SSH keys, and Docker Compose deployments across multiple accounts
mode: subagent
temperature: 0.1
tools:
  write: true
  edit: true
  bash: true
  read: true
  hetzner-awardsapp_*: true
  hetzner-brandlight_*: true
  hetzner-marcusquinn_*: true
  hetzner-storagebox_*: true
---

# Hetzner Cloud Operations Agent

Specialized agent for Hetzner Cloud infrastructure management across multiple accounts.

## Reference Documentation

Read `~/git/aidevops/.agent/hetzner.md` for complete operational guidance.

## Available Accounts (MCP Servers)

- **hetzner-awardsapp**: AwardsApp account
- **hetzner-brandlight**: Brandlight account  
- **hetzner-marcusquinn**: Personal account
- **hetzner-storagebox**: Storage Box account

## Available MCP Tools (per account)

- **Servers**: list_servers, get_server, create_server, delete_server
- **Power**: power_on, power_off, reboot
- **Firewalls**: list_firewalls, create_firewall, set_firewall_rules
- **Volumes**: list_volumes, create_volume, attach_volume, resize_volume
- **SSH Keys**: list_ssh_keys, create_ssh_key, delete_ssh_key

## Security

Credentials in `~/.config/aidevops/mcp-env.sh` - Variables: `HCLOUD_TOKEN_*`
AGENT_EOF
    print_success "Created hetzner.md (subagent)"

    # ==========================================================================
    # SUBAGENT: wordpress
    # ==========================================================================
    cat > "$OPENCODE_AGENT_DIR/wordpress.md" << 'AGENT_EOF'
---
description: WordPress and MainWP operations - local development with LocalWP, multi-site management via MainWP, theme/plugin deployment
mode: subagent
temperature: 0.2
tools:
  write: true
  edit: true
  bash: true
  read: true
  localwp_*: true
  context7_*: true
---

# WordPress Operations Agent

Specialized agent for WordPress development and management.

## Reference Documentation

- `~/git/aidevops/.agent/localwp-mcp.md` - LocalWP MCP integration
- `~/git/aidevops/.agent/mainwp.md` - MainWP multi-site management

## Available MCP Tools

### LocalWP MCP (localwp_*)

- `localwp_mysql_query` - Execute read-only SQL queries
- `localwp_mysql_schema` - Inspect database schema and tables

## Working Directory

Use `~/.agent/work/wordpress/` for theme customizations, plugin development, content drafts.
AGENT_EOF
    print_success "Created wordpress.md (subagent)"

    # ==========================================================================
    # SUBAGENT: seo
    # ==========================================================================
    cat > "$OPENCODE_AGENT_DIR/seo.md" << 'AGENT_EOF'
---
description: SEO analysis and research - Google Search Console data, Ahrefs backlink/keyword analysis, PageSpeed insights, and content optimization
mode: subagent
temperature: 0.2
tools:
  write: true
  edit: true
  bash: true
  read: true
  webfetch: true
  gsc_*: true
  ahrefs_*: true
---

# SEO Operations Agent

Specialized agent for SEO analysis, keyword research, and search performance optimization.

## Reference Documentation

- `~/git/aidevops/.agent/google-search-console-examples.md` - GSC query examples
- `~/git/aidevops/.agent/pagespeed-lighthouse.md` - Performance analysis

## Available MCP Tools

### Google Search Console (gsc_*)

- `gsc_list_sites` - List all verified sites
- `gsc_search_analytics` - Get search performance data
- `gsc_index_inspect` - Check URL indexing status
- `gsc_list_sitemaps` / `gsc_submit_sitemap` - Sitemap management

## Working Directory

Use `~/.agent/work/seo/` for keyword research, content briefs, competitor analysis.
AGENT_EOF
    print_success "Created seo.md (subagent)"

    # ==========================================================================
    # SUBAGENT: code-quality (with learning loop)
    # ==========================================================================
    cat > "$OPENCODE_AGENT_DIR/code-quality.md" << 'AGENT_EOF'
---
description: Code quality and security scanning - SonarCloud, Codacy, CodeRabbit, Qlty, Snyk, ShellCheck for comprehensive code analysis, automated fixes, and framework improvement
mode: subagent
temperature: 0.1
tools:
  write: true
  edit: true
  bash: true
  read: true
  glob: true
  grep: true
  context7_*: true
permission:
  edit: ask
  bash:
    "git *": ask
    "gh pr *": ask
    "*": allow
---

# Code Quality Agent

Specialized agent for code quality analysis, security scanning, automated fixes, and **preventing recurrence through framework improvement**.

## Reference Documentation

- `~/git/aidevops/.agent/code-quality.md` - Quality standards
- `~/git/aidevops/.agent/codacy-auto-fix.md` - Automated fixing
- `~/git/aidevops/.agent/snyk.md` - Security scanning

## Quality Tools

```bash
# SonarCloud
~/git/aidevops/.agent/scripts/sonarscanner-cli.sh analyze

# Codacy with auto-fix
~/git/aidevops/.agent/scripts/codacy-cli.sh analyze --fix

# Qlty
~/git/aidevops/.agent/scripts/qlty-cli.sh check
~/git/aidevops/.agent/scripts/qlty-cli.sh fmt --all

# ShellCheck
find .agent/scripts/ -name "*.sh" -exec shellcheck {} \;
```

## Learning Loop

After fixing issues, analyze patterns to prevent recurrence:

```
Quality Issue → Fix Applied → Pattern Identified → Framework Updated → Issue Prevented
```

### After Fixing Issues:

1. **Categorize** - Shell scripting, security, style, architecture?
2. **Analyze root cause** - Why didn't the framework prevent this?
3. **Update framework** - Add guidance to AGENTS.md or .agent/*.md
4. **Submit PR** - Contribute prevention back to aidevops

### Common Mappings

| ShellCheck | Framework Update |
|------------|------------------|
| SC2162 | Add `read -r` examples to AGENTS.md |
| SC2181 | Add pattern to code-quality.md |
| SC2155 | Add to shell script templates |

### Create PR for Improvements

```bash
cd ~/git/aidevops || exit
git checkout -b improve/quality-[rule]-[date]
# Apply changes
git commit -m "improve(quality): prevent [rule] violations"
gh pr create --title "improve(quality): prevent [rule] violations" --body "..."
```
AGENT_EOF
    print_success "Created code-quality.md (subagent with learning loop)"

    # ==========================================================================
    # SUBAGENT: browser-automation
    # ==========================================================================
    cat > "$OPENCODE_AGENT_DIR/browser-automation.md" << 'AGENT_EOF'
---
description: Browser automation and testing - Chrome DevTools for debugging and performance, Playwright for cross-browser testing, web scraping with Crawl4AI
mode: subagent
temperature: 0.2
tools:
  write: true
  edit: true
  bash: true
  read: true
  chrome-devtools_*: true
  context7_*: true
---

# Browser Automation Agent

Specialized agent for browser automation, testing, and performance analysis.

## Reference Documentation

- `~/git/aidevops/.agent/browser-automation.md` - Overview
- `~/git/aidevops/.agent/chrome-devtools-examples.md` - DevTools examples
- `~/git/aidevops/.agent/playwright-automation-examples.md` - Playwright examples

## Available MCP Tools (chrome-devtools_*)

- **Navigation**: navigate_page, list_pages, select_page, new_page
- **Interaction**: click, fill, fill_form, hover, drag, press_key
- **Inspection**: take_snapshot, take_screenshot, evaluate_script
- **Network**: list_network_requests, get_network_request
- **Performance**: performance_start_trace, performance_analyze_insight
AGENT_EOF
    print_success "Created browser-automation.md (subagent)"

    # ==========================================================================
    # SUBAGENT: context7-mcp-setup
    # ==========================================================================
    cat > "$OPENCODE_AGENT_DIR/context7-mcp-setup.md" << 'AGENT_EOF'
---
description: Context7 documentation search - real-time access to library documentation for development tasks
mode: subagent
temperature: 0.2
tools:
  read: true
  webfetch: true
  context7_*: true
---

# Context7 Documentation Agent

Specialized agent for searching and retrieving library documentation.

## Available MCP Tools

- `context7_resolve-library-id` - Find library ID for documentation
- `context7_get-library-docs` - Fetch documentation for a library

## Usage Pattern

1. Resolve: `context7_resolve-library-id({ libraryName: "react" })`
2. Fetch: `context7_get-library-docs({ context7CompatibleLibraryID: "/facebook/react", topic: "hooks" })`
AGENT_EOF
    print_success "Created context7-mcp-setup.md (subagent)"

    # ==========================================================================
    # SUBAGENT: google-search-console-examples
    # ==========================================================================
    cat > "$OPENCODE_AGENT_DIR/google-search-console-examples.md" << 'AGENT_EOF'
---
description: Google Search Console queries and examples - search performance analysis, indexing status, sitemap management
mode: subagent
temperature: 0.1
tools:
  read: true
  gsc_*: true
---

# Google Search Console Agent

Specialized agent for Google Search Console operations.

## Reference Documentation

Read `~/git/aidevops/.agent/google-search-console-examples.md` for detailed examples.

## Available MCP Tools

- `gsc_list_sites` - List all verified sites
- `gsc_search_analytics` - Query search performance data
- `gsc_index_inspect` - Check URL indexing status
- `gsc_list_sitemaps` / `gsc_get_sitemap` / `gsc_submit_sitemap`
AGENT_EOF
    print_success "Created google-search-console-examples.md (subagent)"

    # ==========================================================================
    # SUBAGENT: git-platforms
    # ==========================================================================
    cat > "$OPENCODE_AGENT_DIR/git-platforms.md" << 'AGENT_EOF'
---
description: Git platform operations - GitHub, GitLab, Gitea repository management, issues, PRs/MRs, branches, and CI/CD workflows
mode: subagent
temperature: 0.1
tools:
  write: true
  edit: true
  bash: true
  read: true
  glob: true
  grep: true
  gh_grep_*: true
  context7_*: true
---

# Git Platforms Agent

Specialized agent for Git repository management across GitHub, GitLab, and Gitea.

## Reference Documentation

- `~/git/aidevops/.agent/git-platforms.md` - Overview
- `~/git/aidevops/.agent/github-cli.md` - GitHub CLI (gh)
- `~/git/aidevops/.agent/gitlab-cli.md` - GitLab CLI (glab)
- `~/git/aidevops/.agent/gitea-cli.md` - Gitea CLI (tea)

## CLI Tools

- **GitHub**: `gh repo list`, `gh issue list`, `gh pr create`
- **GitLab**: `glab project list`, `glab mr create`
- **Gitea**: `tea repo list`, `tea pr create`

## GitHub Code Search

`gh_grep_searchGitHub({ query: "useState(", language: ["TypeScript"] })`
AGENT_EOF
    print_success "Created git-platforms.md (subagent)"

    # ==========================================================================
    # SUBAGENT: crawl4ai-usage
    # ==========================================================================
    cat > "$OPENCODE_AGENT_DIR/crawl4ai-usage.md" << 'AGENT_EOF'
---
description: Web crawling and data extraction - Crawl4AI for LLM-friendly content scraping, structured data extraction, and RAG pipelines
mode: subagent
temperature: 0.2
tools:
  write: true
  edit: true
  bash: true
  read: true
  webfetch: true
  context7_*: true
---

# Crawl4AI Agent

Specialized agent for web crawling and data extraction.

## Reference Documentation

- `~/git/aidevops/.agent/crawl4ai.md` - Overview
- `~/git/aidevops/.agent/crawl4ai-usage.md` - Usage examples

## Features

- LLM-Ready Output: Clean markdown for RAG pipelines
- Structured Extraction: CSS selectors, XPath, LLM-based
- High Performance: Parallel crawling, async operations
AGENT_EOF
    print_success "Created crawl4ai-usage.md (subagent)"

    # ==========================================================================
    # SUBAGENT: dns-providers
    # ==========================================================================
    cat > "$OPENCODE_AGENT_DIR/dns-providers.md" << 'AGENT_EOF'
---
description: DNS management - Cloudflare, Namecheap, Route 53, and domain registrar operations for DNS records, zones, and domain configuration
mode: subagent
temperature: 0.1
tools:
  write: true
  edit: true
  bash: true
  read: true
  hostinger-api_DNS_*: true
---

# DNS Providers Agent

Specialized agent for DNS and domain management across providers.

## Reference Documentation

- `~/git/aidevops/.agent/dns-providers.md` - Overview
- `~/git/aidevops/.agent/cloudflare-setup.md` - Cloudflare configuration

## Supported Providers

- **Cloudflare**: `~/git/aidevops/.agent/scripts/cloudflare-dns-helper.sh`
- **Namecheap**: `~/git/aidevops/.agent/scripts/namecheap-dns-helper.sh`
- **Route 53**: AWS CLI commands
- **Hostinger**: `hostinger-api_DNS_*` MCP tools
AGENT_EOF
    print_success "Created dns-providers.md (subagent)"

    # ==========================================================================
    # SUBAGENT: agent-review (meta-agent for continuous improvement)
    # ==========================================================================
    cat > "$OPENCODE_AGENT_DIR/agent-review.md" << 'AGENT_EOF'
---
description: Session review agent - analyzes conversation to identify missing, incorrect, or excessive information in aidevops agents, suggests improvements, and composes PRs for the aidevops repo
mode: subagent
temperature: 0.3
tools:
  read: true
  write: true
  edit: true
  glob: true
  bash: true
permission:
  edit: ask
  bash:
    "git *": ask
    "gh pr *": ask
    "*": deny
---

# Agent Review - Continuous Improvement Agent

You are a meta-agent responsible for analyzing AI assistant sessions and improving the aidevops framework.

## Purpose

After a session, analyze the conversation to identify:
1. **Missing information** - What guidance was needed but not provided?
2. **Incorrect information** - What was wrong or outdated?
3. **Misleading information** - What caused confusion or wrong approaches?
4. **Excessive information** - What was unnecessary and wasted context tokens?
5. **Tool gaps** - What MCPs or tools should have been enabled but weren't?

## Analysis Framework

### Step 1: Identify Agents Used

- Which `@agent` mentions occurred?
- Which agent documentation files were read?
- Which MCPs were called?

### Step 2: Evaluate Each Agent

| Criteria | Questions |
|----------|-----------|
| **Completeness** | Did it have all needed commands, examples, patterns? |
| **Accuracy** | Were APIs, paths, commands correct and current? |
| **Clarity** | Was guidance clear or did it cause confusion? |
| **Efficiency** | Was there unnecessary content bloating context? |
| **Tool Access** | Were the right MCPs/tools enabled? |

### Step 3: Generate Improvement Report

```markdown
## Agent Review Report

### Session Summary
- Primary task: [what was being accomplished]
- Agents used: [list]
- Outcome: [success/partial/failed]

### Issues Identified

#### [Agent Name]
- **Issue Type**: [missing/incorrect/misleading/excessive]
- **Description**: [what went wrong]
- **Suggested Fix**: [specific improvement]
- **File to Edit**: [path]

### Recommended Changes
1. [Specific change with file path]
```

## Agent File Locations

| Location | Purpose |
|----------|---------|
| `~/.config/opencode/agent/*.md` | OpenCode agent definitions |
| `~/git/aidevops/.agent/*.md` | Framework documentation (82 files) |
| `~/git/aidevops/AGENTS.md` | Authoritative framework guidance |

## Step 4: Compose and Submit PR

If the user wants to contribute improvements:

1. **Create branch**:
   ```bash
   cd ~/git/aidevops || exit
   git checkout -b improve/agent-[name]-[date]
   ```

2. **Apply changes** to framework files

3. **Commit**:
   ```bash
   git commit -m "improve([agent]): [description]
   
   Based on real-world usage session feedback via @agent-review"
   ```

4. **Create PR**:
   ```bash
   gh pr create --title "improve([agent]): [description]" --body "..."
   ```

## Continuous Improvement Cycle

```
Session → @agent-review → Improvements → PR to aidevops → Better Agents → Better Sessions
```
AGENT_EOF
    print_success "Created agent-review.md (meta-agent for improvement)"

    return 0
}

generate_opencode_json_config() {
    print_info "Generating opencode.json agent configuration..."
    
    # Check if opencode.json exists
    if [[ ! -f "$OPENCODE_JSON" ]]; then
        print_warning "opencode.json not found - creating minimal config"
        cat > "$OPENCODE_JSON" << 'JSON_EOF'
{
  "$schema": "https://opencode.ai/config.json",
  "mcp": {},
  "tools": {},
  "agent": {}
}
JSON_EOF
    fi
    
    # Create a temporary file with the agent configuration to merge
    local agent_config
    agent_config=$(cat << 'AGENT_CONFIG_EOF'
{
  "aidevops": {
    "description": "AI DevOps Framework - comprehensive infrastructure automation across 29+ services",
    "mode": "primary",
    "temperature": 0.2,
    "tools": {
      "write": true,
      "edit": true,
      "bash": true,
      "read": true,
      "glob": true,
      "grep": true,
      "webfetch": true,
      "task": true,
      "context7_*": true
    }
  },
  "hostinger": {
    "description": "Hostinger hosting operations - websites, WordPress, DNS, domains, billing",
    "mode": "subagent",
    "temperature": 0.1,
    "tools": {
      "hostinger-api_*": true
    }
  },
  "hetzner": {
    "description": "Hetzner Cloud infrastructure - servers, firewalls, volumes, SSH keys across multiple accounts",
    "mode": "subagent",
    "temperature": 0.1,
    "tools": {
      "hetzner-awardsapp_*": true,
      "hetzner-brandlight_*": true,
      "hetzner-marcusquinn_*": true,
      "hetzner-storagebox_*": true
    }
  },
  "wordpress": {
    "description": "WordPress and MainWP operations - local development, multi-site management",
    "mode": "subagent",
    "temperature": 0.2,
    "tools": {
      "localwp_*": true,
      "context7_*": true
    }
  },
  "seo": {
    "description": "SEO analysis - Google Search Console, Ahrefs, PageSpeed insights",
    "mode": "subagent",
    "temperature": 0.2,
    "tools": {
      "gsc_*": true,
      "ahrefs_*": true,
      "webfetch": true
    }
  },
  "code-quality": {
    "description": "Code quality and security scanning with framework improvement learning loop",
    "mode": "subagent",
    "temperature": 0.1,
    "tools": {
      "write": true,
      "edit": true,
      "bash": true,
      "read": true,
      "glob": true,
      "grep": true,
      "context7_*": true
    },
    "permission": {
      "edit": "ask",
      "bash": {
        "git *": "ask",
        "gh pr *": "ask",
        "*": "allow"
      }
    }
  },
  "browser-automation": {
    "description": "Browser automation and testing - Chrome DevTools, Playwright, web scraping",
    "mode": "subagent",
    "temperature": 0.2,
    "tools": {
      "chrome-devtools_*": true,
      "MCP_DOCKER_*": true,
      "context7_*": true
    }
  },
  "context7-mcp-setup": {
    "description": "Context7 documentation search - real-time library documentation access",
    "mode": "subagent",
    "temperature": 0.2,
    "tools": {
      "context7_*": true,
      "webfetch": true
    }
  },
  "google-search-console-examples": {
    "description": "Google Search Console queries - search analytics, indexing, sitemaps",
    "mode": "subagent",
    "temperature": 0.1,
    "tools": {
      "gsc_*": true
    }
  },
  "git-platforms": {
    "description": "Git platform operations - GitHub, GitLab, Gitea repository management",
    "mode": "subagent",
    "temperature": 0.1,
    "tools": {
      "gh_grep_*": true,
      "bash": true,
      "context7_*": true
    }
  },
  "crawl4ai-usage": {
    "description": "Web crawling - Crawl4AI for LLM-friendly content extraction",
    "mode": "subagent",
    "temperature": 0.2,
    "tools": {
      "bash": true,
      "webfetch": true,
      "context7_*": true
    }
  },
  "dns-providers": {
    "description": "DNS management - Cloudflare, Namecheap, Route 53, domain configuration",
    "mode": "subagent",
    "temperature": 0.1,
    "tools": {
      "bash": true,
      "hostinger-api_DNS_*": true
    }
  },
  "agent-review": {
    "description": "Session review - analyzes conversations, identifies agent improvements, and composes PRs to contribute back to aidevops",
    "mode": "subagent",
    "temperature": 0.3,
    "tools": {
      "read": true,
      "write": true,
      "edit": true,
      "glob": true,
      "bash": true
    },
    "permission": {
      "edit": "ask",
      "bash": {
        "git *": "ask",
        "gh pr *": "ask",
        "*": "deny"
      }
    }
  }
}
AGENT_CONFIG_EOF
)
    
    print_info "Agent configuration ready for opencode.json"
    print_info "To apply, add the 'agent' section to your opencode.json"
    echo ""
    echo "Agent configuration saved. You can merge it into opencode.json manually or"
    echo "the agents will work from the markdown files in ~/.config/opencode/agent/"
    
    return 0
}

show_status() {
    print_header
    
    echo "Agent Directory: $OPENCODE_AGENT_DIR"
    echo ""
    
    if [[ -d "$OPENCODE_AGENT_DIR" ]]; then
        local agent_count
        agent_count=$(find "$OPENCODE_AGENT_DIR" -name "*.md" 2>/dev/null | wc -l | tr -d ' ')
        
        if [[ "$agent_count" -gt 0 ]]; then
            print_success "Found $agent_count agent(s):"
            echo ""
            for agent_file in "$OPENCODE_AGENT_DIR"/*.md; do
                if [[ -f "$agent_file" ]]; then
                    local agent_name
                    agent_name=$(basename "$agent_file" .md)
                    local mode
                    mode=$(grep -m1 "^mode:" "$agent_file" 2>/dev/null | cut -d: -f2 | tr -d ' ' || echo "unknown")
                    echo "  - $agent_name ($mode)"
                fi
            done
        else
            print_warning "No agents found"
        fi
    else
        print_warning "Agent directory does not exist"
    fi
    
    echo ""
    
    if [[ -f "$OPENCODE_JSON" ]]; then
        print_success "opencode.json exists"
        local mcp_count
        mcp_count=$(grep -c '"type":' "$OPENCODE_JSON" 2>/dev/null || echo "0")
        echo "  - MCP servers configured: $mcp_count"
    else
        print_warning "opencode.json not found"
    fi
    
    return 0
}

clean_agents() {
    print_header
    print_warning "This will remove aidevops agents from $OPENCODE_AGENT_DIR"
    echo ""
    
    read -r -p "Continue? [y/N] " response
    if [[ ! "$response" =~ ^[Yy]$ ]]; then
        echo "Cancelled."
        return 0
    fi
    
    local removed=0
    for name in "${AGENT_NAMES[@]}"; do
        local agent_file="$OPENCODE_AGENT_DIR/$name.md"
        
        if [[ -f "$agent_file" ]]; then
            rm "$agent_file"
            print_success "Removed $name.md"
            removed=$((removed + 1))
        fi
    done
    
    echo ""
    print_info "Removed $removed agent(s)"
    return 0
}

install_agents() {
    print_header
    
    # Check prerequisites
    if ! check_prerequisites; then
        print_error "Prerequisites check failed"
        return 1
    fi
    
    # Create agent directory
    create_agent_directory
    
    # Generate agent files
    generate_agent_files
    
    # Generate opencode.json config
    generate_opencode_json_config
    
    echo ""
    print_success "OpenCode agents installed successfully!"
    echo ""
    print_info "Installed agents:"
    echo "  - aidevops (primary) - Full framework access"
    echo "  - hostinger, hetzner, wordpress, seo (service subagents)"
    echo "  - code-quality (with learning loop for framework improvement)"
    echo "  - browser-automation, git-platforms, dns-providers"
    echo "  - agent-review (meta-agent for continuous improvement)"
    echo ""
    print_info "Next steps:"
    echo "  1. Configure MCP servers in $OPENCODE_JSON"
    echo "  2. Set API credentials in ~/.config/aidevops/mcp-env.sh"
    echo "  3. Restart opencode to load new agents"
    echo ""
    print_info "Usage:"
    echo "  - Use Tab to switch between primary agents"
    echo "  - Use @agent-name to invoke subagents"
    echo "  - Use @agent-review at end of sessions to capture improvements"
    echo "  - Use @code-quality to fix issues AND improve framework guidance"
    
    return 0
}

show_help() {
    cat << 'HELP_EOF'
AI DevOps Framework - OpenCode Agent Setup

Usage: ./setup-opencode-agents.sh [command]

Commands:
  install   Install agents with full configurations
  status    Show current agent configuration
  clean     Remove aidevops agents (keeps other agents)
  help      Show this help message

The script creates specialized AI agents for:

  PRIMARY AGENT:
    aidevops        Full framework access with Context7 docs

  SERVICE SUBAGENTS:
    hostinger       Hostinger hosting operations
    hetzner         Hetzner Cloud infrastructure (multi-account)
    wordpress       WordPress/MainWP + LocalWP MCP
    seo             Google Search Console + Ahrefs
    browser-automation  Chrome DevTools + Playwright
    git-platforms   GitHub/GitLab/Gitea CLIs
    dns-providers   Cloudflare, Namecheap, Route 53
    crawl4ai-usage  Web crawling and extraction

  META AGENTS:
    code-quality    Quality scanning + learning loop + PR creation
    agent-review    Session analysis + framework improvement + PR creation

FEATURES:
  - Context7 enabled for development-focused agents
  - Learning loops: code-quality and agent-review can submit PRs
  - Restricted bash permissions for PR-creating agents
  - Full MCP tool mappings per agent

Agents are installed to: ~/.config/opencode/agent/

For more information:
  https://github.com/marcusquinn/aidevops
  https://opencode.ai/docs/agents

HELP_EOF
    return 0
}

main() {
    local command="${1:-help}"
    
    case "$command" in
        install)
            install_agents
            ;;
        status)
            show_status
            ;;
        clean)
            clean_agents
            ;;
        help|--help|-h)
            show_help
            ;;
        *)
            print_error "Unknown command: $command"
            show_help
            return 1
            ;;
    esac
    
    return 0
}

main "$@"
