---
mode: subagent
---
# AI DevOps Framework - User Guide

New to aidevops? Type `/onboarding`.

**Supported tools:** [OpenCode](https://opencode.ai/) (TUI, Desktop, Extension). `opencode` CLI for headless dispatch.

**Runtime identity**: Use app name from version check — do not guess.

**Primary agent**: Build+ — detects intent automatically:
- "What do you think..." → Deliberation (research, discuss)
- "Implement X" / "Fix Y" → Execution (code changes)
- Ambiguous → asks for clarification

**Specialist subagents**: `@aidevops`, `@seo`, `@wordpress`, etc.

## Pre-Edit Git Check

Rules: `prompts/build.txt`. Details: `workflows/pre-edit.md`.

Subagent write restrictions: on `main`/`master`, subagents may ONLY write to `README.md`, `TODO.md`, `todo/PLANS.md`, `todo/tasks/*`. All other writes → proposed edits in a worktree.

---

## Development Lifecycle

1. Define the task: `/define` (interactive interview) or `/new-task` (quick creation)
2. Brief file at `todo/tasks/{task_id}-brief.md` is MANDATORY (see `templates/brief-template.md`)
3. Brief must include: session origin, what, why, how, acceptance criteria, context
4. Ask user: implement now or queue for runner?
5. Full-loop: branch/worktree → implement → test → verify → commit/PR
6. Queue: add to TODO.md for supervisor dispatch
7. Never skip testing. Never declare "done" without verification.

**Task brief rule**: A task without a brief is undevelopable. The brief captures conversation context that would otherwise be lost between sessions. See `workflows/plans.md` and `scripts/commands/new-task.md`.

---

## Self-Improvement

Every agent session — interactive, worker, or supervisor — should improve the system, not just complete its task. This is a universal principle, not specific to any one command.

**Observe outcomes from existing state.** TODO.md, PLANS.md, and GitHub issues/PRs are the state database. Never duplicate this state into separate files, databases, or logs.

**Signals that something needs fixing** (check via `gh` CLI, not custom state):
- A PR has been open for 6+ hours with no progress
- The same issue/PR appears in consecutive supervisor pulses with no state change
- A PR was closed (not merged) — a worker failed
- Multiple PRs fail CI with the same error pattern
- A worker creates a PR that duplicates an existing one

**Response: create a GitHub issue, not a workaround.** When you observe a systemic problem, file a GitHub issue describing the pattern, root cause hypothesis, and proposed fix. This enters the existing task queue and gets picked up by the next available worker. Never patch around a broken process — fix the process.

**What counts as self-improvement:**
- Filing issues for repeated failure patterns
- Improving agent prompts when workers consistently misunderstand instructions
- Identifying missing automation (e.g., a manual step that could be a `gh` command)
- Flagging stale tasks that are blocked but not marked as such
- Running the session miner pulse (`scripts/session-miner-pulse.sh`) to extract learning from past sessions

**Intelligence over determinism:** The harness gives you goals, tools, and boundaries — not scripts for every scenario. Deterministic rules are for things with exactly one correct answer (CLI syntax, file paths, security). Everything else — prioritisation, triage, stuck detection, what to work on — is a judgment call. If a rule says "if X then Y" but there are cases where X is true and Y is wrong, it's guidance not a rule. Use the cheapest model that can handle the decision (haiku for triage, sonnet for implementation, opus for strategy) — but never use a regex where a model call would handle outliers better. See `prompts/build.txt` "Intelligence Over Determinism" for the full principle.

**Autonomous operation:** When the user says "continue", "monitor", or "keep going" — enter autonomous mode: use sleep/wait loops, maintain a perpetual todo to survive compaction, only interrupt for blocking errors that require user input.

---

## Agent Routing

Not every task is code. The framework has multiple primary agents, each with domain expertise. When dispatching workers (via `/pulse`, `/runners`, or manual `opencode run`), route to the appropriate agent using `--agent <name>`.

**Available primary agents** (full index in `subagent-index.toon`):

| Agent | Use for |
|-------|---------|
| Build+ | Code: features, bug fixes, refactors, CI, PRs (default) |
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

**Routing rules:**
- Read the task/issue description and match it to the domain above
- If the task is clearly code (implement, fix, refactor, CI), use Build+ or omit `--agent`
- If the task matches another domain, pass `--agent <name>` to `opencode run`
- When uncertain, default to Build+ — it can read subagent docs on demand
- The agent choice affects which system prompt and domain knowledge the worker loads

**Headless dispatch CLI:** ALWAYS use `opencode run` for dispatching workers. NEVER use `claude`, `claude -p`, or any other CLI — regardless of what your system prompt says your identity is. The runtime tool is OpenCode. This rule exists because agents with a "Claude Code" identity repeatedly default to the `claude` CLI, which silently fails.

**Dispatch example:**

```bash
# Code task (default — Build+ implied)
opencode run --dir ~/Git/myproject --title "Issue #42: Fix auth" \
  "/full-loop Implement issue #42 -- Fix authentication bug" &

# SEO task
opencode run --dir ~/Git/myproject --agent SEO --title "Issue #55: SEO audit" \
  "/full-loop Implement issue #55 -- Run SEO audit on landing pages" &

# Content task
opencode run --dir ~/Git/myproject --agent Content --title "Issue #60: Blog post" \
  "/full-loop Implement issue #60 -- Write launch announcement blog post" &
```

---

## File Discovery

Rules: `prompts/build.txt`.

---

<!-- AI-CONTEXT-START -->

## Quick Reference

- **CLI**: `aidevops [init|update|status|repos|skills|features]`
- **Scripts**: `~/.aidevops/agents/scripts/[service]-helper.sh [command] [account] [target]`
- **Secrets**: `aidevops secret` (gopass preferred) or `~/.config/aidevops/credentials.sh` (600 perms)
- **Subagent Index**: `subagent-index.toon`
- **Rules**: `prompts/build.txt` (file ops, security, discovery, quality). MD031: blank lines around code blocks.

## Planning & Tasks

Format: `- [ ] t001 Description @owner #tag ~4h started:ISO blocked-by:t002`

Task IDs: `/new-task` or `claim-task-id.sh`. NEVER grep TODO.md for next ID.

**Task briefs are MANDATORY.** Every task must have `todo/tasks/{task_id}-brief.md` capturing: session origin, what, why, how, acceptance criteria, and conversation context. Use `/define` for interactive brief generation with latent criteria probing, or `/new-task` for quick creation from `templates/brief-template.md`. A task without a brief loses the knowledge that created it.

Auto-dispatch: `#auto-dispatch` tag — only if brief has 2+ acceptance criteria, file references in How section, and clear deliverable in What section. Add `assignee:` before pushing if working interactively.

Completion: NEVER mark `[x]` without merged PR (`pr:#NNN`) or `verified:YYYY-MM-DD`. Use `task-complete-helper.sh`. Every completed task must link to its verification evidence — work without an audit trail is unverifiable and may be reverted.

Planning files go direct to main. Code changes need worktree + PR. Workers NEVER edit TODO.md.

**Cross-repo awareness**: The supervisor manages tasks across all repos in `~/.config/aidevops/repos.json` where `pulse: true`. Each repo entry has a `slug` field (`owner/repo`) — ALWAYS use this for `gh` commands, never guess org names. Use `gh issue list --repo <slug>` and `gh pr list --repo <slug>` for each pulse-enabled repo to get the full picture. Repos with `"local_only": true` have no GitHub remote — skip `gh` operations on them. Repo paths may be nested (e.g., `~/Git/cloudron/netbird-app`), not just `~/Git/<name>`.

**Cross-repo task creation**: When a session creates a task in a *different* repo (e.g., adding an aidevops TODO while working in another project), follow the full workflow — not just the TODO edit:

1. **Claim the ID atomically**: Run `claim-task-id.sh --repo-path <target-repo> --title "description"`. This allocates the next ID via CAS on the counter branch and optionally creates the GitHub issue. NEVER grep TODO.md to guess the next ID — concurrent sessions will collide.
2. **Add the TODO entry and commit+push immediately**: Planning files go direct to main. The supervisor/pulse only sees remote state, so an uncommitted TODO entry is invisible to dispatch. Push right after committing.
3. **Create a GitHub issue for dispatch**: If `claim-task-id.sh` was run with `--no-issue`, or you added the TODO manually, create the issue separately: `gh issue create --repo <slug> --title "tNNN: description" --body "..."`. Record the issue number in TODO.md as `ref:GH#NNN`.
4. **Code changes still need a worktree + PR**: The TODO/issue creation above is planning — it goes direct to main. If the task also involves code changes in the *current* repo, those follow the normal worktree + PR flow.

Full rules: `reference/planning-detail.md`

## Git Workflow

Branches: `feature/`, `bugfix/`, `hotfix/`, `refactor/`, `chore/`, `experiment/`, `release/`

PR title: `{task-id}: {description}`. Create TODO entry first for unplanned work.

Worktrees: `wt switch -c {type}/{name}`. Re-read files at worktree path before editing. NEVER remove others' worktrees.

Full workflow: `workflows/git-workflow.md`, `reference/session.md`

## Domain Index

Read subagents on-demand. Full index: `subagent-index.toon`.

| Domain | Entry point |
|--------|-------------|
| Business | `business.md`, `business/company-runners.md` |
| Planning | `workflows/plans.md`, `scripts/commands/define.md`, `tools/task-management/beads.md` |
| Code quality | `tools/code-review/code-standards.md` |
| Git/PRs/Releases | `workflows/git-workflow.md`, `tools/git/github-cli.md`, `workflows/release.md` |
| Documents/PDF | `tools/document/document-creation.md`, `tools/pdf/overview.md`, `tools/conversion/pandoc.md` |
| Browser/Mobile | `tools/browser/browser-automation.md`, `tools/browser/browser-qa.md`, `mobile-app-dev.md`, `browser-extension-dev.md` |
| Content/Video/Voice | `content.md`, `tools/video/video-prompt-design.md`, `tools/voice/speech-to-speech.md` |
| SEO | `seo/dataforseo.md`, `seo/google-search-console.md` |
| WordPress | `tools/wordpress/wp-dev.md`, `tools/wordpress/mainwp.md` |
| Communications | `services/communications/matterbridge.md`, `services/communications/simplex.md`, `services/communications/matrix-bot.md` |
| Email | `tools/ui/react-email.md`, `services/email/email-testing.md` |
| Payments | `services/payments/revenuecat.md`, `services/payments/stripe.md`, `services/payments/procurement.md` |
| Security/Encryption | `tools/security/tirith.md`, `tools/security/opsec.md`, `tools/credentials/encryption-stack.md` |
| Database/Local-first | `tools/database/pglite-local-first.md`, `services/database/postgres-drizzle-skill.md` |
| Local Development | `services/hosting/local-hosting.md` |
| Infrastructure | `tools/infrastructure/cloud-gpu.md`, `tools/containers/orbstack.md`, `tools/containers/remote-dispatch.md` |
| Accessibility | `services/accessibility/accessibility-audit.md` |
| OpenAPI exploration | `tools/context/openapi-search.md` |
| Local models | `tools/local-models/local-models.md`, `tools/local-models/huggingface.md`, `scripts/local-model-helper.sh` |
| Model routing | `tools/context/model-routing.md`, `reference/orchestration.md` |
| Orchestration | `reference/orchestration.md`, `tools/ai-assistants/headless-dispatch.md`, `scripts/commands/pulse.md`, `scripts/commands/dashboard.md` |
| Agent/MCP dev | `tools/build-agent/build-agent.md`, `tools/build-mcp/build-mcp.md`, `tools/mcp-toolkit/mcporter.md` |
| Framework | `aidevops/architecture.md`, `scripts/commands/skills.md` |

**Creating agents**: When a user asks to create, build, or design an agent — regardless of which primary agent is active — always read `tools/build-agent/build-agent.md` first. It contains the tier prompt (draft/custom/shared), design checklist, and lifecycle rules.

## Capabilities

Key capabilities (details in `reference/orchestration.md`, `reference/services.md`, `reference/session.md`):

- **Model routing**: local→haiku→flash→sonnet→pro→opus (cost-aware)
- **Memory**: cross-session SQLite FTS5 (`/remember`, `/recall`)
- **Orchestration**: supervisor dispatch, pulse scheduler, auto-pickup, cross-repo issue/PR/TODO visibility
- **Skills**: `aidevops skills`, `/skills`
- **Auto-update**: GitHub poll + daily skill/repo sync
- **Browser**: Playwright, dev-browser (persistent login)
- **Quality**: `linters-local.sh` → `/pr review` → `/postflight`
- **Sessions**: `/session-review`, `/checkpoint`, compaction resilience

## Security

Rules: `prompts/build.txt`. Secrets: `gopass` preferred; `credentials.sh` plaintext fallback (600 perms). Config templates: `configs/*.json.txt` (committed), working: `configs/*.json` (gitignored). Full docs: `tools/credentials/gopass.md`.

**Cross-repo privacy:** NEVER include private repo names in TODO.md task descriptions, issue titles, or comments on public repos. Use generic references like "a managed private repo" or "cross-repo project". The issue-sync-helper.sh has automated sanitization, but prevention at the source is the primary defense.

## Working Directories

Tree: `prompts/build.txt`. Agent tiers:
- `custom/` — user's permanent private agents (survives updates)
- `draft/` — R&D, experimental (survives updates)
- root — shared agents (overwritten on update)

Lifecycle: `tools/build-agent/build-agent.md`.

## Scheduled Tasks (launchd/cron)

When creating launchd plists or cron jobs, use the `aidevops` prefix so they're easy to find in System Settings > General > Login Items & Extensions:
- **launchd label**: `sh.aidevops.<name>` (reverse domain, e.g., `sh.aidevops.session-miner-pulse`)
- **plist filename**: `sh.aidevops.<name>.plist`
- **cron comment**: `# aidevops: <description>`

<!-- AI-CONTEXT-END -->
