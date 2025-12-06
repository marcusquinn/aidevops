# AI DevOps Framework

**[aidevops.sh](https://aidevops.sh)** — Unleash your AI assistant's true potential with specialist DevOps agents, designed to manage all your infrastructure and services with security and reliability guidance on every decision.

*"List all my servers and websites, and check each for theme and plugin update needs, SEO and page loading performance scores, and give me a list of recommended priorities"* - **One conversation, complete infrastructure management.**

## **Why This Framework?**

**Beyond Single-Repo Limitations:** VS Code and Web UIs work on one repo at a time. CLI AI assistants can manage your entire infrastructure when given the right tools, access, and guidance.

**DevOps Superpowers for AI:**

- **Multi-Service Management**: 30+ APIs (hosting, Git, security, monitoring, deployment)
- **Real-Time Operations**: SSH, domain management, database operations
- **Cross-Service Intelligence**: Connect patterns across your entire ecosystem
- **Unlimited Scope**: Full access to your development infrastructure for bug fixes and feature development

---

<!-- Build & Quality Status -->
[![GitHub Actions](https://github.com/marcusquinn/aidevops/workflows/Code%20Quality%20Analysis/badge.svg)](https://github.com/marcusquinn/aidevops/actions)
[![Quality Gate Status](https://sonarcloud.io/api/project_badges/measure?project=marcusquinn_aidevops&metric=alert_status)](https://sonarcloud.io/summary/new_code?id=marcusquinn_aidevops)
[![CodeFactor](https://www.codefactor.io/repository/github/marcusquinn/aidevops/badge)](https://www.codefactor.io/repository/github/marcusquinn/aidevops)
[![Maintainability](https://qlty.sh/gh/marcusquinn/projects/aidevops/maintainability.svg)](https://qlty.sh/gh/marcusquinn/projects/aidevops)
[![Codacy Badge](https://app.codacy.com/project/badge/Grade/2b1adbd66c454dae92234341e801b984)](https://app.codacy.com/gh/marcusquinn/aidevops/dashboard?utm_source=gh&utm_medium=referral&utm_content=&utm_campaign=Badge_grade)
[![CodeRabbit](https://img.shields.io/badge/CodeRabbit-AI%20Reviews-FF570A?logo=coderabbit&logoColor=white)](https://coderabbit.ai)

<!-- License & Legal -->
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)
[![Copyright](https://img.shields.io/badge/Copyright-Marcus%20Quinn%202025-blue.svg)](https://github.com/marcusquinn)

<!-- GitHub Stats -->
[![GitHub stars](https://img.shields.io/github/stars/marcusquinn/aidevops.svg?style=social)](https://github.com/marcusquinn/aidevops/stargazers)
[![GitHub forks](https://img.shields.io/github/forks/marcusquinn/aidevops.svg?style=social)](https://github.com/marcusquinn/aidevops/network)
[![GitHub watchers](https://img.shields.io/github/watchers/marcusquinn/aidevops.svg?style=social)](https://github.com/marcusquinn/aidevops/watchers)

<!-- Release & Version Info -->
[![GitHub release (latest by date)](https://img.shields.io/github/v/release/marcusquinn/aidevops)](https://github.com/marcusquinn/aidevops/releases)
[![GitHub Release Date](https://img.shields.io/github/release-date/marcusquinn/aidevops)](https://github.com/marcusquinn/aidevops/releases)
[![GitHub commits since latest release](https://img.shields.io/github/commits-since/marcusquinn/aidevops/latest)](https://github.com/marcusquinn/aidevops/commits/main)

<!-- Repository Stats -->
[![Version](https://img.shields.io/badge/Version-2.19.4-blue)](https://github.com/marcusquinn/aidevops/releases)
[![GitHub repo size](https://img.shields.io/github/repo-size/marcusquinn/aidevops?style=flat&color=blue)](https://github.com/marcusquinn/aidevops)
[![Lines of code](https://img.shields.io/badge/Lines%20of%20Code-18%2C000%2B-brightgreen)](https://github.com/marcusquinn/aidevops)
[![GitHub language count](https://img.shields.io/github/languages/count/marcusquinn/aidevops)](https://github.com/marcusquinn/aidevops)
[![GitHub top language](https://img.shields.io/github/languages/top/marcusquinn/aidevops)](https://github.com/marcusquinn/aidevops)

<!-- Community & Issues -->
[![GitHub issues](https://img.shields.io/github/issues/marcusquinn/aidevops)](https://github.com/marcusquinn/aidevops/issues)
[![GitHub closed issues](https://img.shields.io/github/issues-closed/marcusquinn/aidevops)](https://github.com/marcusquinn/aidevops/issues?q=is%3Aissue+is%3Aclosed)
[![GitHub pull requests](https://img.shields.io/github/issues-pr/marcusquinn/aidevops)](https://github.com/marcusquinn/aidevops/pulls)
[![GitHub contributors](https://img.shields.io/github/contributors/marcusquinn/aidevops)](https://github.com/marcusquinn/aidevops/graphs/contributors)

<!-- Framework Specific -->
[![Services Supported](https://img.shields.io/badge/Services%20Supported-30+-brightgreen.svg)](#comprehensive-service-coverage)
[![AGENTS.md](https://img.shields.io/badge/AGENTS.md-Compliant-blue.svg)](https://agents.md/)
[![AI Optimized](https://img.shields.io/badge/AI%20Optimized-Yes-brightgreen.svg)](https://github.com/marcusquinn/aidevops/blob/main/AGENTS.md)
[![MCP Servers](https://img.shields.io/badge/MCP%20Servers-18-orange.svg)](#mcp-integrations)
[![API Integrations](https://img.shields.io/badge/API%20Integrations-30+-blue.svg)](#comprehensive-service-coverage)

## **Enterprise-Grade Quality & Security**

**Comprehensive DevOps framework with tried & tested services integrations, popular and trusted MCP servers, and enterprise-grade infrastructure quality assurance code monitoring and recommendations.**

## **Security Notice**

**This framework provides agentic AI assistants with powerful infrastructure access. Use responsibly.**

**Capabilities:** Execute commands, access credentials, modify infrastructure, interact with APIs
**Your responsibility:** Use trusted AI providers, rotate credentials regularly, monitor activity

## **Quick Start**

**One-liner install** (fresh install or update):

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/marcusquinn/aidevops/main/setup.sh)
```

Or manually:

```bash
git clone https://github.com/marcusquinn/aidevops.git ~/Git/aidevops
~/Git/aidevops/setup.sh
```

**That's it!** The setup script will:
- Clone/update the repo to `~/Git/aidevops`
- Deploy agents to `~/.aidevops/agents/`
- Install the `aidevops` CLI command
- Configure your AI assistants automatically
- Guide you through recommended tools (Tabby, Zed, Git CLIs)

**After installation, use the CLI:**

```bash
aidevops status     # Check what's installed
aidevops update     # Update to latest version
aidevops uninstall  # Remove aidevops
```

**Your AI assistant now has agentic access to 30+ service integrations.**

**Supported AI Assistants:** (OpenCode & Zed are our daily drivers and preferred tools, so will have the most continual testing. All 18 assistants below have MCP configuration support.)

**Preferred:**

- **[Tabby](https://tabby.sh/)** - Modern terminal with colour-coded Profiles. Use different profile colours per project/repo to visually distinguish which codebase you're working in.
- **[OpenCode](https://opencode.ai/)** - Primary choice. Powerful agentic TUI/CLI with native MCP support, Tab-based agent switching, and excellent DX.
- **[Zed](https://zed.dev/)** - High-performance editor with AI (Preferred, with the OpenCode Agent Extension)

**IDE-Based:**

- **[Cursor](https://cursor.sh/)** - AI-first IDE with MCP support
- **[Windsurf](https://codeium.com/windsurf)** - Codeium's AI IDE
- **[Continue.dev](https://continue.dev/)** - VS Code/JetBrains extension
- **[Cody](https://sourcegraph.com/cody)** - Sourcegraph's AI assistant

**Claude Family:**

- **[Claude Code](https://claude.ai/)** - CLI version with `claude mcp add`
- **[Claude Desktop](https://claude.ai/)** - GUI with MCP config

**Enterprise & Professional:**

- **[Factory AI Droid](https://www.factory.ai/)** - Enterprise-grade agentic AI
- **[Augment Code](https://www.augmentcode.com/)** - Deep codebase indexing
- **[GitHub Copilot](https://github.com/features/copilot)** - Agent mode for MCP

**Specialized:**

- **[Kilo Code](https://kilocode.ai/)** - VS Code extension
- **[Kiro](https://kiro.dev/)** - AWS's AI assistant
- **[AntiGravity](https://antigravity.dev/)** - AI coding tool
- **[Gemini CLI](https://ai.google.dev/)** - Google's CLI

**Terminal & CLI:**

- **[Aider](https://aider.chat/)** - CLI pair programmer with native MCP
- **[Warp AI](https://www.warp.dev/)** - Terminal with AI (no native MCP, use OpenCode/Claude in Warp)
- **[Qwen](https://qwen.ai/)** - Alibaba's CLI (MCP support experimental)

## **Core Capabilities**

**AI-First Infrastructure Management:**

- SSH server access, remote command execution, API integrations
- DNS management, application deployment, email monitoring
- Git platform management, domain purchasing, setup automation
- [WordPress](https://wordpress.org/) management, credential security, code auditing

**Unified Interface:**

- Standardized commands across all providers
- Automated SSH configuration and multi-account support for all services
- Security-first design with comprehensive logging, code quality reviews, and continual feedback-based improvement

**Quality Control & Monitoring:**

- **Multi-Platform Analysis**: SonarCloud, CodeFactor, Codacy, CodeRabbit, Qlty, Gemini Code Assist, Snyk
- **Performance Auditing**: PageSpeed Insights and Lighthouse integration
- **Uptime Monitoring**: Updown.io integration for website and SSL monitoring

## **Requirements**

```bash
# Install dependencies (auto-detected by setup.sh)
brew install sshpass jq curl mkcert dnsmasq  # macOS
sudo apt-get install sshpass jq curl dnsmasq  # Ubuntu/Debian

# Generate SSH key
ssh-keygen -t ed25519 -C "your-email@domain.com"
```

## **Comprehensive Service Coverage**

### **Infrastructure & Hosting**

- **[Hostinger](https://www.hostinger.com/)**: Shared hosting, domains, email
- **[Hetzner Cloud](https://www.hetzner.com/cloud)**: VPS servers, networking, load balancers
- **[Closte](https://closte.com/)**: Managed hosting, application deployment
- **[Coolify](https://coolify.io/)** *Enhanced with CLI*: Self-hosted PaaS with CLI integration
- **[Cloudron](https://www.cloudron.io/)**: Server and app management platform
- **[Vercel](https://vercel.com/)** *Enhanced with CLI*: Modern web deployment platform with CLI integration
- **[AWS](https://aws.amazon.com/)**: Cloud infrastructure support via standard protocols
- **[DigitalOcean](https://www.digitalocean.com/)**: Cloud infrastructure support via standard protocols

### **Domain & DNS**

- **[Cloudflare](https://www.cloudflare.com/)**: DNS, CDN, security services
- **[Spaceship](https://www.spaceship.com/)**: Domain registration and management
- **[101domains](https://www.101domain.com/)**: Domain purchasing and DNS
- **[AWS Route 53](https://aws.amazon.com/route53/)**: AWS DNS management
- **[Namecheap](https://www.namecheap.com/)**: Domain and DNS services

### **Development & Git Platforms with CLI Integration**

- **[GitHub](https://github.com/)** *Enhanced with CLI*: Repository management, actions, API, GitHub CLI (gh) integration
- **[GitLab](https://gitlab.com/)** *Enhanced with CLI*: Self-hosted and cloud Git platform with GitLab CLI (glab) integration  
- **[Gitea](https://gitea.io/)** *Enhanced with CLI*: Lightweight Git service with Gitea CLI (tea) integration
- **[Agno](https://agno.com/)**: Local AI agent operating system for DevOps automation
- **[Pandoc](https://pandoc.org/)**: Document conversion to markdown for AI processing

### **WordPress Development**

- **[LocalWP](https://localwp.com)**: WordPress development environment with MCP database access
- **[MainWP](https://mainwp.com/)**: WordPress site management dashboard

**Git CLI Enhancement Features:**

- **.agent/scripts/github-cli-helper.sh**: Advanced GitHub repository, issue, PR, and branch management
- **.agent/scripts/gitlab-cli-helper.sh**: Complete GitLab project, issue, MR, and branch management
- **.agent/scripts/gitea-cli-helper.sh**: Full Gitea repository, issue, PR, and branch management

### **Security & Code Quality**

- **[Vaultwarden](https://github.com/dani-garcia/vaultwarden)**: Password and secrets management
- **[SonarCloud](https://sonarcloud.io/)**: Security and quality analysis (A-grade ratings)
- **[CodeFactor](https://www.codefactor.io/)**: Code quality metrics (A+ score)
- **[Codacy](https://www.codacy.com/)**: Multi-tool analysis (0 findings)
- **[CodeRabbit](https://coderabbit.ai/)**: AI-powered code reviews
- **[Snyk](https://snyk.io/)**: Security vulnerability scanning
- **[Qlty](https://qlty.sh/)**: Universal code quality platform (70+ linters, auto-fixes)
- **[Gemini Code Assist](https://cloud.google.com/gemini/docs/codeassist/overview)**: Google's AI-powered code completion and review

### **AI Prompt Optimization**

- **[Augment Context Engine](https://docs.augmentcode.com/context-services/mcp/overview)**: Semantic codebase retrieval with deep code understanding
- **[Repomix](https://repomix.com/)**: Pack codebases into AI-friendly context (80% token reduction with compress mode)
- **[DSPy](https://dspy.ai/)**: Framework for programming with language models
- **[DSPyGround](https://dspyground.com/)**: Interactive playground for prompt optimization
- **[TOON Format](https://github.com/marcusquinn/aidevops/blob/main/.agent/toon-format.md)**: Token-Oriented Object Notation - 20-60% token reduction for LLM prompts

### **Performance & Monitoring**

- **[PageSpeed Insights](https://pagespeed.web.dev/)**: Website performance auditing
- **[Lighthouse](https://developer.chrome.com/docs/lighthouse/)**: Comprehensive web app analysis
- **[Updown.io](https://updown.io/)**: Website uptime and SSL monitoring

### **AI & Documentation**

- **[Context7](https://context7.io/)**: Real-time documentation access for libraries and frameworks

## **MCP Integrations**

**Model Context Protocol servers for real-time AI assistant integration.** The framework helps configure these MCPs for **18 AI assistants** including OpenCode (preferred), Cursor, Claude Code/Desktop, Windsurf, Continue.dev, Cody, Zed, GitHub Copilot, Kilo Code, Kiro, AntiGravity, Gemini CLI, Droid, Warp AI, Aider, and Qwen.

### **All Supported MCPs**

| MCP | Purpose | API Key Required |
|-----|---------|------------------|
| [Ahrefs](https://ahrefs.com/api) | SEO analysis & backlinks | Yes |
| [Augment Context Engine](https://docs.augmentcode.com/context-services/mcp/overview) | Semantic codebase retrieval | Yes (Augment account) |
| [Chrome DevTools](https://chromedevtools.github.io/devtools-protocol/) | Browser debugging & automation | No |
| [Cloudflare Browser](https://developers.cloudflare.com/browser-rendering/) | Server-side rendering | Yes (Cloudflare) |
| [Context7](https://context7.com/) | Library documentation lookup | No |
| [Crawl4AI](https://github.com/unclecode/crawl4ai) | Web crawling & scraping | No |
| [Google Search Console](https://developers.google.com/webmaster-tools) | Search performance data | Yes (Google API) |
| [Grep by Vercel](https://grep.app/) | GitHub code search | No |
| [LocalWP](https://localwp.com/) | WordPress database access | No (local) |
| [Next.js DevTools](https://nextjs.org/docs) | React/Next.js assistance | No |
| [Outscraper](https://outscraper.com/) | Google Maps & business data extraction | Yes |
| [PageSpeed Insights](https://developers.google.com/speed/docs/insights/v5/get-started) | Performance auditing | Yes (Google API) |
| [Perplexity](https://docs.perplexity.ai/) | AI-powered research | Yes |
| [Playwright](https://playwright.dev/) | Cross-browser testing | No |
| [Repomix](https://github.com/yamadashy/repomix) | Codebase packing for AI context | No |
| [Snyk](https://snyk.io/) | Security vulnerability scanning | Yes |
| [Stagehand (JS)](https://github.com/browserbase/stagehand) | AI browser automation | Optional (Browserbase) |
| [Stagehand (Python)](https://github.com/anthropics/stagehand-python) | AI browser automation | Optional (Browserbase) |

### **By Category**

**Context & Codebase:**

- [Augment Context Engine](https://docs.augmentcode.com/context-services/mcp/overview) - Semantic codebase retrieval with deep code understanding
- [osgrep](https://github.com/Ryandonofrio3/osgrep) - Local semantic search (100% private, no cloud) ⚠️ *experimental*
- [Context7](https://context7.com/) - Real-time documentation access for thousands of libraries
- [Repomix](https://github.com/yamadashy/repomix) - Pack codebases into AI-friendly context

**Browser Automation:**

- [Stagehand (JavaScript)](https://github.com/browserbase/stagehand) - AI-powered browser automation with natural language
- [Stagehand (Python)](https://github.com/anthropics/stagehand-python) - Python version with Pydantic validation
- [Chrome DevTools](https://chromedevtools.github.io/devtools-protocol/) - Browser automation, performance analysis, debugging
- [Playwright](https://playwright.dev/) - Cross-browser testing and automation
- [Crawl4AI](https://github.com/unclecode/crawl4ai) - Async web crawler optimized for AI
- [Cloudflare Browser Rendering](https://developers.cloudflare.com/browser-rendering/) - Server-side web scraping

**SEO & Research:**

- [Ahrefs](https://ahrefs.com/api) - SEO analysis, backlink research, keyword data
- [Google Search Console](https://developers.google.com/webmaster-tools) - Search performance insights
- [Perplexity](https://docs.perplexity.ai/) - AI-powered web search and research
- [Grep by Vercel](https://grep.app/) - Search code snippets across GitHub repositories

**Data Extraction:**

- [Outscraper](https://outscraper.com/) - Google Maps, business data, reviews extraction

**Performance & Security:**

- [PageSpeed Insights](https://developers.google.com/speed/docs/insights/v5/get-started) - Website performance auditing
- [Snyk](https://snyk.io/) - Security vulnerability scanning

**WordPress & Development:**

- [LocalWP](https://localwp.com/) - Direct WordPress database access
- [Next.js DevTools](https://nextjs.org/docs) - React/Next.js development assistance

### **Quick Setup**

```bash
# Install all MCP integrations
bash .agent/scripts/setup-mcp-integrations.sh all

# Install specific integration
bash .agent/scripts/setup-mcp-integrations.sh stagehand          # JavaScript version
bash .agent/scripts/setup-mcp-integrations.sh stagehand-python   # Python version
bash .agent/scripts/setup-mcp-integrations.sh stagehand-both     # Both versions
bash .agent/scripts/setup-mcp-integrations.sh chrome-devtools
```

## **Repomix - AI Context Generation**

[Repomix](https://repomix.com/) packages your codebase into AI-friendly formats for sharing with AI assistants. This framework includes optimized Repomix configuration for consistent context generation.

### Why Repomix?

| Use Case | Tool | When to Use |
|----------|------|-------------|
| **Interactive coding** | Augment Context Engine | Real-time semantic search during development |
| **Share with external AI** | Repomix | Self-contained snapshot for ChatGPT, Claude web, etc. |
| **Architecture review** | Repomix (compress) | 80% token reduction, structure only |
| **CI/CD integration** | GitHub Action | Automated context in releases |

### Quick Usage

```bash
# Pack current repo with configured defaults
npx repomix

# Compress mode (~80% smaller, structure only)
npx repomix --compress

# Or use the helper script
.agent/scripts/context-builder-helper.sh pack      # Full context
.agent/scripts/context-builder-helper.sh compress  # Compressed
```

### Configuration Files

| File | Purpose |
|------|---------|
| `repomix.config.json` | Default settings (style, includes, security) |
| `.repomixignore` | Additional exclusions beyond .gitignore |
| `repomix-instruction.md` | Custom AI instructions included in output |

### Key Design Decisions

- **No pre-generated files**: Outputs are generated on-demand to avoid staleness
- **Inherits .gitignore**: Security patterns automatically respected
- **Secretlint enabled**: Scans for exposed credentials before output
- **Symlinks excluded**: Avoids duplicating `.agent/` content

### MCP Integration

Repomix runs as an MCP server for direct AI assistant integration:

```json
{
  "repomix": {
    "type": "local",
    "command": ["npx", "-y", "repomix@latest", "--mcp"],
    "enabled": true
  }
}
```

See `.agent/tools/context/context-builder.md` for complete documentation.

## **Augment Context Engine - Semantic Codebase Search**

[Augment Context Engine](https://docs.augmentcode.com/context-services/mcp/overview) provides semantic codebase retrieval - understanding your code at a deeper level than simple text search. It's the recommended tool for real-time interactive coding sessions.

### Why Augment Context Engine?

| Feature | grep/glob | Augment Context Engine |
|---------|-----------|------------------------|
| Text matching | Exact patterns | Semantic understanding |
| Cross-file context | Manual | Automatic |
| Code relationships | None | Understands dependencies |
| Natural language | No | Yes |

Use it to:

- Find related code across your entire codebase
- Understand project architecture quickly
- Discover patterns and implementations
- Get context-aware code suggestions

### Quick Setup

```bash
# 1. Install Auggie CLI (requires Node.js 22+)
npm install -g @augmentcode/auggie@prerelease

# 2. Authenticate (opens browser)
auggie login

# 3. Verify installation
auggie token print
```

### MCP Integration

Add to your AI assistant's MCP configuration:

**OpenCode** (`~/.config/opencode/opencode.json`):

```json
{
  "mcp": {
    "augment-context-engine": {
      "type": "local",
      "command": ["auggie", "--mcp"],
      "enabled": true
    }
  }
}
```

**Claude Code**:

```bash
claude mcp add-json auggie-mcp --scope user '{"type":"stdio","command":"auggie","args":["--mcp"]}'
```

**Cursor**: Settings → Tools & MCP → New MCP Server:

```json
{
  "mcpServers": {
    "augment-context-engine": {
      "command": "bash",
      "args": ["-c", "auggie --mcp -m default -w \"${WORKSPACE_FOLDER_PATHS%%,*}\""]
    }
  }
}
```

### Verification

Test with this prompt:

```text
What is this project? Please use codebase retrieval tool to get the answer.
```

The AI should provide a semantic understanding of your project architecture.

### Repomix vs Augment Context Engine

| Use Case | Tool | When to Use |
|----------|------|-------------|
| **Interactive coding** | Augment Context Engine | Real-time semantic search during development |
| **Share with external AI** | Repomix | Self-contained snapshot for ChatGPT, Claude web, etc. |
| **Architecture review** | Repomix (compress) | 80% token reduction, structure only |
| **CI/CD integration** | Repomix GitHub Action | Automated context in releases |

See `.agent/tools/context/augment-context-engine.md` for complete documentation including configurations for Zed, GitHub Copilot, Kilo Code, Kiro, AntiGravity, Gemini CLI, and Factory.AI Droid.

### osgrep - Local Alternative (Experimental)

[osgrep](https://github.com/Ryandonofrio3/osgrep) provides 100% local semantic search with no cloud dependency:

```bash
npm install -g osgrep && osgrep setup
osgrep "where is authentication handled?"
```

| Feature | osgrep | Augment |
|---------|--------|---------|
| Privacy | 100% local | Cloud-based |
| Auth | None required | Account + login |
| Node.js | 18+ | 22+ |

⚠️ **Status**: Currently experiencing indexing issues (v0.4.x). See `.agent/tools/context/osgrep.md` for details and GitHub issues #58, #26 for progress.

## **AI Agents & Subagents**

**Agents are specialized AI personas with focused knowledge and tool access.** Instead of giving your AI assistant access to everything at once (which wastes context tokens), agents provide targeted capabilities for specific tasks.

Call them in your AI assistant conversation with a simple @mention

### **How Agents Work**

| Concept | Description |
|---------|-------------|
| **Main Agent** | Domain-focused assistant (e.g., WordPress, SEO, DevOps) |
| **Subagent** | Specialized assistant for specific services (invoked with @mention) |
| **MCP Tools** | Only loaded when relevant agent is invoked (saves tokens) |

### **Main Agents**

Ordered as they appear in OpenCode Tab selector and other AI assistants (14 total):

| Name | File | Purpose | MCPs Enabled |
|------|------|---------|--------------|
| Plan+ | `plan-plus.md` | Read-only planning with semantic codebase search | context7, augment, repomix |
| Build+ | `build-plus.md` | Enhanced Build with context tools | context7, augment, repomix |
| Build-Agent | `build-agent.md` | Design and improve AI agents | context7, augment, repomix |
| Build-MCP | `build-mcp.md` | Build MCP servers with TS+Bun+ElysiaJS | context7, augment, repomix |
| Accounting | `accounting.md` | Financial operations | quickfile, augment |
| AI-DevOps | `aidevops.md` | Framework operations, meta-agents, setup | context7, augment, repomix |
| Content | `content.md` | Content creation workflows | augment |
| Health | `health.md` | Health and wellness guidance | augment |
| Legal | `legal.md` | Legal compliance and documentation | augment |
| Marketing | `marketing.md` | Marketing strategy and automation | augment |
| Research | `research.md` | Research and analysis tasks | context7, augment |
| Sales | `sales.md` | Sales operations and CRM | augment |
| SEO | `seo.md` | SEO optimization, Search Console, keyword research | gsc, ahrefs, augment |
| WordPress | `wordpress.md` | WordPress ecosystem (dev, admin, MainWP, LocalWP) | localwp, context7, augment |

### **Example Subagents with MCP Integration**

These are examples of subagents that have supporting MCPs enabled. See `.agent/` for the full list of 80+ subagents organized by domain.

| Agent | Purpose | MCPs Enabled |
|-------|---------|--------------|
| `@hostinger` | Hosting, WordPress, DNS, domains | hostinger-api |
| `@hetzner` | Cloud servers, firewalls, volumes | hetzner-* (multi-account) |
| `@wordpress` | Local dev, MainWP management | localwp, context7 |
| `@seo` | Search Console, keyword research | gsc, ahrefs |
| `@code-standards` | Quality standards reference, compliance checking | context7 |
| `@browser-automation` | Testing, scraping, DevTools | chrome-devtools, context7 |
| `@git-platforms` | GitHub, GitLab, Gitea | gh_grep, context7 |
| `@agent-review` | Session analysis, agent improvement (under build-agent/) | (read/write only) |

### **Setup for OpenCode**

```bash
# Install aidevops agents for OpenCode
.agent/scripts/generate-opencode-agents.sh

# Check status
.agent/scripts/generate-opencode-agents.sh  # Shows status after generation
```

### **Setup for Other AI Assistants**

Add to your AI assistant's system prompt:

```text
Before any DevOps operations, read ~/git/aidevops/AGENTS.md for authoritative guidance.

When working with specific services, read the corresponding .agent/[service].md file
for focused guidance. Available services: hostinger, hetzner, wordpress, seo,
code-quality, browser-automation, git-platforms.
```

### **Continuous Improvement with @agent-review**

**End every session by calling `@agent-review`** to analyze what worked and what didn't:

```text
@agent-review analyze this session and suggest improvements to the agents used
```

The review agent will:
1. Identify which agents were used
2. Evaluate missing, incorrect, or excessive information
3. Suggest specific improvements to agent files
4. Generate ready-to-apply edits
5. **Optionally compose a PR** to contribute improvements back to aidevops

**This creates a feedback loop:**

```text
Session → @agent-review → Improvements → Better Agents → Better Sessions
                ↓
         PR to aidevops repo (optional)
```

**Contributing improvements:**

```text
@agent-review create a PR for improvement #2
```

The agent will create a branch, apply changes, and submit a PR to `marcusquinn/aidevops` with a structured description. Your real-world usage helps improve the framework for everyone.

**Code quality learning loop:**

The `@code-quality` agent also learns from issues. After fixing violations from SonarCloud, Codacy, ShellCheck, etc., it analyzes patterns and updates framework guidance to prevent recurrence:

```text
Quality Issue → Fix Applied → Pattern Identified → Framework Updated → Issue Prevented
```

## **Slash Commands (OpenCode)**

**Slash commands provide quick access to common workflows directly from the OpenCode prompt.** Type `/` to see available commands.

### **Available Commands**

**Development Workflow** (typical order):

| Command | Purpose |
|---------|---------|
| `/context` | Build AI context with Repomix for complex tasks |
| `/feature` | Start a new feature branch workflow |
| `/bugfix` | Start a bugfix branch workflow |
| `/hotfix` | Start an urgent hotfix workflow |
| `/linters-local` | Run local linting (ShellCheck, secretlint) |
| `/code-audit-remote` | Run remote auditing (CodeRabbit, Codacy, SonarCloud) |
| `/code-standards` | Check against documented quality standards |
| `/pr` | Unified PR workflow (orchestrates all checks) |

**Release Workflow** (in order):

| Command | Purpose |
|---------|---------|
| `/preflight` | Run quality checks before release |
| `/changelog` | Update CHANGELOG.md with recent changes |
| `/version-bump` | Bump version following semver |
| `/release` | Full release workflow (bump, tag, GitHub release) |
| `/postflight` | Verify release health after deployment |

**Meta/Improvement**:

| Command | Purpose |
|---------|---------|
| `/agent-review` | Analyze session and suggest agent improvements |

### **Installation**

Slash commands are automatically installed by `setup.sh`:

```bash
# Commands are deployed to:
~/.config/opencode/commands/

# Regenerate commands manually:
.agent/scripts/generate-opencode-commands.sh
```

### **Usage**

In OpenCode, type the command at the prompt:

```text
/preflight
/release minor
/feature add-user-authentication
```

Commands invoke the corresponding workflow subagent with appropriate context.

---

### **Creating Custom Agents**

Create a markdown file in `~/.config/opencode/agent/` (OpenCode) or reference in your AI's system prompt:

```markdown
---
description: Short description of what this agent does
mode: subagent
temperature: 0.2
tools:
  bash: true
  specific-mcp_*: true
---

# Agent Name

Detailed instructions for the agent...
```

See `.agent/opencode-integration.md` for complete documentation.

---

## **Usage Examples**

### **Server Management**

```bash
# List all servers across providers
./.agent/scripts/servers-helper.sh list

# Connect to specific servers
./.agent/scripts/hostinger-helper.sh connect example.com
./.agent/scripts/hetzner-helper.sh connect main web-server

# Execute commands remotely
./.agent/scripts/hostinger-helper.sh exec example.com "uptime"
```

### **Monitoring & Uptime (Updown.io)**

```bash
# List all monitors
./.agent/scripts/updown-helper.sh list

# Add a new website check
./.agent/scripts/updown-helper.sh add https://example.com "My Website"
```

### **Domain & DNS Management**

```bash
# Purchase and configure domain
./.agent/scripts/spaceship-helper.sh purchase example.com
./.agent/scripts/dns-helper.sh cloudflare add-record example.com A 192.168.1.1

# Check domain availability
./.agent/scripts/101domains-helper.sh check-availability example.com
```

### **Quality Control & Performance**

```bash
# Run quality analysis with auto-fixes
bash .agent/scripts/qlty-cli.sh check 10
bash .agent/scripts/qlty-cli.sh fix

# Run chunked Codacy analysis for large repositories
bash .agent/scripts/codacy-cli-chunked.sh quick    # Fast analysis
bash .agent/scripts/codacy-cli-chunked.sh chunked # Full analysis

# AI coding assistance
bash .agent/scripts/ampcode-cli.sh scan ./src
bash .agent/scripts/continue-cli.sh review

# Audit website performance
./.agent/scripts/pagespeed-helper.sh wordpress https://example.com
```

## **Documentation & Resources**

**Wiki Guides:**

- **[Getting Started](.wiki/Getting-Started.md)** - Installation and setup
- **[CLI Reference](.wiki/CLI-Reference.md)** - aidevops command documentation
- **[MCP Integrations](.wiki/MCP-Integrations.md)** - MCP servers setup
- **[Providers](.wiki/Providers.md)** - Service provider configurations
- **[Workflows Guide](.wiki/Workflows-Guide.md)** - Development workflows
- **[The Agent Directory](.wiki/The-Agent-Directory.md)** - Agent file structure
- **[Understanding AGENTS.md](.wiki/Understanding-AGENTS-md.md)** - How agents work

**Agent Guides** (in `.agent/`):

- **[API Integrations](.agent/aidevops/api-integrations.md)** - Service APIs
- **[Browser Automation](.agent/tools/browser/browser-automation.md)** - Web scraping and automation
- **[PageSpeed](.agent/tools/browser/pagespeed.md)** - Performance auditing
- **[Pandoc](.agent/tools/conversion/pandoc.md)** - Document format conversion
- **[Security](.agent/aidevops/security.md)** - Enterprise security standards

**Provider-Specific Guides:** Hostinger, Hetzner, Cloudflare, WordPress, Git platforms, Vercel CLI, Coolify CLI, and more in `.agent/`

## **Architecture**

```text
aidevops/
├── setup.sh                       # Main setup script
├── AGENTS.md                      # AI agent guidance
├── .agent/scripts/                # Automation & setup scripts
├── .agent/scripts/                     # Service helper scripts
├── configs/                       # Configuration templates
├── .agent/                          # Comprehensive documentation
├── .agent/                        # AI agent development tools
├── ssh/                           # SSH key management
└── templates/                     # Reusable templates and examples
```

## **Configuration & Setup**

```bash
# 1. Copy and customize configuration templates
cp configs/hostinger-config.json.txt configs/hostinger-config.json
cp configs/hetzner-config.json.txt configs/hetzner-config.json
# Edit with your actual credentials

# 2. Test connections
./.agent/scripts/servers-helper.sh list

# 3. Install MCP integrations (optional)
bash .agent/scripts/setup-mcp-integrations.sh all
```

## **Security & Best Practices**

**Credential Management:**

- Store API tokens in separate config files (never hardcode)
- Use Ed25519 SSH keys (modern, secure, fast)
- Set proper file permissions (600 for configs)
- Regular key rotation and access audits

**Quality Assurance:**

- Multi-platform analysis (SonarCloud, CodeFactor, Codacy, CodeRabbit, Qlty, Snyk, Gemini Code Assist)
- Automated security monitoring and vulnerability detection

## **Contributing & License**

**Contributing:**

1. Fork the repository
2. Create feature branch
3. Add provider support or improvements
4. Test with your infrastructure
5. Submit pull request

**License:** MIT License - see [LICENSE](LICENSE) file for details
**Created by Marcus Quinn** - Copyright © 2025

---

## **What This Framework Achieves**

**For You:**

- Unified infrastructure management across all services
- AI-powered automation with standardized commands
- Enterprise-grade security and quality assurance
- Time savings through consistent interfaces

**For Your AI Assistant:**

- Structured access to entire DevOps ecosystem
- Real-time documentation via Context7 MCP
- Quality control with automated fixes
- Performance monitoring with and continual improvement of agents' token efficiency, tool use, and file location consistency

**Get Started:**

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/marcusquinn/aidevops/main/setup.sh)
```

Or: `git clone https://github.com/marcusquinn/aidevops.git ~/Git/aidevops && ~/Git/aidevops/setup.sh`

**Transform your AI assistant into a powerful infrastructure management tool with seamless access to all your servers and services.**
