# AI DevOps Framework

**[aidevops.sh](https://aidevops.sh)** — Unleash your AI assistant's true potential with specialist DevOps agents, designed to manage all your infrastructure and services with security and reliability guidance on every decision.

*"List all my servers and websites, and check each for theme and plugin update needs, SEO and page loading performance scores, and give me a list of recommended priorities"* - **One conversation, complete infrastructure management.**

## **The Philosophy**

**Sane vibe-coding through git workflow best practices.** **[aidevops](https://aidevops.sh)** brings structure to AI-assisted development:

- **Git-first workflow** - Protected branches, PR reviews, quality gates before merge
- **Parallel agents** - Multiple AI sessions running full [Ralph loops](#ralph-loop---iterative-ai-development) on separate branches via [git worktrees](#git-worktrees---parallel-branch-development)
- **Progressive discovery** - `/slash` commands and `@subagent` mentions load knowledge into context only when needed
- **Guided development** - Build your AI team incrementally, with specialists for every online need

The result: AI agents that work *with* your development process, not around it.

**Built on proven patterns**: aidevops implements [industry-standard agent design patterns](#agent-design-patterns) validated across Claude Code, Manus, and Cursor - including multi-layer action spaces, context isolation, and iterative execution loops.

**[aidevops](https://aidevops.sh)** knows what you need to know.

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
[![npm version](https://img.shields.io/npm/v/aidevops)](https://www.npmjs.com/package/aidevops)
[![Homebrew](https://img.shields.io/badge/homebrew-marcusquinn%2Ftap-orange)](https://github.com/marcusquinn/homebrew-tap)
[![GitHub Release Date](https://img.shields.io/github/release-date/marcusquinn/aidevops)](https://github.com/marcusquinn/aidevops/releases)
[![GitHub commits since latest release](https://img.shields.io/github/commits-since/marcusquinn/aidevops/latest)](https://github.com/marcusquinn/aidevops/commits/main)

<!-- Repository Stats -->
[![Version](https://img.shields.io/badge/Version-2.61.0-blue)](https://github.com/marcusquinn/aidevops/releases)
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
[![MCP Servers](https://img.shields.io/badge/MCP%20Servers-20-orange.svg)](#mcp-integrations)
[![API Integrations](https://img.shields.io/badge/API%20Integrations-30+-blue.svg)](#comprehensive-service-coverage)

## **Enterprise-Grade Quality & Security**

**Comprehensive DevOps framework with tried & tested services integrations, popular and trusted MCP servers, and enterprise-grade infrastructure quality assurance code monitoring and recommendations.**

## **Security Notice**

**This framework provides agentic AI assistants with powerful infrastructure access. Use responsibly.**

**Capabilities:** Execute commands, access credentials, modify infrastructure, interact with APIs
**Your responsibility:** Use trusted AI providers, rotate credentials regularly, monitor activity

## **Quick Start**

### Installation Options

**npm** (recommended - [verified provenance](https://docs.npmjs.com/generating-provenance-statements)):

```bash
npm install -g aidevops && aidevops update
```

> **Note**: npm suppresses postinstall output. The `&& aidevops update` deploys agents to `~/.aidevops/agents/`. The CLI will remind you if agents need updating.

**Bun** (fast alternative):

```bash
bun install -g aidevops && aidevops update
```

**Homebrew** (macOS/Linux):

```bash
brew install marcusquinn/tap/aidevops && aidevops update
```

**Direct from source** (aidevops.sh):

```bash
bash <(curl -fsSL https://aidevops.sh/install)
```

**Manual** (git clone):

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

**New users: Start OpenCode and type `/onboarding`** to configure your services interactively. The onboarding wizard will:
- Explain what **[aidevops](https://aidevops.sh)** can do
- Ask about your work to give personalized recommendations
- Show which services are configured vs need setup
- Guide you through setting up each service with links and commands

**After installation, use the CLI:**

```bash
aidevops status           # Check what's installed
aidevops update           # Update framework + check registered projects
aidevops init             # Initialize aidevops in any project
aidevops features         # List available features
aidevops repos            # List/add/remove registered projects
aidevops detect           # Scan for unregistered aidevops projects
aidevops upgrade-planning # Upgrade TODO.md/PLANS.md to latest templates
aidevops update-tools     # Check and update installed tools
aidevops uninstall        # Remove aidevops
```

**Project tracking:** When you run `aidevops init`, the project is automatically registered in `~/.config/aidevops/repos.json`. Running `aidevops update` checks all registered projects for version updates.

### **Use aidevops in Any Project**

Initialize **[aidevops](https://aidevops.sh)** features in any git repository:

```bash
cd ~/your-project
aidevops init                         # Enable all features
aidevops init planning                # Enable only planning
aidevops init planning,time-tracking  # Enable specific features
```

This creates:
- `.aidevops.json` - Configuration with enabled features
- `.agent` symlink → `~/.aidevops/agents/`
- `TODO.md` - Quick task tracking with time estimates
- `todo/PLANS.md` - Complex execution plans
- `.beads/` - Task graph database (if beads enabled)

**Available features:** `planning`, `git-workflow`, `code-quality`, `time-tracking`, `beads`

### Upgrade Planning Files

When aidevops templates evolve, upgrade existing projects to the latest format:

```bash
aidevops upgrade-planning           # Interactive upgrade with backup
aidevops upgrade-planning --dry-run # Preview changes without modifying
aidevops upgrade-planning --force   # Skip confirmation prompt
```

This preserves your existing tasks while adding TOON-enhanced parsing, dependency tracking, and better structure.

### Task Graph Visualization with Beads

[Beads](https://github.com/steveyegge/beads) provides task dependency tracking and graph visualization:

```bash
aidevops init beads              # Enable beads (includes planning)
```

**Task Dependencies:**

```markdown
- [ ] t001 First task
- [ ] t002 Second task blocked-by:t001
- [ ] t001.1 Subtask of t001
```

| Syntax | Meaning |
|--------|---------|
| `blocked-by:t001` | Task waits for t001 to complete |
| `blocks:t002` | This task blocks t002 |
| `t001.1` | Subtask of t001 (hierarchical) |

**Commands:**

| Command | Purpose |
|---------|---------|
| `/ready` | Show tasks with no open blockers |
| `/sync-beads` | Sync TODO.md/PLANS.md with Beads graph |
| `bd list` | List all tasks in Beads |
| `bd ready` | Show ready tasks (Beads CLI) |
| `bd graph <id>` | Show dependency graph for an issue |

**Architecture:** **[aidevops](https://aidevops.sh)** markdown files (TODO.md, PLANS.md) are the source of truth. Beads syncs from them for visualization.

**Optional Viewers:** Beyond the `bd` CLI, there are community viewers for richer visualization:
- `beads_viewer` (Python TUI) - PageRank, critical path analysis
- `beads-ui` (Web) - Live updates in browser
- `bdui` (React/Ink TUI) - Modern terminal UI
- `perles` (Rust TUI) - BQL query language

See `.agent/tools/task-management/beads.md` for complete documentation and installation commands.

**Your AI assistant now has agentic access to 30+ service integrations.**

### OpenCode Antigravity OAuth Plugin

The setup automatically installs the [opencode-antigravity-auth](https://github.com/NoeFabris/opencode-antigravity-auth) plugin, enabling Google OAuth authentication for OpenCode. This gives you access to Antigravity rate limits and premium models.

**After setup, authenticate:**

```bash
opencode auth login
# Select: Google → OAuth with Google (Antigravity)
# Press Enter to skip Project ID prompt
```

**Available models via Antigravity:**

- `gemini-3-pro-high` / `gemini-3-pro-low` / `gemini-3-flash`
- `claude-sonnet-4-5` / `claude-sonnet-4-5-thinking` / `claude-opus-4-5-thinking`
- `gpt-oss-120b-medium`

**Multi-account load balancing:** Add multiple Google accounts for automatic rate limit distribution and failover. See the [plugin documentation](https://github.com/NoeFabris/opencode-antigravity-auth) for model configuration.

### OpenCode Anthropic OAuth Plugin

The setup automatically installs the [opencode-anthropic-auth](https://github.com/anomalyco/opencode-anthropic-auth) plugin, enabling OAuth authentication for Claude Pro/Max accounts. This allows Claude subscribers to use OpenCode with zero API costs.

**After setup, authenticate:**

```bash
opencode auth login
# Select: Anthropic → Claude Pro/Max
# Follow OAuth flow in browser
```

**Benefits:**

- **Zero cost** for Claude Pro/Max subscribers (covered by subscription)
- **Automatic token refresh** - No manual re-authentication needed
- **Beta features enabled** - Extended thinking modes and latest features
- **Three authentication methods:**
  - Claude Pro/Max OAuth (recommended for subscribers)
  - Create API Key via OAuth
  - Manual API key entry

**Available models:**

All Anthropic models available to Pro/Max subscribers, including:
- `claude-sonnet-4-20250514`
- `claude-opus-4-5`
- Extended thinking modes

See the [plugin documentation](https://github.com/anomalyco/opencode-anthropic-auth) and `.agent/tools/opencode/opencode-anthropic-auth.md` for complete setup and troubleshooting.

### Oh-My-OpenCode Plugin (Optional)

The setup offers to install [oh-my-opencode](https://github.com/code-yeongyu/oh-my-opencode) - a complementary plugin that adds **coding productivity features**:

| Feature | Description |
|---------|-------------|
| **Async Background Agents** | Run multiple agents in parallel (like Claude Code) |
| **LSP Tools** | 11 tools: hover, goto definition, references, rename, code actions |
| **AST-Grep** | Semantic code search and replace across 25 languages |
| **Curated Agents** | OmO (Opus 4.5), Oracle (GPT 5.2), Librarian (Sonnet 4.5), Explore (Grok) |
| **Claude Code Compatibility** | Full support for hooks, commands, skills from `.claude/` directories |
| **21 Lifecycle Hooks** | Comment checker, todo enforcer, context window monitor, session recovery |

**How they complement each other:**

- **aidevops** provides DevOps infrastructure (30+ services: hosting, DNS, WordPress, SEO, code quality)
- **oh-my-opencode** provides coding productivity (LSP, AST, background agents, hooks)

**Usage after installation:**

```bash
# Trigger maximum performance mode
> ultrawork implement the authentication system

# Use curated agents
> @oracle review this architecture
> @librarian find examples of this pattern on GitHub
> @explore search for authentication handling
```

See `.agent/tools/opencode/oh-my-opencode.md` for the full compatibility guide.

### GitHub AI Agent Integration

Enable AI-powered issue resolution directly from GitHub. Comment `/oc fix this` on any issue and the AI creates a branch, implements the fix, and opens a PR.

**Security-first design** - The workflow includes:
- Trusted users only (OWNER/MEMBER/COLLABORATOR)
- `ai-approved` label required on issues before AI processing
- Prompt injection pattern detection
- Audit logging of all invocations
- 15-minute timeout and rate limiting

**Quick setup:**

```bash
# 1. Install the OpenCode GitHub App
# Visit: https://github.com/apps/opencode-agent

# 2. Add API key secret
# Repository → Settings → Secrets → ANTHROPIC_API_KEY

# 3. Create required labels
gh label create "ai-approved" --color "0E8A16" --description "Issue approved for AI agent"
gh label create "security-review" --color "D93F0B" --description "Requires security review"
```

The secure workflow is included at `.github/workflows/opencode-agent.yml`.

**Usage:**

| Context | Command | Result |
|---------|---------|--------|
| Issue (with `ai-approved` label) | `/oc fix this` | Creates branch + PR |
| Issue | `/oc explain this` | AI analyzes and replies |
| PR | `/oc review this PR` | Code review feedback |
| PR Files tab | `/oc add error handling here` | Line-specific fix |

See `.agent/tools/git/opencode-github-security.md` for the full security documentation.

**Supported AI Assistants:** (OpenCode & Zed are our daily drivers and preferred tools, so will have the most continual testing. All 18 assistants below have MCP configuration support.)

**Preferred:**

- **[Tabby](https://tabby.sh/)** - Modern terminal with colour-coded Profiles. Use different profile colours per project/repo to visually distinguish which codebase you're working in. **Auto-syncs tab title with git repo/branch.**
- **[OpenCode](https://opencode.ai/)** - Primary choice. Powerful agentic TUI/CLI with native MCP support, Tab-based agent switching, and excellent DX.
- **[Zed](https://zed.dev/)** - High-performance editor with AI (Preferred, with the OpenCode Agent Extension)

### Terminal Tab Title Sync

Your terminal tab/window title automatically shows `repo/branch` context when working in git repositories. This helps identify which codebase and branch you're working on across multiple terminal sessions.

**Supported terminals:** Tabby, iTerm2, Windows Terminal, Kitty, Alacritty, WezTerm, Hyper, and most xterm-compatible terminals.

**How it works:** The `pre-edit-check.sh` script's primary role is enforcing git workflow protection (blocking edits on main/master branches). As a secondary, non-blocking action, it updates the terminal title via escape sequences. No configuration needed - it's automatic.

**Example format:** `{repo}/{branch-type}/{description}`

See `.agent/tools/terminal/terminal-title.md` for customization options.

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

## **Agent Design Patterns**

aidevops implements proven agent design patterns identified by [Lance Martin (LangChain)](https://x.com/RLanceMartin/status/2009683038272401719) and validated across successful agents like Claude Code, Manus, and Cursor.

| Pattern | Description | aidevops Implementation |
|---------|-------------|------------------------|
| **Give Agents a Computer** | Filesystem + shell for persistent context | `~/.aidevops/.agent-workspace/`, 100+ helper scripts |
| **Multi-Layer Action Space** | Few tools, push actions to computer | Per-agent MCP filtering (~12-20 tools each) |
| **Progressive Disclosure** | Load context on-demand | Subagent tables, YAML frontmatter, read-on-demand |
| **Offload Context** | Write results to filesystem | `.agent-workspace/work/[project]/` for persistence |
| **Cache Context** | Prompt caching for cost | Stable instruction prefixes |
| **Isolate Context** | Sub-agents with separate windows | Subagent files with specific tool permissions |
| **Ralph Loop** | Iterative execution until complete | `ralph-loop-helper.sh`, `full-loop-helper.sh` |
| **Evolve Context** | Learn from sessions | `/remember`, `/recall` with SQLite FTS5 |

**Key insight**: Context is a finite resource with diminishing returns. aidevops treats every token as precious - loading only what's needed, when it's needed.

See `.agent/aidevops/architecture.md` for detailed implementation notes and references.

## **Requirements**

```bash
# Install dependencies (auto-detected by setup.sh)
brew install sshpass jq curl mkcert dnsmasq fd ripgrep  # macOS
sudo apt-get install sshpass jq curl dnsmasq fd-find ripgrep  # Ubuntu/Debian

# Generate SSH key
ssh-keygen -t ed25519 -C "your-email@domain.com"
```

### **File Discovery Tools**

AI agents use fast file discovery tools for efficient codebase navigation:

| Tool | Purpose | Speed |
|------|---------|-------|
| `fd` | Fast file finder (replaces `find`) | ~10x faster |
| `ripgrep` | Fast content search (replaces `grep`) | ~10x faster |

Both tools respect `.gitignore` by default and are written in Rust for maximum performance.

**Preference order for file discovery:**

1. `git ls-files '*.md'` - Instant, git-tracked files only
2. `fd -e md` - Fast, respects .gitignore
3. `rg --files -g '*.md'` - Fast, respects .gitignore
4. Built-in glob tools - Fallback when bash unavailable

The setup script offers to install these tools automatically.

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

### **AI Orchestration Frameworks**

- **[Langflow](https://langflow.org/)**: Visual drag-and-drop builder for AI workflows (MIT, localhost:7860)
- **[CrewAI](https://crewai.com/)**: Multi-agent teams with role-based orchestration (MIT, localhost:8501)
- **[AutoGen](https://microsoft.github.io/autogen/)**: Microsoft's agentic AI framework with MCP support (MIT, localhost:8081)

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

### **Communications**

- **[Twilio](https://www.twilio.com/)**: SMS, voice calls, WhatsApp, phone verification (Verify API), call recording & transcription
- **[Telfon](https://mytelfon.com/)**: Twilio-powered cloud phone system with iOS/Android/Chrome apps for end-user calling interface

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
| [DataForSEO](https://dataforseo.com/) | SERP, keywords, backlinks, on-page | Yes |
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
| [Serper](https://serper.dev/) | Google Search API (web, images, news) | Yes |
| [shadcn/ui](https://ui.shadcn.com/) | UI component library browsing & installation | No |
| [Snyk](https://snyk.io/) | Security vulnerability scanning | Yes |
| [Stagehand (JS)](https://github.com/browserbase/stagehand) | AI browser automation | Optional (Browserbase) |
| [Stagehand (Python)](https://github.com/anthropics/stagehand-python) | AI browser automation | Optional (Browserbase) |
| [llm-tldr](https://github.com/parcadei/llm-tldr) | Semantic code analysis (95% token savings) | No |

### **By Category**

**Context & Codebase:**

- [Augment Context Engine](https://docs.augmentcode.com/context-services/mcp/overview) - Semantic codebase retrieval with deep code understanding
- [llm-tldr](https://github.com/parcadei/llm-tldr) - Semantic code analysis with 95% token savings (tree, structure, CFG, DFG, impact analysis)
- [osgrep](https://github.com/Ryandonofrio3/osgrep) - Local semantic search (100% private, no cloud)
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
- [DataForSEO](https://dataforseo.com/) - Comprehensive SEO data APIs (SERP, keywords, backlinks, on-page)
- [Serper](https://serper.dev/) - Google Search API (web, images, news, places, shopping)
- [Google Search Console](https://developers.google.com/webmaster-tools) - Search performance insights
- [Perplexity](https://docs.perplexity.ai/) - AI-powered web search and research
- [Grep by Vercel](https://grep.app/) - Search code snippets across GitHub repositories
- **Keyword Research** - Strategic keyword research with SERP weakness detection (via DataForSEO + Serper + Ahrefs)
- **Site Crawler** - Screaming Frog-like SEO auditing: broken links, redirects, meta issues, structured data
- **Domain Research** - DNS intelligence via THC (4.51B records) and Reconeer APIs: rDNS, subdomains, CNAMEs

**Data Extraction:**

- [Outscraper](https://outscraper.com/) - Google Maps, business data, reviews extraction

**Performance & Security:**

- [PageSpeed Insights](https://developers.google.com/speed/docs/insights/v5/get-started) - Website performance auditing
- [Snyk](https://snyk.io/) - Security vulnerability scanning

**WordPress & Development:**

- [LocalWP](https://localwp.com/) - Direct WordPress database access
- [Next.js DevTools](https://nextjs.org/docs) - React/Next.js development assistance

**UI Components:**

- [shadcn/ui](https://ui.shadcn.com/) - Browse, search, and install shadcn/ui components directly via MCP

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

See `.agent/tools/context/osgrep.md` for complete documentation and AI tool configurations.

### llm-tldr - Semantic Code Analysis

[llm-tldr](https://github.com/parcadei/llm-tldr) extracts code structure and semantics, saving ~95% tokens compared to raw code. From the [Continuous-Claude](https://github.com/parcadei/Continuous-Claude-v3) project.

```bash
# Install
pip install llm-tldr

# CLI usage
tldr tree ./src                    # File structure with line counts
tldr structure src/auth.py         # Code skeleton (classes, functions)
tldr context src/auth.py           # Full semantic analysis
tldr search "authentication" ./src # Semantic code search
tldr impact src/auth.py validate   # What would change affect?
```

**MCP Integration:**

```json
{
  "llm-tldr": {
    "command": "tldr-mcp",
    "args": ["--project", "${workspaceFolder}"]
  }
}
```

| Feature | Token Savings | Use Case |
|---------|---------------|----------|
| Structure extraction | 90% | Understanding code layout |
| Context analysis | 95% | Deep code understanding |
| Semantic search | N/A | Finding code by meaning |
| Impact analysis | N/A | Change risk assessment |

See `.agent/tools/context/llm-tldr.md` for complete documentation.

## **Cross-Tool Compatibility**

### Agent Skills Standard

aidevops implements the [Agent Skills](https://agentskills.io/) standard for cross-tool compatibility. Skills are auto-discovered by compatible AI assistants.

**Generated SKILL.md files** in `~/.aidevops/agents/` provide skill metadata for:
- Cursor
- Claude Code
- VS Code (GitHub Copilot)
- Other Agent Skills-compatible tools

### Claude Code Plugin Marketplace

aidevops is registered as a **Claude Code plugin marketplace**. Install with two commands:

```bash
/plugin marketplace add marcusquinn/aidevops
/plugin install aidevops@aidevops
```

This installs the complete framework: 14 domain agents, 80+ subagents, and 100+ helper scripts.

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
| Plan+ | `plan-plus.md` | Planning with semantic search, writes to TODO.md/todo/ | context7, augment, repomix |
| Build+ | `build-plus.md` | Enhanced Build with context tools | context7, augment, repomix |
| Build-Agent | `build-agent.md` | Design and improve AI agents | context7, augment, repomix |
| Build-MCP | `build-mcp.md` | Build MCP servers with TS+Bun+ElysiaJS | context7, augment, repomix |
| Accounts | `accounts.md` | Financial operations | quickfile, augment |
| AI-DevOps | `aidevops.md` | Framework operations, meta-agents, setup | context7, augment, repomix |
| Content | `content.md` | Content creation workflows | augment |
| Health | `health.md` | Health and wellness guidance | augment |
| Legal | `legal.md` | Legal compliance and documentation | augment |
| Marketing | `marketing.md` | Marketing strategy and automation | augment |
| Research | `research.md` | Research and analysis tasks | context7, augment |
| Sales | `sales.md` | Sales operations and CRM | augment |
| SEO | `seo.md` | SEO optimization, Search Console, keyword research | gsc, ahrefs, dataforseo, serper, context7, augment |
| WordPress | `wordpress.md` | WordPress ecosystem (dev, admin, MainWP, LocalWP) | localwp, context7, augment |

### **Example Subagents with MCP Integration**

These are examples of subagents that have supporting MCPs enabled. See `.agent/` for the full list of 80+ subagents organized by domain.

| Agent | Purpose | MCPs Enabled |
|-------|---------|--------------|
| `@hostinger` | Hosting, WordPress, DNS, domains | hostinger-api |
| `@hetzner` | Cloud servers, firewalls, volumes | hetzner-* (multi-account) |
| `@wordpress` | Local dev, MainWP management | localwp, context7 |
| `@seo` | Search Console, keyword research, domain intelligence | gsc, ahrefs, dataforseo, serper, context7 |
| `@dataforseo` | SERP, keywords, backlinks, on-page analysis | dataforseo |
| `@domain-research` | DNS intelligence: rDNS, subdomains, CNAMEs (THC + Reconeer) | (API-based) |
| `@serper` | Google Search API (web, images, news, places) | serper |
| `@list-keys` | List all configured API keys and storage locations | (read-only) |
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

**Claude Code** (recommended):

```bash
/plugin marketplace add marcusquinn/aidevops
/plugin install aidevops-all@aidevops
```

**Agent Skills-compatible tools** (Cursor, VS Code, etc.):
Skills are auto-discovered from `~/.aidevops/agents/` via SKILL.md files after running `setup.sh`.

**Manual configuration** (other tools):
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

**Planning & Task Management**:

| Command | Purpose |
|---------|---------|
| `/list-todo` | List tasks with sorting, filtering, and grouping |
| `/save-todo` | Save discussion as task or plan (auto-detects complexity) |
| `/plan-status` | Check status of plans in `TODO.md` and `todo/PLANS.md` |
| `/create-prd` | Create a Product Requirements Document for complex features |
| `/generate-tasks` | Generate implementation tasks from a PRD |
| `/log-time-spent` | Log time spent on a task for tracking |
| `/ready` | Show tasks with no open blockers (Beads integration) |
| `/sync-beads` | Sync TODO.md/PLANS.md with Beads task graph |
| `/remember` | Store knowledge for cross-session recall |
| `/recall` | Search memories from previous sessions |

Plans are tracked in `TODO.md` (all tasks) and `todo/PLANS.md` (complex execution plans). Task dependencies are visualized with [Beads](https://github.com/steveyegge/beads).

**`/list-todo` options:**

| Option | Example | Purpose |
|--------|---------|---------|
| `--priority` | `/list-todo -p` | Sort by priority (high → low) |
| `--estimate` | `/list-todo -e` | Sort by time estimate (shortest first) |
| `--tag` | `/list-todo -t seo` | Filter by tag |
| `--owner` | `/list-todo -o marcus` | Filter by assignee |
| `--estimate` | `/list-todo --estimate "<2h"` | Filter by estimate range |
| `--group-by` | `/list-todo -g tag` | Group by tag, owner, status, or estimate |
| `--plans` | `/list-todo --plans` | Include full plan details |
| `--compact` | `/list-todo --compact` | One-line per task |

**Time Tracking**: Tasks support time estimates and actuals with the format `~4h (ai:2h test:1h) started:2025-01-15T10:30Z`. Configure per-repo via `.aidevops.json`.

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
| `/code-simplifier` | Simplify and refine code for clarity and maintainability |
| `/list-keys` | List all configured API keys and their storage locations |
| `/pr` | Unified PR workflow (orchestrates all checks) |

**SEO Workflow**:

| Command | Purpose |
|---------|---------|
| `/keyword-research` | Seed keyword expansion with volume, CPC, difficulty |
| `/autocomplete-research` | Google autocomplete long-tail discovery |
| `/keyword-research-extended` | Full SERP analysis with weakness detection |
| `/webmaster-keywords` | Keywords from GSC + Bing for your verified sites |

**Release Workflow** (in order):

| Command | Purpose |
|---------|---------|
| `/preflight` | Run quality checks before release |
| `/changelog` | Update CHANGELOG.md with recent changes |
| `/version-bump` | Bump version following semver |
| `/release` | Full release workflow (bump, tag, GitHub release, auto-changelog) |
| `/postflight` | Verify release health after deployment |

**Meta/Improvement**:

| Command | Purpose |
|---------|---------|
| `/agent-review` | Analyze session and suggest agent improvements |
| `/session-review` | Review session for completeness and capture learnings |
| `/full-loop` | End-to-end development loop (task → preflight → PR → postflight → deploy) |
| `/preflight-loop` | Run preflight checks iteratively until all pass |

### Ralph Loop - Iterative AI Development

The **Ralph Loop** (named after Ralph Wiggum's persistent optimism) enables autonomous iterative development. The AI keeps working on a task until it's complete, automatically resolving issues that arise.

**How it works:**

```text
Task → Implement → Check → Fix Issues → Re-check → ... → Complete
         ↑                    ↓
         └────────────────────┘ (loop until done)
```

**Usage:**

```bash
# Run quality checks iteratively until all pass
.agent/scripts/quality-loop-helper.sh preflight --auto-fix --max-iterations <MAX_ITERATIONS>

# Or use the slash command
/preflight-loop --auto-fix --max-iterations <MAX_ITERATIONS>
```

**Note:** Store any API credentials securely via environment variables or `.env` files (never commit credentials to version control).

**Key features:**
- Automatic issue detection and resolution
- Configurable max iterations (prevents infinite loops)
- Works with any quality check (linting, tests, builds)
- Detailed logging of each iteration

See `.agent/workflows/ralph-loop.md` for the full workflow guide.

### Full Loop - End-to-End Development Automation

The **Full Loop** chains all development phases into a single automated workflow:

```text
Task Development → Preflight → PR Create → PR Review → Postflight → Deploy
```

**Usage:**

```bash
# Start a full development loop
/full-loop "Implement feature X with tests"

# With options
/full-loop "Fix bug Y" --max-task-iterations 30 --skip-postflight
```

**Options:**

| Option | Description |
|--------|-------------|
| `--max-task-iterations N` | Max iterations for task (default: 50) |
| `--skip-preflight` | Skip preflight checks |
| `--skip-postflight` | Skip postflight monitoring |
| `--no-auto-pr` | Pause for manual PR creation |

The loop pauses for human input at merge approval, rollback decisions, and scope changes.

See `.agent/scripts/commands/full-loop.md` for complete documentation.

### Git Worktrees - Parallel Branch Development

Work on multiple branches simultaneously without stashing or switching. Each branch gets its own directory.

**Recommended: [Worktrunk](https://worktrunk.dev)** (`wt`) - Git worktree management with shell integration, CI status, and PR links:

```bash
# Install (macOS/Linux)
brew install max-sixty/worktrunk/wt && wt config shell install
# Restart your shell for shell integration to take effect

# Create worktree + cd into it
wt switch -c feature/my-feature

# Create worktree + start any AI CLI (-x runs command after switch)
wt switch -c -x claude feature/ai-task

# List worktrees with CI status and PR links
wt list

# Merge + cleanup (squash/rebase options)
wt merge
```

**Fallback** (no dependencies):

```bash
~/.aidevops/agents/scripts/worktree-helper.sh add feature/my-feature
# Creates: ~/Git/{repo}-feature-my-feature/ (cd there manually)
~/.aidevops/agents/scripts/worktree-helper.sh list
~/.aidevops/agents/scripts/worktree-helper.sh clean
```

**Benefits:**
- Run tests on one branch while coding on another
- Compare implementations side-by-side
- No context switching or stash management
- Each AI session can work on a different branch

**Worktree-first workflow:** The pre-edit check now **enforces** worktrees as the default when creating branches, keeping your main directory on `main`. This prevents uncommitted changes from blocking branch switches and ensures parallel sessions don't inherit wrong branch state.

See `.agent/workflows/worktree.md` for the complete guide and `.agent/tools/git/worktrunk.md` for Worktrunk documentation.

### Session Management - Parallel AI Sessions

Spawn new AI sessions for parallel work or fresh context. The framework detects natural session completion points and suggests next steps.

**Completion signals:**

| Signal | Meaning |
|--------|---------|
| PR merged | Branch work complete |
| Release published | Version shipped |
| All tests passing | Quality gates satisfied |
| User says "done" | Explicit completion |

**Spawning options:**

```bash
# Background session (same terminal)
opencode --non-interactive --prompt "Continue with feature X" &

# New terminal tab (macOS)
osascript -e 'tell application "Terminal" to do script "cd ~/Git/project && opencode"'

# Worktree-based (isolated branch) - recommended
wt switch -c -x opencode feature/next-feature  # Worktrunk: create + start AI CLI
# Or fallback:
# ~/.aidevops/agents/scripts/worktree-helper.sh add feature/next-feature
# cd ~/Git/{repo}-feature-next-feature && opencode
```

**Session handoff pattern:**

When ending a session, the AI provides a continuation prompt for the next session:

```markdown
## Continuation Prompt
[Copy this to start a new session with full context]
```

See `.agent/workflows/session-manager.md` for the complete guide.

### Cross-Session Memory System

**"Compound, then clear"** - Sessions should build on each other. The memory system stores knowledge, patterns, and learnings for future sessions using SQLite FTS5 for fast full-text search.

**Slash commands:**

| Command | Purpose |
|---------|---------|
| `/remember {content}` | Store a memory with AI-assisted categorization |
| `/recall {query}` | Search memories by keyword |
| `/recall --recent` | Show 10 most recent memories |
| `/recall --stats` | Show memory statistics |

**Memory types:**

| Type | Use For |
|------|---------|
| `WORKING_SOLUTION` | Fixes that worked |
| `FAILED_APPROACH` | What didn't work (avoid repeating) |
| `CODEBASE_PATTERN` | Project conventions |
| `USER_PREFERENCE` | Developer preferences |
| `TOOL_CONFIG` | Tool setup notes |
| `DECISION` | Architecture decisions |
| `CONTEXT` | Background info |

**CLI usage:**

```bash
# Store a memory
~/.aidevops/agents/scripts/memory-helper.sh store "WORKING_SOLUTION" "Fixed CORS with nginx headers" "cors,nginx"

# Recall memories
~/.aidevops/agents/scripts/memory-helper.sh recall "cors"

# View statistics
~/.aidevops/agents/scripts/memory-helper.sh stats

# Maintenance
~/.aidevops/agents/scripts/memory-helper.sh validate   # Check for stale entries
~/.aidevops/agents/scripts/memory-helper.sh prune      # Remove stale memories
```

**Storage:** `~/.aidevops/.agent-workspace/memory/memory.db`

See `.agent/memory/README.md` for complete documentation.

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

### **Strategic Keyword Research**

```bash
# Basic keyword research with volume, CPC, difficulty
./.agent/scripts/keyword-research-helper.sh research "seo tools" --limit 20

# Google autocomplete long-tail discovery
./.agent/scripts/keyword-research-helper.sh autocomplete "how to" --provider both

# Extended research with SERP weakness detection
./.agent/scripts/keyword-research-helper.sh extended "keywords" --quick

# Competitor keyword research
./.agent/scripts/keyword-research-helper.sh extended --competitor ahrefs.com --limit 50

# Keyword gap analysis (find keywords competitor ranks for but you don't)
./.agent/scripts/keyword-research-helper.sh extended --gap semrush.com,ahrefs.com

# Domain research (all keywords a domain ranks for)
./.agent/scripts/keyword-research-helper.sh extended --domain example.com --limit 100
```

**Features:**

- **6 Research Modes**: Keyword expansion, autocomplete, domain research, competitor research, keyword gap, extended SERP analysis
- **17 SERP Weaknesses**: Low domain score, no backlinks, thin content, UGC-heavy, non-HTTPS, and more
- **KeywordScore Algorithm**: 0-100 score based on weakness count, volume, and difficulty
- **Multi-Provider**: DataForSEO (primary), Serper (autocomplete), Ahrefs (domain ratings)
- **Locale Support**: US/UK/CA/AU/DE/FR/ES with saved preferences
- **Output Formats**: Markdown tables (TUI) and CSV export to ~/Downloads

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
# npm (recommended)
npm install -g aidevops && aidevops update

# Bun (fast alternative)
bun install -g aidevops && aidevops update

# Homebrew
brew install marcusquinn/tap/aidevops && aidevops update

# Direct from source
bash <(curl -fsSL https://aidevops.sh/install)
```

**Transform your AI assistant into a powerful infrastructure management tool with seamless access to all your servers and services.**
