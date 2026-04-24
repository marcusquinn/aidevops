---
name: onboarding
description: Interactive onboarding wizard - discover services, check credentials, configure integrations
mode: subagent
subagents: [setup, troubleshooting, api-key-setup, list-keys, mcp-integrations, services, service-links, general, explore]
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Onboarding Wizard

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Command**: `/onboarding` or `@onboarding`
- **Script**: `~/.aidevops/agents/scripts/onboarding-helper.sh`
- **Settings**: `~/.config/aidevops/settings.json` — `settings-helper.sh list|set|reset`
- **Credentials**: `~/.config/aidevops/credentials.sh` (600 perms) | `configs/*-config.json` (600, gitignored) | `~/.config/coderabbit/api_key` (600)
- **Set keys**: `setup-local-api-keys.sh set NAME "value"` | **List**: `list-keys-helper.sh`

**OpenCode setup**: NEVER manually write `opencode.json` — run `generate-opencode-agents.sh`. Broken? `mv ~/.config/opencode/opencode.json{,.broken}` and re-run.
Hand-fix: `"tools": {}` (not `[]`), `"type": "local"|"remote"`, `"tool_name": true` (not objects). Verify: `jq . ~/.config/opencode/opencode.json > /dev/null`.

<!-- AI-CONTEXT-END -->

## Welcome Flow

1. **Introduce capabilities** (if wanted) — see Service Catalog below for full list
2. **Capture concept familiarity** (Git, terminal, API keys, hosting, SEO, AI assistants): `onboarding-helper.sh save-concepts 'git,terminal'`
3. **Capture work type** (web-dev, devops, seo, wordpress, other): `onboarding-helper.sh save-work-type devops`
4. **Show status**: `onboarding-helper.sh status`
5. **Guide service-by-service setup**: purpose → credential source → setup command → verification
6. **Per-repo platform setup**: after `gh auth login` succeeds, mention `/setup-git` for per-repo secrets (SYNC_PAT for issue-sync, etc.) — see "Scope" note below.

## Scope: Per-Account vs Per-Repo

`/onboarding` (this wizard) handles **per-account** setup — credentials and tooling that apply globally to a user or workstation:

- Auth tokens stored in `~/.config/aidevops/credentials.sh` or `gopass` (one set of values, used everywhere)
- Platform CLI logins: `gh auth login`, `glab auth login`, `tea login` (one auth per platform per account)
- AI assistant API keys, hosting tokens, SEO service credentials

`/setup-git` handles **per-repo** platform configuration — secrets that must be set on each individual remote repo:

- `SYNC_PAT` (GitHub Actions secret used by `issue-sync.yml` to push TODO.md auto-completion past branch protection)
- Future: GitLab CI variables, Gitea Actions secrets, Bitbucket Pipelines variables — same model, different platform UIs

The two workflows compose: `/onboarding` first (you need `gh` to be authenticated before any per-repo helper can run), `/setup-git` second (run when new repos are registered or when SYNC_PAT advisories appear in the session greeting toast).

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

CodeRabbit key setup (single command): `read -rsp "CodeRabbit API key: " CODERABBIT_API_KEY && echo && mkdir -p ~/.config/coderabbit && chmod 700 ~/.config/coderabbit && printf '%s\n' "$CODERABBIT_API_KEY" > ~/.config/coderabbit/api_key && chmod 600 ~/.config/coderabbit/api_key && unset CODERABBIT_API_KEY`

SEO: `/keyword-research`, `/autocomplete-research`, `/keyword-research-extended`, `/webmaster-keywords`

### OpenClaw (Personal AI Assistant)

```bash
curl -fsSL https://openclaw.ai/install.sh | bash && openclaw onboard --install-daemon
# Tiers: (1) Native local, (2) OrbStack container, (3) Remote VPS + Tailscale
# Post-setup: openclaw security audit --deep | Docs: @openclaw
```

## Verification

```bash
# Run what applies to the selected stack
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

- **Layers**: Main agents (Tab) → subagents (`@name`) → commands (`/name`)
- **Main**: `Build+`, `SEO`, `WordPress` | **Init**: `cd ~/your-project && aidevops init`
- **Subagents**: `@hetzner`, `@cloudflare`, `@coolify`, `@vercel`, `@github-cli`, `@dataforseo`, `@augment-context-engine`, `@code-standards`, `@wp-dev`
- **Commands**: `/create-prd`, `/generate-tasks`, `/feature`, `/bugfix`, `/hotfix`, `/pr`, `/preflight`, `/release`, `/linters-local`, `/keyword-research`

## Repo Sync & Orchestration

```bash
# Configure git parent directories for repo sync (creates repos.json if missing)
mkdir -p ~/.config/aidevops && { [ -s ~/.config/aidevops/repos.json ] || echo '{}' > ~/.config/aidevops/repos.json; } && \
  tmp_file="$(mktemp "${TMPDIR:-/tmp}/repos.XXXXXX")" && \
  jq --argjson dirs '["~/Git", "~/Projects"]' '. + {git_parent_dirs: $dirs}' \
  ~/.config/aidevops/repos.json > "$tmp_file" && mv "$tmp_file" ~/.config/aidevops/repos.json
aidevops repo-sync enable
aidevops config set orchestration.supervisor_pulse true && ./setup.sh  # Enable autonomous orchestration
# Runners: see scripts/commands/runners.md (launchd/cron)
```

Settings: `settings-helper.sh list`. Cost note: subscription plans (Claude Max/Pro, OpenAI Pro/Plus) usually cheaper than API for sustained use.

## Next Steps

1. **Playground**: `mkdir ~/Git/aidevops-playground && cd $_ && git init && aidevops init`
2. **Smoke test**: "List my GitHub repos" or "Check my Hetzner servers"
3. **First flow**: `/create-prd` → `/generate-tasks` → `/feature` → build → `/release`
4. **Orchestration**: see `scripts/commands/runners.md`, add `#auto-dispatch` to a TODO.md task
