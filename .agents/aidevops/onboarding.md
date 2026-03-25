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
- **Settings**: `~/.config/aidevops/settings.json` (canonical config file)
- **Settings helper**: `~/.aidevops/agents/scripts/settings-helper.sh`
- **Purpose**: Interactive wizard to discover, configure, and verify aidevops integrations

**CRITICAL - OpenCode Setup**: NEVER manually write `opencode.json`. Always run:

```bash
~/.aidevops/agents/scripts/generate-opencode-agents.sh
```

**Settings file**: All onboarding choices are persisted to `~/.config/aidevops/settings.json`. Created with documented defaults on first run.

**Workflow**:
1. Welcome & explain aidevops capabilities
2. Ask about user's work/interests for personalized suggestions
3. **Save choices to settings.json** (work type, concepts, orchestration preference)
4. Show current setup status (configured vs needs setup)
5. Guide through setting up selected services
6. Verify configurations work

<!-- AI-CONTEXT-END -->

## Welcome Flow

### Step 1: Introduction (if new user)

Ask if the user would like an explanation of what aidevops does. If yes:

```text
aidevops gives your AI assistant superpowers for DevOps and infrastructure management.

Recommended tool: OpenCode (https://opencode.ai/) — all features are designed and tested for OpenCode first.

Capabilities:
- Autonomous Orchestration: Supervisor dispatches AI workers, merges PRs, tracks tasks across repos
- Infrastructure: Manage servers across Hetzner, Hostinger, Cloudron, Coolify
- Domains & DNS: Cloudflare, Spaceship, 101domains
- Git Platforms: GitHub, GitLab, Gitea with full CLI integration
- Code Quality: SonarCloud, Codacy, CodeRabbit, Snyk, Qlty
- WordPress: LocalWP development, MainWP fleet management
- SEO: Keyword research, SERP analysis, Google Search Console
- Browser Automation: Playwright, Stagehand, Chrome DevTools
- Context Tools: Augment, Context7, Repomix
```

### Step 2: Check Concept Familiarity

Ask which concepts they know (Git, Terminal, API keys, Hosting, SEO, AI assistants, or none). Offer brief explanations for unfamiliar ones — keep explanations to 3-4 sentences each. Save results:

```bash
~/.aidevops/agents/scripts/onboarding-helper.sh save-concepts 'git,terminal,api-keys'
```

### Step 3: Understand User's Work

Ask what they do (web dev, DevOps, SEO, WordPress, other). Save the choice:

```bash
~/.aidevops/agents/scripts/onboarding-helper.sh save-work-type devops
```

### Step 4: Show Current Status

```bash
~/.aidevops/agents/scripts/onboarding-helper.sh status
```

Display configured vs needs-setup services clearly.

### Step 5: Guide Setup

For each service: explain purpose, link to get credentials, setup command, verification.

## Service Catalog

### AI Providers

| Service | Env Var | Setup Link | Purpose |
|---------|---------|------------|---------|
| OpenAI | `OPENAI_API_KEY` | https://platform.openai.com/api-keys | GPT models, Stagehand |
| Anthropic | `ANTHROPIC_API_KEY` | https://console.anthropic.com/settings/keys | Claude models |

```bash
~/.aidevops/agents/scripts/setup-local-api-keys.sh set OPENAI_API_KEY "sk-..."
```

### Git Platforms

| Service | Auth Method | Purpose |
|---------|-------------|---------|
| GitHub | `gh auth login` | Repos, PRs, Actions |
| GitLab | `glab auth login` | Repos, MRs, Pipelines |
| Gitea | `tea login add` | Self-hosted Git |

### Hosting Providers

| Service | Env Var(s) | Setup Link | Purpose |
|---------|------------|------------|---------|
| Hetzner Cloud | `HCLOUD_TOKEN_*` | https://console.hetzner.cloud/ → Security → API Tokens | VPS, networking |
| Cloudflare | `CLOUDFLARE_API_TOKEN` | https://dash.cloudflare.com/profile/api-tokens | DNS, CDN, security |
| Coolify | `COOLIFY_API_TOKEN` | Your Coolify instance → Settings → API | Self-hosted PaaS |
| Vercel | `VERCEL_TOKEN` | https://vercel.com/account/tokens | Serverless deployment |

### Code Quality

| Service | Env Var | Setup Link | Purpose |
|---------|---------|------------|---------|
| SonarCloud | `SONAR_TOKEN` | https://sonarcloud.io/account/security | Security analysis |
| Codacy | `CODACY_PROJECT_TOKEN` | https://app.codacy.com → Project → Settings | Code quality |
| CodeRabbit | `CODERABBIT_API_KEY` | https://app.coderabbit.ai/settings | AI code review |
| Snyk | `SNYK_TOKEN` | https://app.snyk.io/account | Vulnerability scanning |

CodeRabbit key storage: `mkdir -p ~/.config/coderabbit && echo "key" > ~/.config/coderabbit/api_key && chmod 600 ~/.config/coderabbit/api_key`

### SEO & Research

| Service | Env Var(s) | Setup Link | Purpose |
|---------|------------|------------|---------|
| DataForSEO | `DATAFORSEO_USERNAME`, `DATAFORSEO_PASSWORD` | https://app.dataforseo.com/api-access | SERP, keywords, backlinks |
| Serper | `SERPER_API_KEY` | https://serper.dev/api-key | Google Search API |
| Outscraper | `OUTSCRAPER_API_KEY` | https://outscraper.com/dashboard | Business data extraction |
| Google Search Console | OAuth via MCP | https://search.google.com/search-console | Site search performance |

SEO commands: `/keyword-research`, `/autocomplete-research`, `/keyword-research-extended`, `/webmaster-keywords`

### Context & Semantic Search

| Service | Auth Method | Purpose |
|---------|-------------|---------|
| Augment Context Engine | `auggie login` | Semantic codebase search |
| Context7 | None (MCP config) | Library documentation |

```bash
npm install -g @augmentcode/auggie@prerelease && auggie login
```

### Browser Automation

| Service | Requirements | Purpose |
|---------|--------------|---------|
| Playwright | Node.js | Cross-browser testing (`npx playwright install`) |
| Stagehand | OpenAI/Anthropic key | AI browser automation |
| Chrome DevTools | Chrome running | Browser debugging (`--remote-debugging-port=9222`) |

### Containers & Networking

| Service | Setup | Purpose |
|---------|-------|---------|
| OrbStack | `brew install orbstack` | Docker + Linux VMs (macOS) |
| Tailscale | `brew install tailscale` | Zero-config mesh VPN |

Docs: `@orbstack`, `@tailscale`

### Personal AI Assistant (OpenClaw)

```bash
curl -fsSL https://openclaw.ai/install.sh | bash && openclaw onboard --install-daemon
```

Deployment tiers: (1) Native local, (2) OrbStack container, (3) Remote VPS with Tailscale.
After setup: `openclaw security audit --deep`
Full docs: `@openclaw` or `tools/ai-assistants/openclaw.md`

### WordPress

| Service | Setup Link | Purpose |
|---------|------------|---------|
| LocalWP | https://localwp.com/releases | Local WordPress dev |
| MainWP | https://mainwp.com/ | WordPress fleet management |

### AWS & Other Services

| Service | Env Var(s) | Purpose |
|---------|------------|---------|
| AWS | `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, `AWS_DEFAULT_REGION` | AWS services |
| Spaceship | `configs/spaceship-config.json` | Domain registration |
| 101domains | `configs/101domains-config.json` | Domain purchasing |
| Vaultwarden | `configs/vaultwarden-config.json` | Secrets management |

## Verification Commands

```bash
gh auth status && glab auth status
hcloud server list
curl -s -H "Authorization: Bearer $CLOUDFLARE_API_TOKEN" "https://api.cloudflare.com/client/v4/user/tokens/verify" | jq .success
curl -s -u "$DATAFORSEO_USERNAME:$DATAFORSEO_PASSWORD" "https://api.dataforseo.com/v3/appendix/user_data" | jq .status_message
auggie token print
openclaw doctor
tailscale status
orb status
~/.aidevops/agents/scripts/list-keys-helper.sh
```

## Credential Storage

| Location | Purpose | Permissions |
|----------|---------|-------------|
| `~/.config/aidevops/credentials.sh` | Primary credential store | 600 |
| `~/.config/coderabbit/api_key` | CodeRabbit token | 600 |
| `configs/*-config.json` | Service-specific configs | 600, gitignored |

```bash
~/.aidevops/agents/scripts/setup-local-api-keys.sh set SERVICE_NAME "value"
~/.aidevops/agents/scripts/list-keys-helper.sh  # names only, never values
```

## Recommended Setup Order

| Profile | Priority order |
|---------|---------------|
| Web Developer | GitHub CLI → OpenAI → Augment → Playwright |
| DevOps Engineer | GitHub/GitLab CLI → Hetzner → Cloudflare → Tailscale → Coolify → OrbStack → SonarCloud/Codacy → Supervisor pulse |
| SEO Professional | DataForSEO → Serper → Google Search Console → Outscraper |
| WordPress Developer | LocalWP → MainWP → GitHub CLI → Hostinger |
| Full Stack | All Git CLIs → OpenAI/Anthropic → Augment → Hetzner/Cloudflare → Tailscale → OrbStack → Code quality → Supervisor pulse → DataForSEO → OpenClaw |
| Mobile-First | OpenClaw → OpenAI/Anthropic → Tailscale → WhatsApp/Telegram channel → `openclaw security audit --fix` |

## Troubleshooting

```bash
# Key not loading
grep "credentials.sh" ~/.zshrc ~/.bashrc
source ~/.config/aidevops/credentials.sh

# MCP not connecting
opencode mcp list
~/.aidevops/agents/scripts/mcp-diagnose.sh <name>

# Permission denied
chmod 600 ~/.config/aidevops/credentials.sh && chmod 700 ~/.config/aidevops
```

## OpenCode Configuration

**CRITICAL**: NEVER manually write `opencode.json`. Always use the generator:

```bash
~/.aidevops/agents/scripts/generate-opencode-agents.sh
```

| Error | Wrong | Correct |
|-------|-------|---------|
| `expected record, received array` for tools | `"tools": []` | `"tools": {}` |
| `Invalid input mcp.*` | Missing `type` field | Add `"type": "local"` or `"type": "remote"` |
| `expected boolean, received object` for tools | `"tool_name": {...}` | `"tool_name": true` |

If OpenCode won't start: `mv ~/.config/opencode/opencode.json ~/.config/opencode/opencode.json.broken && ~/.aidevops/agents/scripts/generate-opencode-agents.sh`

Verify: `jq . ~/.config/opencode/opencode.json > /dev/null && echo "Valid JSON"`

## Understanding Agents, Subagents, and Commands

| Layer | How to Use | Purpose |
|-------|------------|---------|
| **Main Agents** | Tab key in OpenCode | Switch AI persona with focused capabilities |
| **Subagents** | `@name` mention | Pull in specialized knowledge on demand |
| **Commands** | `/name` | Execute specific workflows |

**Main agents**: `Build+` (coding/DevOps), `SEO` (search optimization), `WordPress` (WP ecosystem)

**Common subagents**: `@hetzner`, `@cloudflare`, `@coolify`, `@vercel`, `@github-cli`, `@dataforseo`, `@augment-context-engine`, `@code-standards`, `@wp-dev`

**Progressive context loading**: Root AGENTS.md → Main agent → Subagents on @mention → Commands on /invoke. Keeps token usage efficient.

## Workflow Features

```bash
cd ~/your-project
aidevops init                         # Enable all features
aidevops init planning,git-workflow   # Enable specific features
aidevops features                     # List available features
```

Creates: `.aidevops.json`, `.agent` symlink, `TODO.md`, `todo/PLANS.md`

**Key commands**: `/create-prd`, `/generate-tasks`, `/feature`, `/bugfix`, `/hotfix`, `/pr`, `/preflight`, `/release`, `/linters-local`, `/keyword-research`

## Repo Sync Configuration

```bash
# Configure git parent directories for daily repo sync
jq --argjson dirs '["~/Git", "~/Projects"]' \
  '. + {git_parent_dirs: $dirs}' \
  ~/.config/aidevops/repos.json > /tmp/repos.json && mv /tmp/repos.json ~/.config/aidevops/repos.json
aidevops repo-sync enable
```

## Autonomous Orchestration (Optional)

Features: supervisor pulse (every 2 min), auto-pickup, cross-repo visibility, strategic review (every 4h), model routing, budget tracking, session miner, circuit breaker.

Cost: subscription plans (Claude Max/Pro, OpenAI Pro/Plus) are significantly cheaper than API for sustained use. Reserve API keys for testing.

```bash
# Enable
~/.aidevops/agents/scripts/onboarding-helper.sh save-orchestration true
# See scripts/commands/runners.md for launchd (macOS) and cron (Linux) setup
```

## Settings File

```bash
~/.aidevops/agents/scripts/settings-helper.sh list
~/.aidevops/agents/scripts/settings-helper.sh set orchestration.enabled true
~/.aidevops/agents/scripts/settings-helper.sh set user.work_type devops
~/.aidevops/agents/scripts/settings-helper.sh reset
```

Settings sections: `user`, `orchestration`, `repo_sync`, `quality`, `model_routing`, `notifications`, `ui`.

## Next Steps After Setup

1. **Create playground**: `mkdir ~/Git/aidevops-playground && cd ~/Git/aidevops-playground && git init && aidevops init`
2. **Test**: "List my GitHub repos" or "Check my Hetzner servers"
3. **Enable orchestration**: see `scripts/commands/runners.md`
4. **Explore agents**: Type `@` to see available agents
5. **Try a workflow**: `/create-prd` → `/generate-tasks` → `/feature` → build → `/release`
6. **Try autonomous mode**: Add `#auto-dispatch` to a TODO.md task
7. **Read the docs**: `@aidevops` for framework guidance
