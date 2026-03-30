---
name: onboarding
description: Interactive onboarding wizard - discover services, check credentials, configure integrations
mode: subagent
subagents: [setup, troubleshooting, api-key-setup, list-keys, mcp-integrations, services, service-links, general, explore]
---

# Onboarding Wizard

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Command**: `/onboarding` or `@onboarding`
- **Script**: `~/.aidevops/agents/scripts/onboarding-helper.sh`
- **Settings**: `~/.config/aidevops/settings.json` — `settings-helper.sh list|set|reset`
- **Credentials**: `~/.config/aidevops/credentials.sh` (600 perms) | `configs/*-config.json` (600, gitignored) | `~/.config/coderabbit/api_key` (600)
- **Set keys**: `setup-local-api-keys.sh set NAME "value"` | **List**: `list-keys-helper.sh`

**OpenCode setup rule**: NEVER manually write `opencode.json`. Run `generate-opencode-agents.sh`.
If OpenCode fails to start: `mv ~/.config/opencode/opencode.json{,.broken}` and re-run.
If hand-fixing JSON: `"tools": {}` (not `[]`), include `"type": "local"` or `"type": "remote"`, and use `"tool_name": true` (not objects). Verify with `jq . ~/.config/opencode/opencode.json > /dev/null`.

<!-- AI-CONTEXT-END -->

## Welcome Flow

1. **Introduce capabilities** (only if wanted): orchestration; infrastructure (Hetzner, Hostinger, Cloudron, Coolify); domains/DNS (Cloudflare, Spaceship, 101domains); Git (GitHub, GitLab, Gitea); code quality (SonarCloud, Codacy, CodeRabbit, Snyk); WordPress (LocalWP, MainWP); SEO (DataForSEO, Serper, GSC); browser automation (Playwright, Stagehand); context tools (Augment, Context7, Repomix).
2. **Capture concept familiarity** (Git, terminal, API keys, hosting, SEO, AI assistants):
   - `onboarding-helper.sh save-concepts 'git,terminal'`
3. **Capture work type** (web-dev, devops, seo, wordpress, other):
   - `onboarding-helper.sh save-work-type devops`
4. **Show current status**:
   - `onboarding-helper.sh status`
5. **Guide service-by-service setup**:
   - purpose → credential source → setup command → verification

## Service Catalog

| Category | Service | Env Var / Auth | Setup Link |
|----------|---------|----------------|------------|
| AI | OpenAI | `OPENAI_API_KEY` | https://platform.openai.com/api-keys |
| AI | Anthropic | `ANTHROPIC_API_KEY` | https://console.anthropic.com/settings/keys |
| Git | GitHub | `gh auth login` | — |
| Git | GitLab | `glab auth login` | — |
| Git | Gitea | `tea login add` | — |
| Hosting | Hetzner Cloud | `HCLOUD_TOKEN_*` | https://console.hetzner.cloud/ → Security → API Tokens |
| Hosting | Cloudflare | `CLOUDFLARE_API_TOKEN` | https://dash.cloudflare.com/profile/api-tokens |
| Hosting | Coolify | `COOLIFY_API_TOKEN` | Your Coolify instance → Settings → API |
| Hosting | Vercel | `VERCEL_TOKEN` | https://vercel.com/account/tokens |
| Quality | SonarCloud | `SONAR_TOKEN` | https://sonarcloud.io/account/security |
| Quality | Codacy | `CODACY_PROJECT_TOKEN` | https://app.codacy.com → Project → Settings |
| Quality | CodeRabbit | `CODERABBIT_API_KEY` | https://app.coderabbit.ai/settings |
| Quality | Snyk | `SNYK_TOKEN` | https://app.snyk.io/account |
| SEO | DataForSEO | `DATAFORSEO_USERNAME`, `DATAFORSEO_PASSWORD` | https://app.dataforseo.com/api-access |
| SEO | Serper | `SERPER_API_KEY` | https://serper.dev/api-key |
| SEO | Outscraper | `OUTSCRAPER_API_KEY` | https://outscraper.com/dashboard |
| SEO | Google Search Console | OAuth via MCP | https://search.google.com/search-console |
| Context | Augment | `npm install -g @augmentcode/auggie@prerelease && auggie login` | — |
| Context | Context7 | MCP config only | — |
| Browser | Playwright | `npx playwright install` | — |
| Browser | Stagehand | OpenAI/Anthropic key required | — |
| Browser | Chrome DevTools | `--remote-debugging-port=9222` | — |
| Containers | OrbStack | `brew install orbstack` — docs: `@orbstack` | — |
| Containers | Tailscale | `brew install tailscale` — docs: `@tailscale` | — |
| WordPress | LocalWP | — | https://localwp.com/releases |
| WordPress | MainWP | — | https://mainwp.com/ |
| Cloud | AWS | `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, `AWS_DEFAULT_REGION` | — |
| Domains | Spaceship | `configs/spaceship-config.json` | — |
| Domains | 101domains | `configs/101domains-config.json` | — |
| Secrets | Vaultwarden | `configs/vaultwarden-config.json` | — |

CodeRabbit key file: `mkdir -p ~/.config/coderabbit && chmod 700 ~/.config/coderabbit` then write key to `~/.config/coderabbit/api_key` and `chmod 600 ~/.config/coderabbit/api_key`.

SEO commands: `/keyword-research`, `/autocomplete-research`, `/keyword-research-extended`, `/webmaster-keywords`

### Personal AI Assistant (OpenClaw)

```bash
curl -fsSL https://openclaw.ai/install.sh | bash && openclaw onboard --install-daemon
```

Tiers: (1) Native local, (2) OrbStack container, (3) Remote VPS with Tailscale. After setup: `openclaw security audit --deep`. Docs: `@openclaw`

## Verification

Run what applies to the selected stack:

```bash
gh auth status && glab auth status
hcloud server list
curl -s -H "Authorization: Bearer $CLOUDFLARE_API_TOKEN" "https://api.cloudflare.com/client/v4/user/tokens/verify" | jq .success
curl -s -u "$DATAFORSEO_USERNAME:$DATAFORSEO_PASSWORD" "https://api.dataforseo.com/v3/appendix/user_data" | jq .status_message
auggie token print && openclaw doctor && tailscale status && orb status
~/.aidevops/agents/scripts/list-keys-helper.sh
```

## Troubleshooting

```bash
# Key not loading
grep "credentials.sh" ~/.zshrc ~/.bashrc && source ~/.config/aidevops/credentials.sh

# MCP not connecting
opencode mcp list && ~/.aidevops/agents/scripts/mcp-diagnose.sh <name>

# Permission denied
chmod 600 ~/.config/aidevops/credentials.sh && chmod 700 ~/.config/aidevops
```

## Agents & Commands

- **Agent layers**: Main agents (Tab key) → subagents (`@name`) → commands (`/name`)
- **Main agents**: `Build+`, `SEO`, `WordPress`
- **Common subagents**: `@hetzner`, `@cloudflare`, `@coolify`, `@vercel`, `@github-cli`, `@dataforseo`, `@augment-context-engine`, `@code-standards`, `@wp-dev`
- **Project init**: `cd ~/your-project && aidevops init`
- **Key commands**: `/create-prd`, `/generate-tasks`, `/feature`, `/bugfix`, `/hotfix`, `/pr`, `/preflight`, `/release`, `/linters-local`, `/keyword-research`

## Repo Sync & Orchestration

```bash
# Configure git parent directories for repo sync
jq --argjson dirs '["~/Git", "~/Projects"]' '. + {git_parent_dirs: $dirs}' \
  ~/.config/aidevops/repos.json > /tmp/repos.json && mv /tmp/repos.json ~/.config/aidevops/repos.json

aidevops repo-sync enable

# Enable autonomous orchestration
~/.aidevops/agents/scripts/onboarding-helper.sh save-orchestration true

# See scripts/commands/runners.md for launchd (macOS) and cron (Linux) setup
```

Settings: `settings-helper.sh list` to inspect sections. Cost note: subscription plans (Claude Max/Pro, OpenAI Pro/Plus) are usually cheaper than API for sustained use.

## Next Steps After Setup

1. **Create playground**: `mkdir ~/Git/aidevops-playground && cd ~/Git/aidevops-playground && git init && aidevops init`
2. **Smoke test**: "List my GitHub repos" or "Check my Hetzner servers"
3. **Run one flow**: `/create-prd` → `/generate-tasks` → `/feature` → build → `/release`
4. **Enable orchestration/autonomy**: `scripts/commands/runners.md` then add `#auto-dispatch` to a TODO.md task
