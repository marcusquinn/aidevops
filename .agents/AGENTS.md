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

Completion: NEVER mark `[x]` without merged PR (`pr:#NNN`) or `verified:YYYY-MM-DD`. Use `task-complete-helper.sh`.

Planning files go direct to main. Code changes need worktree + PR. Workers NEVER edit TODO.md.

**Cross-repo awareness**: The supervisor manages tasks across all `repos.json` repos. When querying queue status, check the supervisor DB (`~/.aidevops/.agent-workspace/supervisor/supervisor.db`) for all active tasks across repos, not just the current repo's TODO.md. Use `gh issue list --repo <slug>` for each managed repo to get the full picture.

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
| Browser/Mobile | `tools/browser/browser-automation.md`, `mobile-app-dev.md`, `browser-extension-dev.md` |
| Content/Video/Voice | `content.md`, `tools/video/video-prompt-design.md`, `tools/voice/speech-to-speech.md` |
| SEO | `seo/dataforseo.md`, `seo/google-search-console.md` |
| WordPress | `tools/wordpress/wp-dev.md`, `tools/wordpress/mainwp.md` |
| Communications | `services/communications/matterbridge.md`, `services/communications/simplex.md`, `services/communications/matrix-bot.md` |
| Email | `tools/ui/react-email.md`, `services/email/email-testing.md` |
| Payments | `services/payments/revenuecat.md`, `services/payments/stripe.md` |
| Security/Encryption | `tools/security/tirith.md`, `tools/security/opsec.md`, `tools/credentials/encryption-stack.md` |
| Database/Local-first | `tools/database/pglite-local-first.md`, `services/database/postgres-drizzle-skill.md` |
| Local Development | `services/hosting/local-hosting.md` |
| Infrastructure | `tools/infrastructure/cloud-gpu.md`, `tools/containers/orbstack.md`, `tools/containers/remote-dispatch.md` |
| Accessibility | `services/accessibility/accessibility-audit.md` |
| OpenAPI exploration | `tools/context/openapi-search.md` |
| Model routing | `tools/context/model-routing.md`, `reference/orchestration.md` |
| Orchestration | `reference/orchestration.md`, `tools/ai-assistants/headless-dispatch.md` |
| Agent/MCP dev | `tools/build-agent/build-agent.md`, `tools/build-mcp/build-mcp.md`, `tools/mcp-toolkit/mcporter.md` |
| Framework | `aidevops/architecture.md`, `scripts/commands/skills.md` |

## Capabilities

Key capabilities (details in `reference/orchestration.md`, `reference/services.md`, `reference/session.md`):

- **Model routing**: haiku→flash→sonnet→pro→opus (cost-aware)
- **Memory**: cross-session SQLite FTS5 (`/remember`, `/recall`)
- **Orchestration**: supervisor dispatch, pulse scheduler, auto-pickup, cross-repo issue/PR/TODO visibility
- **Skills**: `aidevops skills`, `/skills`
- **Auto-update**: GitHub poll + daily skill/repo sync
- **Browser**: Playwright, dev-browser (persistent login)
- **Quality**: `linters-local.sh` → `/pr review` → `/postflight`
- **Sessions**: `/session-review`, `/checkpoint`, compaction resilience

## Security

Rules: `prompts/build.txt`. Secrets: `gopass` preferred; `credentials.sh` plaintext fallback (600 perms). Config templates: `configs/*.json.txt` (committed), working: `configs/*.json` (gitignored). Full docs: `tools/credentials/gopass.md`.

## Working Directories

Tree: `prompts/build.txt`. Agent tiers:
- `custom/` — user's permanent private agents (survives updates)
- `draft/` — R&D, experimental (survives updates)
- root — shared agents (overwritten on update)

Lifecycle: `tools/build-agent/build-agent.md`.

<!-- AI-CONTEXT-END -->
