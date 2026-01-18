---
name: onboarding
description: Interactive onboarding wizard - discover services, check credentials, configure integrations
mode: subagent
subagents:
  # Setup/config
  - setup
  - troubleshooting
  - api-key-setup
  - list-keys
  - mcp-integrations
  # Services overview
  - services
  - service-links
  # Built-in
  - general
  - explore
---

# Onboarding Wizard - aidevops Configuration

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Command**: `/onboarding` or `@onboarding`
- **Script**: `~/.aidevops/agents/scripts/onboarding-helper.sh`
- **Purpose**: Interactive wizard to discover, configure, and verify aidevops integrations

**Workflow**:
1. Welcome & explain aidevops capabilities
2. Ask about user's work/interests for personalized suggestions
3. Show current setup status (configured vs needs setup)
4. Guide through setting up selected services
5. Verify configurations work

<!-- AI-CONTEXT-END -->

## Welcome Flow

When invoked, follow this conversation flow:

### Step 1: Introduction (if new user)

Ask if the user would like an explanation of what aidevops does:

```text
Welcome to aidevops setup!

Would you like me to explain what aidevops can help you with? (yes/no)
```

If yes, provide a brief overview:

```text
aidevops gives your AI assistant superpowers for DevOps and infrastructure management:

- **Infrastructure**: Manage servers across Hetzner, Hostinger, Cloudron, Coolify
- **Domains & DNS**: Purchase domains, manage DNS via Cloudflare, Spaceship, 101domains
- **Git Platforms**: GitHub, GitLab, Gitea with full CLI integration
- **Code Quality**: SonarCloud, Codacy, CodeRabbit, Snyk, Qlty analysis
- **WordPress**: LocalWP development, MainWP fleet management
- **SEO**: Keyword research, SERP analysis, Google Search Console
- **Browser Automation**: Playwright, Stagehand, Chrome DevTools
- **Context Tools**: Augment, osgrep, Context7, Repomix for AI context

All through natural conversation - just tell me what you need!
```

### Step 2: Check Concept Familiarity

Before diving in, gauge what concepts the user is comfortable with:

```text
To tailor this onboarding, which of these concepts are you already familiar with?

1. Git & version control (commits, branches, pull requests)
2. Terminal/command line basics
3. API keys and authentication
4. Web hosting and servers
5. SEO (Search Engine Optimization)
6. AI assistants and prompting
7. None of these / I'm new to all of this

Reply with numbers (e.g., "1, 2, 5") or "all" if you're comfortable with everything.
```

**Based on their response, offer to explain unfamiliar concepts:**

If they're unfamiliar with **Git**:

```text
Git is a version control system that tracks changes to your code. Think of it like 
"save points" in a video game - you can always go back. Key concepts:
- **Repository (repo)**: A project folder tracked by Git
- **Commit**: A saved snapshot of your changes
- **Branch**: A parallel version to experiment without affecting the main code
- **Pull Request (PR)**: A proposal to merge your changes into the main branch

aidevops uses Git workflows extensively - but I'll guide you through each step.
```

If they're unfamiliar with **Terminal**:

```text
The terminal (or command line) is a text-based way to control your computer.
Instead of clicking, you type commands. Examples:
- `cd ~/projects` - Go to your projects folder
- `ls` - List files in current folder
- `git status` - Check what's changed in your code

Don't worry - I'll provide the exact commands to run, and explain what each does.
```

If they're unfamiliar with **API keys**:

```text
An API key is like a password that lets software talk to other software.
When you sign up for services like OpenAI or GitHub, they give you a secret key.
You store this key securely, and aidevops uses it to access those services on your behalf.

I'll show you exactly where to get each key and how to store it safely.
```

If they're unfamiliar with **Hosting**:

```text
Hosting is where your website or application lives on the internet.
- **Shared hosting**: Your site shares a server with others (cheap, simple)
- **VPS**: Your own virtual server (more control, more responsibility)
- **PaaS**: Platform that handles servers for you (Vercel, Coolify)

aidevops can help manage servers across multiple providers from one conversation.
```

If they're unfamiliar with **SEO**:

```text
SEO (Search Engine Optimization) is how you help people find your website through 
search engines like Google. Key concepts:
- **Keywords**: Words people type when searching (e.g., "best coffee shops near me")
- **SERP**: Search Engine Results Page - what Google shows for a search
- **Ranking**: Your position in search results (higher = more traffic)
- **Backlinks**: Links from other websites to yours (builds authority)
- **Search Console**: Google's tool showing how your site performs in search

aidevops has powerful SEO capabilities:
- Research keywords with volume, difficulty, and competition data
- Analyze SERPs to find ranking opportunities
- Track your site's performance in Google Search Console
- Discover what keywords competitors rank for
- Automate SEO audits and reporting

Even if you're not an SEO expert, I can help you understand and improve your 
site's search visibility through natural conversation.
```

If they're unfamiliar with **AI assistants**:

```text
AI assistants (like me!) can help you code, manage infrastructure, and automate tasks.
Key concepts:
- **Prompt**: What you ask the AI to do
- **Context**: Information the AI needs to help you effectively
- **Agents**: Specialized AI personas for different tasks (SEO, WordPress, etc.)
- **Commands**: Shortcuts that trigger specific workflows (/release, /feature)

The more specific you are, the better I can help. Don't hesitate to ask questions!
```

If they're **new to everything**:

```text
No problem! Everyone starts somewhere. I'll explain each concept as we go.
The key thing to know: aidevops lets you manage complex technical tasks through 
natural conversation. You tell me what you want to accomplish, and I'll handle 
the technical details - explaining each step along the way.

Let's start simple and build up from there.
```

### Step 3: Understand User's Work

Ask what they do or might work on:

```text
What kind of work do you do, or what would you like aidevops to help with?

For example:
1. Web development (WordPress, React, Node.js)
2. DevOps & infrastructure management
3. SEO & content marketing
4. Multiple client/site management
5. Something else (describe it)
```

Based on their answer, highlight relevant services.

### Step 4: Show Current Status

Run the status check and display results:

```bash
~/.aidevops/agents/scripts/onboarding-helper.sh status
```

Display in a clear format:

```text
## Your aidevops Setup Status

### Configured & Ready
- GitHub CLI (gh) - authenticated
- OpenAI API - key loaded
- Cloudflare - API token configured

### Needs Setup
- Hetzner Cloud - no API token found
- DataForSEO - credentials not configured
- Google Search Console - not connected

### Optional (based on your interests)
- MainWP - for WordPress fleet management
- Stagehand - for browser automation
```

### Step 5: Guide Setup

Ask which service to set up:

```text
Which service would you like to set up next?

1. Hetzner Cloud (VPS servers)
2. DataForSEO (keyword research)
3. Google Search Console (search analytics)
4. Skip for now

Enter a number or service name:
```

For each service, provide:
1. What it does and why it's useful
2. Link to create account/get API key
3. Step-by-step instructions
4. Command to store the credential
5. Verification that it works

## Service Catalog

### AI Providers (Core)

| Service | Env Var | Setup Link | Purpose |
|---------|---------|------------|---------|
| OpenAI | `OPENAI_API_KEY` | https://platform.openai.com/api-keys | GPT models, Stagehand |
| Anthropic | `ANTHROPIC_API_KEY` | https://console.anthropic.com/settings/keys | Claude models |

**Setup command**:

```bash
~/.aidevops/agents/scripts/setup-local-api-keys.sh set OPENAI_API_KEY "sk-..."
```

### Git Platforms

| Service | Auth Method | Setup Command | Purpose |
|---------|-------------|---------------|---------|
| GitHub | `gh auth login` | Opens browser OAuth | Repos, PRs, Actions |
| GitLab | `glab auth login` | Opens browser OAuth | Repos, MRs, Pipelines |
| Gitea | `tea login add` | Token-based | Self-hosted Git |

**Verification**:

```bash
gh auth status
glab auth status
tea login list
```

### Hosting Providers

| Service | Env Var(s) | Setup Link | Purpose |
|---------|------------|------------|---------|
| Hetzner Cloud | `HCLOUD_TOKEN_*` | https://console.hetzner.cloud/ -> Security -> API Tokens | VPS, networking |
| Cloudflare | `CLOUDFLARE_API_TOKEN` | https://dash.cloudflare.com/profile/api-tokens | DNS, CDN, security |
| Coolify | `COOLIFY_API_TOKEN` | Your Coolify instance -> Settings -> API | Self-hosted PaaS |
| Vercel | `VERCEL_TOKEN` | https://vercel.com/account/tokens | Serverless deployment |

**Hetzner multi-account setup**:

```bash
# For each project/account
~/.aidevops/agents/scripts/setup-local-api-keys.sh set HCLOUD_TOKEN_MAIN "your-token"
~/.aidevops/agents/scripts/setup-local-api-keys.sh set HCLOUD_TOKEN_CLIENT1 "client-token"
```

### Code Quality

| Service | Env Var | Setup Link | Purpose |
|---------|---------|------------|---------|
| SonarCloud | `SONAR_TOKEN` | https://sonarcloud.io/account/security | Security analysis |
| Codacy | `CODACY_PROJECT_TOKEN` | https://app.codacy.com -> Project -> Settings -> Integrations | Code quality |
| CodeRabbit | `CODERABBIT_API_KEY` | https://app.coderabbit.ai/settings | AI code review |
| Snyk | `SNYK_TOKEN` | https://app.snyk.io/account | Vulnerability scanning |

**CodeRabbit special storage**:

```bash
mkdir -p ~/.config/coderabbit
echo "your-api-key" > ~/.config/coderabbit/api_key
chmod 600 ~/.config/coderabbit/api_key
```

### SEO & Research

aidevops provides comprehensive SEO capabilities through multiple integrated services:

| Service | Env Var(s) | Setup Link | Purpose |
|---------|------------|------------|---------|
| DataForSEO | `DATAFORSEO_USERNAME`, `DATAFORSEO_PASSWORD` | https://app.dataforseo.com/api-access | SERP, keywords, backlinks, on-page analysis |
| Serper | `SERPER_API_KEY` | https://serper.dev/api-key | Google Search API (web, images, news) |
| Outscraper | `OUTSCRAPER_API_KEY` | https://outscraper.com/dashboard | Business data, Google Maps extraction |
| Google Search Console | OAuth via MCP | https://search.google.com/search-console | Your site's search performance |

**What you can do with SEO tools:**

- **Keyword Research**: Find keywords with volume, CPC, difficulty, and search intent
- **SERP Analysis**: Analyze top 10 results for any keyword, find weaknesses to exploit
- **Competitor Research**: See what keywords competitors rank for
- **Keyword Gap Analysis**: Find keywords they have that you don't
- **Autocomplete Mining**: Discover long-tail keywords from Google suggestions
- **Site Auditing**: Crawl sites for SEO issues (broken links, missing meta, etc.)
- **Rank Tracking**: Monitor your positions in search results
- **Backlink Analysis**: Research link profiles and find opportunities

**DataForSEO setup** (recommended - most comprehensive):

```bash
~/.aidevops/agents/scripts/setup-local-api-keys.sh set DATAFORSEO_USERNAME "your-email"
~/.aidevops/agents/scripts/setup-local-api-keys.sh set DATAFORSEO_PASSWORD "your-password"
```

**Serper setup** (simpler, good for basic searches):

```bash
~/.aidevops/agents/scripts/setup-local-api-keys.sh set SERPER_API_KEY "your-key"
```

**SEO Commands available:**

| Command | Purpose |
|---------|---------|
| `/keyword-research` | Expand seed keywords with volume, CPC, difficulty |
| `/autocomplete-research` | Mine Google autocomplete for long-tail keywords |
| `/keyword-research-extended` | Full SERP analysis with 17 weakness indicators |
| `/webmaster-keywords` | Get keywords from your Google Search Console |

**Example workflow:**

```text
# Switch to SEO agent
Tab → SEO

# Research keywords
/keyword-research "best project management tools"

# Deep dive on promising keywords
/keyword-research-extended "project management software for small teams"

# Check your own site's performance
/webmaster-keywords https://yoursite.com
```

### Context & Semantic Search

| Service | Auth Method | Setup Command | Purpose |
|---------|-------------|---------------|---------|
| Augment Context Engine | `auggie login` | Opens browser OAuth | Semantic codebase search |
| osgrep | None (local) | `npm i -g osgrep && osgrep setup` | Local semantic search |
| Context7 | None | MCP config only | Library documentation |

**Augment setup**:

```bash
npm install -g @augmentcode/auggie@prerelease
auggie login  # Opens browser
auggie token print  # Verify
```

### Browser Automation

| Service | Requirements | Setup | Purpose |
|---------|--------------|-------|---------|
| Playwright | Node.js | `npx playwright install` | Cross-browser testing |
| Stagehand | OpenAI/Anthropic key | Key already configured | AI browser automation |
| Chrome DevTools | Chrome running | `--remote-debugging-port=9222` | Browser debugging |
| Playwriter | Browser extension | Install from Chrome Web Store | Extension-based automation |

### Personal AI Assistant (Mobile Access)

| Service | Requirements | Setup | Purpose |
|---------|--------------|-------|---------|
| Clawdbot | Node.js >= 22 | `npm install -g clawdbot@latest && clawdbot onboard` | AI via WhatsApp, Telegram, Slack, Discord |

**Clawdbot setup** (recommended for mobile AI access):

```bash
# Install globally
npm install -g clawdbot@latest

# Run onboarding wizard (installs daemon, connects channels)
clawdbot onboard --install-daemon

# Verify
clawdbot doctor
```

Clawdbot lets you interact with AI from your phone via WhatsApp, Telegram, or any messaging platform. The gateway runs locally as a daemon, always available.

**Key features:**
- Multi-channel inbox (WhatsApp, Telegram, Slack, Discord, Signal, iMessage, Teams)
- Voice Wake + Talk Mode (macOS/iOS/Android)
- Skills system compatible with aidevops agents
- Browser control, cron jobs, webhooks

**Docs**: https://docs.clawd.bot

### WordPress

| Service | Requirements | Setup Link | Purpose |
|---------|--------------|------------|---------|
| LocalWP | LocalWP installed | https://localwp.com/releases | Local WordPress dev |
| MainWP | MainWP Dashboard plugin | https://mainwp.com/ | WordPress fleet management |

**MainWP config** (`configs/mainwp-config.json`):

```json
{
  "dashboard_url": "https://your-mainwp-dashboard.com",
  "api_key": "your-api-key"
}
```

### AWS Services

| Service | Env Var(s) | Setup Link | Purpose |
|---------|------------|------------|---------|
| AWS General | `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, `AWS_DEFAULT_REGION` | https://console.aws.amazon.com/iam | AWS services |
| Amazon SES | Same as above + SES permissions | IAM with SES permissions | Email sending |

### Domain Registrars

| Service | Config File | Setup Link | Purpose |
|---------|-------------|------------|---------|
| Spaceship | `configs/spaceship-config.json` | https://www.spaceship.com/ | Domain registration |
| 101domains | `configs/101domains-config.json` | https://www.101domain.com/ | Domain purchasing |

### Password Management

| Service | Config | Setup | Purpose |
|---------|--------|-------|---------|
| Vaultwarden | `configs/vaultwarden-config.json` | Self-hosted Bitwarden | Secrets management |

## Verification Commands

After setting up each service, verify it works:

```bash
# Git platforms
gh auth status
glab auth status

# Hetzner
hcloud server list

# Cloudflare
curl -s -H "Authorization: Bearer $CLOUDFLARE_API_TOKEN" \
  "https://api.cloudflare.com/client/v4/user/tokens/verify" | jq .success

# DataForSEO
curl -s -u "$DATAFORSEO_USERNAME:$DATAFORSEO_PASSWORD" \
  "https://api.dataforseo.com/v3/appendix/user_data" | jq .status_message

# Augment
auggie token print

# All keys overview
~/.aidevops/agents/scripts/list-keys-helper.sh
```

## Credential Storage

All credentials are stored securely:

| Location | Purpose | Permissions |
|----------|---------|-------------|
| `~/.config/aidevops/mcp-env.sh` | Primary credential store | 600 |
| `~/.config/coderabbit/api_key` | CodeRabbit token | 600 |
| `configs/*-config.json` | Service-specific configs | 600, gitignored |

**Add a new credential**:

```bash
~/.aidevops/agents/scripts/setup-local-api-keys.sh set SERVICE_NAME "value"
```

**List all credentials** (names only, never values):

```bash
~/.aidevops/agents/scripts/list-keys-helper.sh
```

## Recommended Setup Order

For new users, suggest this order based on their interests:

### Web Developer

1. GitHub CLI (`gh auth login`)
2. OpenAI API (for AI features)
3. Augment Context Engine (semantic search)
4. Playwright (browser testing)

### DevOps Engineer

1. GitHub/GitLab CLI
2. Hetzner Cloud or preferred hosting
3. Cloudflare (DNS)
4. Coolify or Vercel (deployment)
5. SonarCloud + Codacy (code quality)

### SEO Professional

1. DataForSEO (keyword research)
2. Serper (Google Search API)
3. Google Search Console
4. Outscraper (business data)

### WordPress Developer

1. LocalWP (local development)
2. MainWP (if managing multiple sites)
3. GitHub CLI
4. Hostinger or preferred hosting

### Full Stack

1. All Git CLIs
2. OpenAI + Anthropic
3. Augment Context Engine
4. Hetzner + Cloudflare
5. All code quality tools
6. DataForSEO + Serper
7. Clawdbot (mobile AI access)

### Mobile-First / Always-On

1. Clawdbot (`clawdbot onboard --install-daemon`)
2. OpenAI or Anthropic API key
3. Connect WhatsApp or Telegram channel
4. Optional: Voice Wake for hands-free

## Troubleshooting

### Key not loading

```bash
# Check if mcp-env.sh is sourced
grep "mcp-env.sh" ~/.zshrc ~/.bashrc

# Source manually
source ~/.config/aidevops/mcp-env.sh

# Verify
echo "${OPENAI_API_KEY:0:10}..."
```

### MCP not connecting

```bash
# Check MCP status
opencode mcp list

# Diagnose specific MCP
~/.aidevops/agents/scripts/mcp-diagnose.sh <name>
```

### Permission denied

```bash
# Fix permissions
chmod 600 ~/.config/aidevops/mcp-env.sh
chmod 700 ~/.config/aidevops
```

## Understanding Agents, Subagents, and Commands

aidevops uses a layered system to give your AI assistant the right context at the right time, without wasting tokens on irrelevant information.

### The Three Layers

| Layer | How to Use | Purpose | Example |
|-------|------------|---------|---------|
| **Main Agents** | Tab key in OpenCode | Switch AI persona with focused capabilities | `Build+`, `SEO`, `WordPress` |
| **Subagents** | `@name` mention | Pull in specialized knowledge on demand | `@hetzner`, `@dataforseo`, `@code-standards` |
| **Commands** | `/name` | Execute specific workflows | `/release`, `/feature`, `/keyword-research` |

### Main Agents (Tab to Switch)

Main agents are complete AI personas with their own tools and focus areas. In OpenCode, press **Tab** to switch between them:

| Agent | Focus | Best For |
|-------|-------|----------|
| `Plan+` | Read-only planning | Architecture decisions, research, analysis |
| `Build+` | Full development | Coding, debugging, file changes |
| `SEO` | Search optimization | Keyword research, SERP analysis, GSC |
| `WordPress` | WordPress ecosystem | Theme/plugin dev, MainWP, LocalWP |
| `AI-DevOps` | Framework operations | Setup, troubleshooting, meta-tasks |

**When to switch agents:** Switch when your task changes focus. Planning? Use `Plan+`. Ready to code? Switch to `Build+`. Need SEO analysis? Switch to `SEO`.

### Subagents (@mention)

Subagents provide specialized knowledge without switching your main agent. Use `@name` to pull in context:

```text
@hetzner list all my servers
@code-standards check this function
@dataforseo research keywords for "ai tools"
```

**How it works:** When you mention a subagent, the AI reads that agent's instructions and gains its specialized knowledge - but stays in your current main agent context.

**Common subagents:**

| Category | Subagents |
|----------|-----------|
| Hosting | `@hetzner`, `@cloudflare`, `@coolify`, `@vercel` |
| Git | `@github-cli`, `@gitlab-cli`, `@gitea-cli` |
| Quality | `@code-standards`, `@codacy`, `@coderabbit`, `@snyk` |
| SEO | `@dataforseo`, `@serper`, `@keyword-research` |
| Context | `@augment-context-engine`, `@osgrep`, `@context7` |
| WordPress | `@wp-dev`, `@wp-admin`, `@localwp`, `@mainwp` |

### Commands (/slash)

Commands execute specific workflows with predefined steps:

```text
/feature add-user-auth
/release minor
/keyword-research "best ai tools"
```

**How it works:** Commands invoke a workflow that may use multiple tools and follow a specific process. They're action-oriented.

**When to use what:**

| Situation | Use | Example |
|-----------|-----|---------|
| Need to switch focus entirely | Main agent (Tab) | Tab → `SEO` |
| Need specialized knowledge | Subagent (@) | `@hetzner help me configure` |
| Need to execute a workflow | Command (/) | `/release minor` |
| General conversation | Just talk | "How do I deploy this?" |

### Progressive Context Loading

aidevops uses **progressive disclosure** - agents only load the context they need:

1. **Root AGENTS.md** loads first (minimal, universal rules)
2. **Main agent** loads when selected (focused capabilities)
3. **Subagents** load on @mention (specialized knowledge)
4. **Commands** load workflow steps (action sequences)

This keeps token usage efficient while giving you access to deep expertise when needed.

### Example Session

```text
# Start in Build+ agent (Tab to select)

> I need to add a new API endpoint for user profiles

# AI helps you plan and code...

> @code-standards check my implementation

# AI reads code-standards subagent, reviews your code

> /pr

# AI runs the PR workflow: linting, auditing, standards check

# Later, need to research keywords for the feature...

# Tab → SEO agent

> /keyword-research "user profile api"

# AI runs keyword research with SEO context
```

## Workflow Features

aidevops isn't just about API integrations - it provides powerful workflow enhancements for any project.

### Enable Features in Any Project

```bash
cd ~/your-project
aidevops init                         # Enable all features
aidevops init planning                # Enable only planning
aidevops init planning,git-workflow   # Enable specific features
aidevops features                     # List available features
```

**Available features:** `planning`, `git-workflow`, `code-quality`, `time-tracking`

This creates:

- `.aidevops.json` - Configuration with enabled features
- `.agent` symlink → `~/.aidevops/agents/`
- `TODO.md` - Quick task tracking
- `todo/PLANS.md` - Complex execution plans

### Slash Commands

Once aidevops is configured, these commands are available in OpenCode:

**Planning & Tasks:**

| Command | Purpose |
|---------|---------|
| `/create-prd` | Create Product Requirements Document for complex features |
| `/generate-tasks` | Generate implementation tasks from a PRD |
| `/plan-status` | Check status of plans and TODO.md |
| `/log-time-spent` | Log time spent on a task |

**Development Workflow:**

| Command | Purpose |
|---------|---------|
| `/feature` | Create and develop a feature branch |
| `/bugfix` | Create and resolve a bugfix branch |
| `/hotfix` | Urgent hotfix for critical issues |
| `/context` | Build AI context for complex tasks |

**Quality & Release:**

| Command | Purpose |
|---------|---------|
| `/linters-local` | Run local linting (ShellCheck, secretlint) |
| `/code-audit-remote` | Run remote auditing (CodeRabbit, Codacy, SonarCloud) |
| `/pr` | Unified PR workflow (orchestrates all checks) |
| `/preflight` | Quality checks before release |
| `/release` | Full release workflow (bump, tag, GitHub release) |
| `/changelog` | Update CHANGELOG.md |

**SEO (if configured):**

| Command | Purpose |
|---------|---------|
| `/keyword-research` | Seed keyword expansion |
| `/keyword-research-extended` | Full SERP analysis with weakness detection |

### Time Tracking

Tasks support time estimates and actuals:

```markdown
- [ ] Add user dashboard @marcus #feature ~4h (ai:2h test:1h) started:2025-01-15T10:30Z
```

| Field | Purpose | Example |
|-------|---------|---------|
| `~estimate` | Total time estimate | `~4h`, `~30m` |
| `(breakdown)` | AI/test/read time | `(ai:2h test:1h)` |
| `started:` | When work began | ISO timestamp |
| `actual:` | Actual time spent | `actual:5h30m` |

## Hands-On Playground

The best way to learn aidevops is by doing. Let's create a playground project to experiment with.

### Step 1: Create Playground Repository

```bash
mkdir -p ~/Git/aidevops-playground
cd ~/Git/aidevops-playground
git init
aidevops init
```

### Step 2: Explore What's Possible

Based on your interests (from earlier in onboarding), here are some ideas:

**For Web Developers:**
- "Create a simple landing page with a contact form"
- "Build a REST API with authentication"
- "Set up a React component library"

**For DevOps Engineers:**
- "Create a deployment script for my servers"
- "Build a monitoring dashboard"
- "Automate SSL certificate renewal"

**For SEO Professionals:**
- "Build a keyword tracking spreadsheet"
- "Create a site audit report generator"
- "Automate competitor analysis"

**For WordPress Developers:**
- "Create a custom plugin skeleton"
- "Build a theme starter template"
- "Automate plugin updates across sites"

### Step 3: Try the Full Workflow

Pick a simple idea and experience the complete workflow:

1. **Plan it**: `/create-prd my-first-feature`
2. **Generate tasks**: `/generate-tasks`
3. **Start development**: `/feature my-first-feature`
4. **Build it**: Work with the AI to implement
5. **Quality check**: `/linters-local` then `/pr`
6. **Release it**: `/release patch`

### Step 4: Personalized Project Ideas

If you're not sure what to build, tell me:
- What problems do you face regularly?
- What repetitive tasks do you wish were automated?
- What tools do you wish existed?

I'll suggest a small project tailored to your needs that we can build together in the playground.

## Next Steps After Setup

Once services are configured:

1. **Create your playground**: `mkdir ~/Git/aidevops-playground && cd ~/Git/aidevops-playground && git init && aidevops init`
2. **Test a simple task**: "List my GitHub repos" or "Check my Hetzner servers"
3. **Explore agents**: Type `@` to see available agents
4. **Try a workflow**: `/create-prd` → `/generate-tasks` → `/feature` → build → `/release`
5. **Read the docs**: `@aidevops` for framework guidance
