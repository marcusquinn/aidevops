---
description: Agent routing — how to select and dispatch the right primary agent for a task
mode: subagent
tools:
  read: true
  write: false
  edit: false
  bash: true
  glob: false
  grep: true
  webfetch: false
  task: false
---

# Agent Routing

Not every task is code. The framework has multiple primary agents, each with domain expertise. When dispatching workers (via `/pulse`, `/runners`, or manual `headless-runtime-helper.sh run`), route to the appropriate agent using `--agent <name>`.

## Available Primary Agents

Full index: `subagent-index.toon`

| Agent | Use for |
|-------|---------|
| Build+ | Code: features, bug fixes, refactors, CI, PRs (default) |
| Automate | Scheduling, dispatch, monitoring, background orchestration, pulse supervisor |
| SEO | SEO audits, keyword research, GSC, schema markup |
| Content | Blog posts, video scripts, social media, newsletters |
| Marketing | Email campaigns, FluentCRM, landing pages |
| Business | Company operations, runner configs, strategy |
| Accounts | Financial operations, invoicing, receipts |
| Legal | Compliance, terms of service, privacy policy |
| Research | Tech research, competitive analysis, market research |
| Sales | CRM pipeline, proposals, outreach |
| Social-Media | Social media management, scheduling |
| Video | Video generation, editing, prompt engineering |
| Health | Health and wellness content |

## Routing Rules

- Read the task/issue description and match it to the domain above
- If the task is clearly code (implement, fix, refactor, CI), use Build+ or omit `--agent`
- If the task matches another domain, pass `--agent <name>` to `headless-runtime-helper.sh run`
- When uncertain, default to Build+ — it can read subagent docs on demand
- The agent choice affects which system prompt and domain knowledge the worker loads
- **Bundle-aware routing (t1364.6):** Project bundles can define `agent_routing` overrides per task domain. For example, a content-site bundle routes `marketing` tasks to the Marketing agent. Check with `bundle-helper.sh get agent_routing <repo-path>`. Explicit `--agent` flags always override bundle defaults.

## Headless Dispatch CLI

ALWAYS use `headless-runtime-helper.sh run` for dispatching workers. This helper handles provider rotation, session persistence, backoff, and lifecycle reinforcement. NEVER use bare `opencode run` or `claude run` for dispatch — workers launched that way miss lifecycle reinforcement and stop after PR creation (GH#5096).

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

## Related

- `tools/ai-assistants/headless-dispatch.md` — full headless dispatch patterns
- `reference/orchestration.md` — orchestration overview
- `subagent-index.toon` — full agent index
- `bundles/` + `scripts/bundle-helper.sh` — bundle-aware routing
