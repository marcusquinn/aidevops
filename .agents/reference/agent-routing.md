# Agent Routing

## Core rule

Dispatch workers with `headless-runtime-helper.sh run`, not bare runtime CLIs. The helper provides provider rotation, session persistence, backoff, and lifecycle reinforcement. Bare `claude run`, `claude`, `claude -p`, or similar commands can skip lifecycle reinforcement and stop after PR creation (GH#5096).

## Routing order

1. Read the task or issue description.
2. If it is clearly code work (`implement`, `fix`, `refactor`, `CI`), use Build+ or omit `--agent`.
3. If it matches another domain, pass `--agent <name>`.
4. If uncertain, default to Build+; it can load narrower docs on demand.
5. **Bundle-aware routing (t1364.6):** project bundles can define `agent_routing` overrides. Check with `bundle-helper.sh get agent_routing <repo-path>`. An explicit `--agent` flag wins.

The selected agent changes the system prompt and domain knowledge loaded for the worker.

## Primary agents

Full index: `subagent-index.toon`.

| Agent | Use for |
|-------|---------|
| Build+ | Code: features, bug fixes, refactors, CI, PRs (default) |
| Automate | Scheduling, dispatch, monitoring, background orchestration, pulse supervisor |
| SEO | SEO audits, keyword research, GSC, schema markup |
| Content | Media production and distribution: blog, video, audio, image, social, newsletters, AI video generation |
| Marketing-Sales | Email campaigns, FluentCRM, Meta Ads, CRO, direct response copy, CRM pipeline, proposals, outreach |
| Business | Company operations, financial ops, invoicing, receipts, runner configs, strategy |
| Legal | Compliance, terms of service, privacy policy |
| Research | Tech research, competitive analysis, market research |
| Health | Health and wellness content |

## Dispatch example

```bash
AGENTS_DIR="$(aidevops config get paths.agents_dir)"
AGENTS_DIR="${AGENTS_DIR:-"$HOME/.aidevops/agents"}"
HELPER="${AGENTS_DIR/#\~/$HOME}/scripts/headless-runtime-helper.sh"
# Path is determined by 'paths.agents_dir' in config.jsonc

# Code task (default — Build+ implied)
$HELPER run \
  --role worker \
  --session-key "issue-42" \
  --dir ~/Git/myproject \
  --title "Issue #42: Fix auth" \
  --prompt "/full-loop Implement issue #42 -- Fix authentication bug" &
sleep 2

# SEO task
$HELPER run \
  --role worker \
  --session-key "issue-55" \
  --agent SEO \
  --dir ~/Git/myproject \
  --title "Issue #55: SEO audit" \
  --prompt "/full-loop Implement issue #55 -- Run SEO audit on landing pages" &
sleep 2

# Content task
$HELPER run \
  --role worker \
  --session-key "issue-60" \
  --agent Content \
  --dir ~/Git/myproject \
  --title "Issue #60: Blog post" \
  --prompt "/full-loop Implement issue #60 -- Write launch announcement blog post" &
sleep 2
```
