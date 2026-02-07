---
description: AI DevOps framework architecture context
mode: subagent
tools:
  read: true
  write: false
  edit: false
  bash: false
  glob: true
  grep: true
  webfetch: false
---

# AI DevOps Framework Context

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Services**: 25+ integrated (hosting, DNS, Git, code quality, email, etc.)
- **Pattern**: `./.agents/scripts/[service]-helper.sh [command] [account] [target] [options]`
- **Config**: `configs/[service]-config.json.txt` (template) → `configs/[service]-config.json` (gitignored)

**Categories**:
- Infrastructure (4): Hostinger, Hetzner, Closte, Cloudron
- Deployment (1): Coolify
- Git (4): GitHub, GitLab, Gitea, Local
- DNS (5): Spaceship, 101domains, Cloudflare, Namecheap, Route53
- Code Quality (4): CodeRabbit, CodeFactor, Codacy, SonarCloud
- Security (1): Vaultwarden
- Email (1): Amazon SES

**MCP Ports**: 3001 (LocalWP), 3002 (Vaultwarden), 3003+ (code audit, git platforms)

**Extension**: Follow standard patterns in `.agents/aidevops/extension.md`

**Design Patterns**: aidevops implements industry-standard agent design patterns (see below)
<!-- AI-CONTEXT-END -->

This file provides comprehensive context for AI assistants to understand, manage, and extend the AI DevOps Framework.

## Preferred Tool

**[Claude Code](https://Claude.ai/)** is the recommended and primary-tested AI coding agent for aidevops. All features, agents, workflows, and MCP integrations are designed and tested for Claude Code first. Other AI assistants (OpenCode, Cursor, Zed, etc.) are supported as a courtesy for users evaluating aidevops capabilities, but may not receive the same level of testing or integration depth.

Key integrations:
- **Agents**: Generated via `generate-opencode-agents.sh` with per-agent MCP tool filtering
- **Commands**: 41 slash commands deployed to `~/.config/opencode/commands/`
- **Plugins**: Compaction plugin at `.agents/plugins/opencode-aidevops/`
- **Prompts**: Custom system prompt at `.agents/prompts/build.txt`

## Agent Architecture

**Build+** is the unified coding agent for planning and implementation. It consolidates the former Plan+ and AI-DevOps agents:

- **Intent detection**: Automatically detects deliberation vs execution mode
- **Planning workflow**: Parallel explore agents, investigation phases, synthesis
- **Execution workflow**: Pre-edit git check, quality gates, autonomous iteration
- **Specialist subagents**: `@aidevops` for framework ops, `@plan-plus` for planning-only mode

## Agent Design Patterns

aidevops implements proven agent design patterns identified by Lance Martin (LangChain) and validated across successful agents like Claude Code, Manus, and Cursor. These patterns optimize for context efficiency and long-running autonomous operation.

### Pattern Alignment

| Pattern | Description | aidevops Implementation |
|---------|-------------|------------------------|
| **Give Agents a Computer** | Filesystem + shell access for persistent context | `~/.aidevops/.agent-workspace/`, helper scripts in `scripts/`, bash tools |
| **Multi-Layer Action Space** | Few tools, push actions to computer | Per-agent MCP filtering in `generate-opencode-agents.sh`, ~12-20 tools per agent |
| **Progressive Disclosure** | Load context on-demand, not upfront | Subagent tables in AGENTS.md, read-on-demand pattern, YAML frontmatter |
| **Offload Context** | Write intermediate results to filesystem | `.agent-workspace/work/[project]/` for persistent files, session trajectories |
| **Cache Context** | Prompt caching for cost efficiency | Stable instruction prefixes, avoid reordering between calls |
| **Isolate Context** | Sub-agents with separate context windows | Subagent markdown files with specific tool permissions |
| **Ralph Loop** | Iterative agent execution until task complete | `workflows/ralph-loop.md`, `ralph-loop-helper.sh`, `full-loop-helper.sh` |
| **Evolve Context** | Learn from sessions, update memories | `/remember`, `/recall` with SQLite FTS5, `memory-helper.sh` |

### Key Implementation Details

**Multi-Layer Action Space** (`opencode.json` tools section):

```python
# Tools disabled globally, enabled per-agent
GLOBAL_TOOLS = {"gsc_*": False, "outscraper_*": False, "osgrep_*": True, ...}
AGENT_TOOLS = {
    "Build+": {"write": True, "context7_*": True, "bash": True, "playwriter_*": True, ...},
    "SEO": {"gsc_*": True, "google-analytics-mcp_*": True, ...},
}
```

**Progressive Disclosure** (AGENTS.md structure):

```markdown
## Subagent Folders
| Folder | Purpose | Key Subagents |
|--------|---------|---------------|
| `tools/browser/` | Browser automation | stagehand, playwright, crawl4ai |
```

Agents read full subagent content only when tasks require domain expertise.

**Ralph Loop** (iterative development):

```text
Task -> Implement -> Check -> Fix Issues -> Re-check -> ... -> Complete
         ^                      |
         +----------------------+ (loop until done)
```

**Memory System** (continual learning):

```bash
# Store learnings
/remember "Fixed CORS with nginx proxy_set_header"

# Recall across sessions
/recall "cors nginx"
```

### MCP Lifecycle Pattern

Decision framework for when to use an MCP server vs a curl-based subagent:

| Factor | Use MCP | Use curl subagent |
|--------|---------|-------------------|
| Tool count | 25+ tools (outscraper) | 5-10 endpoints |
| Auth complexity | OAuth2 token exchange (GSC) | Simple Bearer/Basic/API key |
| Session frequency | Used most sessions | Used occasionally |
| Context cost | Justified by frequency | Wasteful if rarely invoked |
| Statefulness | Needs persistent connection | Stateless REST calls |

**Three-tier MCP strategy**:

1. **Globally enabled** (always loaded, ~2K tokens each): osgrep, augment-context-engine
2. **Enabled, tools disabled** (zero context until agent invokes): claude-code-mcp, gsc, outscraper, google-analytics-mcp, quickfile, amazon-order-history, context7, repomix, playwriter, chrome-devtools, etc.
3. **Replaced by curl subagent** (removed entirely): hetzner, serper, dataforseo, ahrefs, hostinger

**Pattern for tier 2** (in `opencode.json`):

```json
"mcp": { "service": { "enabled": true, ... } },
"tools": { "service_*": false },
"agent": { "AgentName": { "tools": { "service_*": true } } }
```

The MCP process runs but tools are hidden from all agents except those that explicitly enable them. Zero context overhead for agents that don't need the capability.

**When to migrate MCP → curl subagent**:
- API is simple REST with Bearer/Basic auth
- Fewer than ~10 endpoints needed
- No complex state management
- Subagent can document all patterns in a single markdown file
- Saves ~2K context tokens per session permanently

### References

- [Lance Martin's "Effective Agent Design" (Jan 2025)](https://x.com/RLanceMartin/status/2009683038272401719)
- [Anthropic's Claude Code architecture](https://www.anthropic.com/research/claude-code)
- [Manus agent design](https://manus.im/)
- [CodeAct paper on code execution](https://arxiv.org/abs/2402.01030)

## 🎯 **Framework Overview**

### **Complete DevOps Ecosystem (25+ Services)**

The AI DevOps Framework provides unified management across:

**🏗️ Infrastructure & Hosting (4 services):**

- Hostinger (shared hosting), Hetzner Cloud (VPS/cloud), Closte (VPS), Cloudron (app platform)

**🚀 Deployment & Orchestration (1 service):**

- Coolify (self-hosted PaaS)

**🎯 Content Management (1 service):**

- MainWP (WordPress management)

**🔐 Security & Secrets (1 service):**

- Vaultwarden (password/secrets management)

**🔍 Code Quality & Auditing (4 services):**

- CodeRabbit (AI reviews), CodeFactor (quality), Codacy (quality & security), SonarCloud (professional)

**📚 Version Control & Git Platforms (4 services):**

- GitHub, GitLab, Gitea, Local Git

**📧 Email Services (1 service):**

- Amazon SES (email delivery)

**🌐 Domain & DNS (5 services):**

- Spaceship (with purchasing), 101domains, Cloudflare DNS, Namecheap DNS, Route 53

**🏠 Development & Local (4 services):**

- Localhost (.local domains), LocalWP (WordPress dev), Context7 MCP (docs), MCP Servers

**🧙‍♂️ Setup & Configuration (1 service):**

- Intelligent Setup Wizard

## 🛠️ **Framework Architecture**

### **Unified Command Patterns**

All services follow consistent patterns for AI assistant efficiency:

```bash
# Standard pattern: ./.agents/scripts/[service]-helper.sh [command] [account/instance] [target] [options]

# List/Status Commands
./.agents/scripts/[service]-helper.sh [accounts|instances|servers|sites]

# Management Commands
./.agents/scripts/[service]-helper.sh [action] [account/instance] [target] [options]

# Monitoring Commands
./.agents/scripts/[service]-helper.sh [monitor|audit|status] [account/instance]

# Help Commands
./.agents/scripts/[service]-helper.sh help
```

### **Configuration Structure**

```bash
# Configuration pattern:
configs/[service]-config.json.txt  # Template (committed)
configs/[service]-config.json      # Working config (gitignored)

# All configs follow consistent JSON structure:
{
  "accounts": {
    "account-name": {
      "api_token": "TOKEN_HERE",
      "base_url": "https://api.service.com",
      "description": "Account description"
    }
  },
  "default_settings": { ... },
  "mcp_servers": { ... }
}
```

### **Documentation Structure**

```bash
.agents/AGENTS.md                      # AI assistant framework context
.agents/[SERVICE].md                   # Complete service guide
.agents/recommendations.md             # Provider selection guide
```

## 🚀 **Framework Usage Examples**

### **Complete Project Setup Workflow**

```bash
# 1. Setup wizard for intelligent guidance
./.agents/scripts/setup-wizard-helper.sh full-setup

# 2. Domain research and purchase
./.agents/scripts/spaceship-helper.sh bulk-check personal myproject.com myproject.dev
./.agents/scripts/spaceship-helper.sh purchase personal myproject.com 1 true

# 3. Git repository creation
./.agents/scripts/git-platforms-helper.sh github-create personal myproject "Description" false
./.agents/scripts/git-platforms-helper.sh local-init ~/projects myproject

# 4. Infrastructure provisioning
./.agents/scripts/hetzner-helper.sh create-server production myproject

# 5. DNS configuration
./.agents/scripts/dns-helper.sh add cloudflare personal myproject.com @ A 192.168.1.100

# 6. Application deployment
./.agents/scripts/coolify-helper.sh deploy production myproject

# 7. Security setup
./.agents/scripts/vaultwarden-helper.sh create production "MyProject Creds" user pass

# 8. Code quality setup
./.agents/scripts/code-audit-helper.sh audit myproject

# 9. Monitoring setup
./.agents/scripts/ses-helper.sh monitor production
```

### **Multi-Service Operations**

```bash
# Comprehensive infrastructure audit
for service in hostinger hetzner coolify mainwp; do
    ./.agents/scripts/${service}-helper.sh monitor production
done

# Bulk domain management
./.agents/scripts/spaceship-helper.sh bulk-check personal \
  project1.com project2.com project3.com

# Cross-platform Git management
./.agents/scripts/git-platforms-helper.sh audit github personal
./.agents/scripts/git-platforms-helper.sh audit gitlab personal
```

## 🔧 **MCP Server Ecosystem**

### **Available MCP Servers**

```bash
# Complete MCP server stack for AI assistants:
./.agents/scripts/localhost-helper.sh start-mcp          # Port 3001 - LocalWP access
./.agents/scripts/vaultwarden-helper.sh start-mcp production 3002  # Secure credentials
./.agents/scripts/code-audit-helper.sh start-mcp coderabbit 3003   # Code analysis
./.agents/scripts/code-audit-helper.sh start-mcp codacy 3004       # Quality metrics
./.agents/scripts/code-audit-helper.sh start-mcp sonarcloud 3005   # Security analysis
./.agents/scripts/git-platforms-helper.sh start-mcp github 3006    # Git management
./.agents/scripts/git-platforms-helper.sh start-mcp gitlab 3007    # GitLab access
./.agents/scripts/git-platforms-helper.sh start-mcp gitea 3008     # Gitea access
```

### **MCP Integration Benefits**

- **Real-time data access** from all services
- **Contextual AI responses** based on current infrastructure state
- **Secure credential retrieval** through Vaultwarden MCP
- **Live code analysis** through code auditing MCPs
- **Dynamic documentation** through Context7 MCP

## 📊 **Framework Extension Guide**

### **Adding New Providers/Services**

#### **1. Create Helper Script**

```bash
# File: .agents/scripts/[service-name]-helper.sh
#!/bin/bash

# [Service Name] Helper Script
# [Brief description of service]

# Standard header with colors and functions
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

print_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
print_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
print_warning() { echo -e "${YELLOW}[WARNING]${NC} $1"; }
print_error() { echo -e "${RED}[ERROR]${NC} $1"; }

CONFIG_FILE="../configs/[service-name]-config.json"

# Standard functions:
# - check_dependencies()
# - load_config()
# - get_account_config()
# - api_request()
# - list_accounts()
# - [service-specific functions]
# - show_help()
# - main()
```

#### **2. Create Configuration Template**

```bash
# File: configs/[service-name]-config.json.txt
{
  "accounts": {
    "personal": {
      "api_token": "YOUR_[SERVICE]_API_TOKEN_HERE",
      "base_url": "https://api.[service].com",
      "description": "Personal [service] account"
    }
  },
  "default_settings": {
    "timeout": 30,
    "rate_limit": 60
  },
  "mcp_servers": {
    "[service]": {
      "enabled": true,
      "port": 30XX,
      "host": "localhost"
    }
  }
}
```

#### **3. Create Comprehensive Documentation**

```bash
# File: .agents/[SERVICE-NAME].md
# [Service Name] Guide

## 🏢 **Provider Overview**
### **[Service] Characteristics:**
- **Service Type**: [Description]
- **Strengths**: [Key benefits]
- **API Support**: [API capabilities]
- **MCP Integration**: [MCP availability]
- **Use Case**: [Primary use cases]

## 🔧 **Configuration**
[Setup instructions]

## 🚀 **Usage Examples**
[Command examples]

## 🛡️ **Security Best Practices**
[Security guidelines]

## 📊 **MCP Integration**
[MCP setup and capabilities]

## 🔍 **Troubleshooting**
[Common issues and solutions]

## 📚 **Best Practices**
[Service-specific best practices]

## 🎯 **AI Assistant Integration**
[AI automation capabilities]
```

#### **4. Update Framework Files**

```bash
# Update .gitignore
echo "configs/[service-name]-config.json" >> .gitignore

# Update README.md
# Add service to provider list and file structure

# Update RECOMMENDATIONS-OPINIONATED.md
# Add service to appropriate category

# Update setup-wizard-helper.sh
# Add service to recommendations logic
```

### **Framework Standards & Conventions**

#### **Naming Conventions**

```bash
# Helper scripts: [service-name]-helper.sh (lowercase, hyphenated)
# Config files: [service-name]-config.json.txt (template)
# Config files: [service-name]-config.json (working, gitignored)
# Documentation: [SERVICE-NAME].md (uppercase, hyphenated)
# Functions: [action_description] (lowercase, underscored)
# Variables: [CONSTANT_NAME] (uppercase, underscored)
```

#### **Code Standards**

```bash
# All helper scripts must include:
1. Shebang: #!/bin/bash
2. Description comment block
3. Color definitions and print functions
4. CONFIG_FILE variable
5. check_dependencies() function
6. load_config() function
7. show_help() function
8. main() function with case statement
9. Consistent error handling
10. Proper exit codes
```

#### **Security Standards**

```bash
# All services must implement:
1. API token validation
2. Rate limiting awareness
3. Secure credential storage
4. Input validation
5. Error message sanitization
6. Audit logging capabilities
7. Confirmation prompts for destructive operations
8. Encrypted data handling where applicable
```

#### **Documentation Standards**

```bash
# All documentation must include:
1. Provider overview with characteristics
2. Configuration setup instructions
3. Usage examples with real commands
4. Security best practices
5. MCP integration details
6. Troubleshooting section
7. Best practices section
8. AI assistant integration capabilities
```

## 📋 **AI Assistant Operational Guidelines**

### **Framework Usage Principles**

1. **Consistency First**: Always use framework patterns and conventions
2. **Security Awareness**: Never expose credentials or sensitive data
3. **Confirmation Required**: Confirm destructive operations and purchases
4. **Context Utilization**: Use Context7 MCP for latest service documentation
5. **Error Handling**: Implement robust error handling and user feedback
6. **Audit Trails**: Log important operations for accountability

### **Extension Best Practices**

1. **Research First**: Check if service already has API and MCP support
2. **Follow Patterns**: Use existing helpers as templates for consistency
3. **Security Focus**: Implement security measures from the start
4. **Documentation**: Create comprehensive documentation alongside code
5. **Testing**: Test all functions before integration
6. **Integration**: Update all framework files for complete integration

### **Maintenance Guidelines**

1. **Regular Updates**: Keep service APIs and MCPs current
2. **Security Audits**: Regular security reviews of all integrations
3. **Documentation Sync**: Keep documentation synchronized with code
4. **Dependency Management**: Monitor and update dependencies
5. **Performance Optimization**: Optimize for AI assistant efficiency

### **Quality Assurance**

1. **Code Review**: All additions should follow framework standards
2. **Security Review**: Security implications of all new integrations
3. **Documentation Review**: Ensure documentation completeness
4. **Integration Testing**: Test integration with existing services
5. **User Experience**: Optimize for AI assistant and user experience

## 🌟 **Framework Evolution Strategy**

### **Continuous Improvement**

- **Service Monitoring**: Monitor for new services and APIs
- **Technology Adoption**: Adopt new technologies that enhance capabilities
- **User Feedback**: Incorporate user feedback for improvements
- **AI Advancement**: Adapt to new AI assistant capabilities
- **Security Evolution**: Stay current with security best practices

### **Scalability Considerations**

- **Modular Design**: Maintain modular architecture for easy extension
- **Performance**: Optimize for performance at scale
- **Resource Management**: Efficient resource utilization
- **Error Recovery**: Robust error recovery mechanisms
- **Load Distribution**: Distribute load across services appropriately

---

**This comprehensive context enables AI assistants to not only use the framework effectively but also extend and maintain it following established patterns, security practices, and quality standards. The framework is designed to evolve continuously while maintaining consistency, security, and usability.** 🚀🤖✨
