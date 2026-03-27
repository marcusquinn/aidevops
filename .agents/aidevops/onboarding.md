---
name: onboarding
description: Interactive onboarding wizard - discover services, check credentials, configure integrations
mode: subagent
subagents: [setup, troubleshooting, api-key-setup, list-keys, mcp-integrations, services, service-links, general, explore]
---

# Onboarding Wizard - aidevops Configuration

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Command**: `/onboarding` or `@onboarding`
- **Script**: `~/.aidevops/agents/scripts/onboarding-helper.sh`
- **Settings**: `~/.config/aidevops/settings.json` — `settings-helper.sh list|set|reset`
- **Purpose**: Interactive wizard to discover, configure, and verify aidevops integrations

**CRITICAL - OpenCode Setup**: NEVER manually write `opencode.json`. Always run:

```bash
~/.aidevops/agents/scripts/generate-opencode-agents.sh
```

If OpenCode won't start: `mv ~/.config/opencode/opencode.json ~/.config/opencode/opencode.json.broken && ~/.aidevops/agents/scripts/generate-opencode-agents.sh`

**OpenCode JSON errors**:

| Error | Wrong | Correct |
|-------|-------|---------|
| `expected record, received array` for tools | `"tools": []` | `"tools": {}` |
| `Invalid input mcp.*` | Missing `type` field | Add `"type": "local"` or `"type": "remote"` |
| `expected boolean, received object` for tools | `"tool_name": {...}` | `"tool_name": true` |

Verify: `jq . ~/.config/opencode/opencode.json > /dev/null && echo "Valid JSON"`

<!-- AI-CONTEXT-END -->

## Welcome Flow

1. **Introduction** (new users) — ask if they want an explanation. Capabilities: Autonomous Orchestration (supervisor dispatches AI workers, merges PRs), Infrastructure (Hetzner, Hostinger, Cloudron, Coolify), Domains/DNS (Cloudflare, Spaceship, 101domains), Git (GitHub, GitLab, Gitea), Code Quality (SonarCloud, Codacy, CodeRabbit, Snyk), WordPress (LocalWP, MainWP), SEO (DataForSEO, Serper, GSC), Browser Automation (Playwright, Stagehand), Context (Augment, Context7, Repomix)
2. **Concept familiarity** — ask which they know (Git, Terminal, API keys, Hosting, SEO, AI assistants). Offer 3-4 sentence explanations. Save: `onboarding-helper.sh save-concepts 'git,terminal'`
3. **Work type** — ask what they do (web dev, DevOps, SEO, WordPress, other). Save: `onboarding-helper.sh save-work-type devops`
4. **Current status** — `onboarding-helper.sh status` — show configured vs needs-setup
5. **Guide setup** — for each service: explain purpose, link to credentials, setup command, verification

## Service Catalog

### AI Providers

| Service | Env Var | Setup Link | Purpose |
|---------|---------|------------|---------|
| OpenAI | `OPENAI_API_KEY` | https://platform.openai.com/api-keys | GPT models, Stagehand |
| Anthropic | `ANTHROPIC_API_KEY` | https://console.anthropic.com/settings/keys | Claude models |

Set keys: `~/.aidevops/agents/scripts/setup-local-api-keys.sh set OPENAI_API_KEY "sk-..."`

### Git Platforms

| Service | Auth | Purpose |
|---------|------|---------|
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

CodeRabbit key: `mkdir -p ~/.config/coderabbit && echo "key" > ~/.config/coderabbit/api_key && chmod 600 ~/.config/coderabbit/api_key`

### SEO & Research

| Service | Env Var(s) | Setup Link | Purpose |
|---------|------------|------------|---------|
| DataForSEO | `DATAFORSEO_USERNAME`, `DATAFORSEO_PASSWORD` | https://app.dataforseo.com/api-access | SERP, keywords, backlinks |
| Serper | `SERPER_API_KEY` | https://serper.dev/api-key | Google Search API |
| Outscraper | `OUTSCRAPER_API_KEY` | https://outscraper.com/dashboard | Business data extraction |
| Google Search Console | OAuth via MCP | https://search.google.com/search-console | Site search performance |

SEO commands: `/keyword-research`, `/autocomplete-research`, `/keyword-research-extended`, `/webmaster-keywords`

### Context, Browser & Containers

| Tool | Setup | Purpose |
|------|-------|---------|
| Augment | `npm install -g @augmentcode/auggie@prerelease && auggie login` | Semantic codebase search |
| Context7 | MCP config only | Library documentation |
| Playwright | `npx playwright install` (Node.js) | Cross-browser testing |
| Stagehand | OpenAI/Anthropic key required | AI browser automation |
| Chrome DevTools | `--remote-debugging-port=9222` | Browser debugging |
| OrbStack | `brew install orbstack` — docs: `@orbstack` | Docker + Linux VMs (macOS) |
| Tailscale | `brew install tailscale` — docs: `@tailscale` | Zero-config mesh VPN |

### Personal AI Assistant (OpenClaw)

```bash
curl -fsSL https://openclaw.ai/install.sh | bash && openclaw onboard --install-daemon
```

Tiers: (1) Native local, (2) OrbStack container, (3) Remote VPS with Tailscale. After setup: `openclaw security audit --deep`. Docs: `@openclaw`

### WordPress & Other Services

**WordPress**: LocalWP (https://localwp.com/releases) — local dev | MainWP (https://mainwp.com/) — fleet management

**AWS**: `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, `AWS_DEFAULT_REGION`

**Domains/Secrets**: `configs/spaceship-config.json` (Spaceship), `configs/101domains-config.json` (101domains), `configs/vaultwarden-config.json` (Vaultwarden)

## Verification Commands

```bash
gh auth status && glab auth status
hcloud server list
curl -s -H "Authorization: Bearer $CLOUDFLARE_API_TOKEN" "https://api.cloudflare.com/client/v4/user/tokens/verify" | jq .success
curl -s -u "$DATAFORSEO_USERNAME:$DATAFORSEO_PASSWORD" "https://api.dataforseo.com/v3/appendix/user_data" | jq .status_message
auggie token print && openclaw doctor && tailscale status && orb status
~/.aidevops/agents/scripts/list-keys-helper.sh
```

## Credential Storage

| Location | Purpose | Permissions |
|----------|---------|-------------|
| `~/.config/aidevops/credentials.sh` | Primary credential store | 600 |
| `~/.config/coderabbit/api_key` | CodeRabbit token | 600 |
| `configs/*-config.json` | Service-specific configs | 600, gitignored |

Set: `setup-local-api-keys.sh set NAME "value"` | List (names only): `list-keys-helper.sh`

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
grep "credentials.sh" ~/.zshrc ~/.bashrc && source ~/.config/aidevops/credentials.sh

# MCP not connecting
opencode mcp list && ~/.aidevops/agents/scripts/mcp-diagnose.sh <name>

# Permission denied
chmod 600 ~/.config/aidevops/credentials.sh && chmod 700 ~/.config/aidevops
```

## Agents, Commands & Workflow

**Agent layers**: Main agents (Tab key) → Subagents (`@name`) → Commands (`/name`). Root AGENTS.md → Main agent → Subagents on @mention → Commands on /invoke.

**Main agents**: `Build+` (coding/DevOps), `SEO` (search optimization), `WordPress` (WP ecosystem)

**Common subagents**: `@hetzner`, `@cloudflare`, `@coolify`, `@vercel`, `@github-cli`, `@dataforseo`, `@augment-context-engine`, `@code-standards`, `@wp-dev`

**Project init**: `cd ~/your-project && aidevops init` — creates `.aidevops.json`, `.agent` symlink, `TODO.md`, `todo/PLANS.md`

**Key commands**: `/create-prd`, `/generate-tasks`, `/feature`, `/bugfix`, `/hotfix`, `/pr`, `/preflight`, `/release`, `/linters-local`, `/keyword-research`

## Repo Sync, Settings & Orchestration

```bash
# Repo sync — configure git parent directories
jq --argjson dirs '["~/Git", "~/Projects"]' '. + {git_parent_dirs: $dirs}' \
  ~/.config/aidevops/repos.json > /tmp/repos.json && mv /tmp/repos.json ~/.config/aidevops/repos.json
aidevops repo-sync enable

# Settings
~/.aidevops/agents/scripts/settings-helper.sh set orchestration.enabled true

# Enable autonomous orchestration (supervisor pulse, auto-pickup, cross-repo visibility)
~/.aidevops/agents/scripts/onboarding-helper.sh save-orchestration true
# See scripts/commands/runners.md for launchd (macOS) and cron (Linux) setup
```

Settings sections: `user`, `orchestration`, `repo_sync`, `quality`, `model_routing`, `notifications`, `ui`.

Cost note: subscription plans (Claude Max/Pro, OpenAI Pro/Plus) are significantly cheaper than API for sustained use. Reserve API keys for testing.

## Next Steps After Setup

1. **Create playground**: `mkdir ~/Git/aidevops-playground && cd ~/Git/aidevops-playground && git init && aidevops init`
2. **Test**: "List my GitHub repos" or "Check my Hetzner servers"
3. **Enable orchestration**: see `scripts/commands/runners.md`
4. **Try a workflow**: `/create-prd` → `/generate-tasks` → `/feature` → build → `/release`
5. **Try autonomous mode**: Add `#auto-dispatch` to a TODO.md task
6. **Read the docs**: `@aidevops` for framework guidance
