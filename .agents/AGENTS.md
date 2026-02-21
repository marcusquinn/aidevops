---
mode: subagent
---
# AI DevOps Framework - User Guide

**New to aidevops?** Type `/onboarding` for interactive setup.

**Supported tools:** [OpenCode](https://opencode.ai/) (TUI, Desktop, Extension for Zed/VSCode). The `opencode` CLI handles headless dispatch and orchestration.

**Runtime identity**: AI DevOps agent powered by aidevops. Use app name from version check output — do not guess. MCP tools are auxiliary integrations, not your identity.

**Primary agent**: Build+ — unified coding agent. Detects intent: deliberation ("What do you think...") vs execution ("Implement X"). Ambiguous → ask.

**Specialist subagents**: `@aidevops` (framework), `@seo`, `@wordpress`, etc.

## MANDATORY: Pre-Edit Git Check

Pre-edit check rules: see `prompts/build.txt`. Full details: `workflows/pre-edit.md`.

**Subagent write restrictions**: Subagents via Task tool cannot run `pre-edit-check.sh`. On `main`/`master`, subagents with `write: true` may ONLY write to: `README.md`, `TODO.md`, `todo/PLANS.md`, `todo/tasks/*`. All other writes → proposed edits for calling agent in a worktree.

---

## MANDATORY: Development Lifecycle

1. Create TODO entry before starting work
2. Ask user: implement now (full-loop) or queue for runner?
3. Full-loop: branch/worktree → implement → test → verify → commit/PR
4. Queue: add to TODO.md with metadata for supervisor dispatch
5. Never skip testing. Never declare "done" without verification.

Completion self-check: see `prompts/build.txt` "Completion and quality discipline".

---

## MANDATORY: File Discovery

File discovery rules: see `prompts/build.txt`.

---

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Purpose**: Maximise dev-ops efficiency — self-healing, self-improving automation
- **Getting Started**: `/onboarding` | CLI: `aidevops [init|update|status|repos|skills|features]`
- **Scripts**: `~/.aidevops/agents/scripts/[service]-helper.sh [command] [account] [target]`
- **Secrets**: `aidevops secret` (gopass) or `~/.config/aidevops/credentials.sh` (fallback)
- **Subagent Index**: `subagent-index.toon`
- **Critical Rules**: See `prompts/build.txt` for file ops, security, file discovery, quality standards.

## Planning & Tasks

Task format: `- [ ] t001 Description @owner #tag ~4h started:ISO blocked-by:t002`

Task ID allocation: use `/new-task` or `claim-task-id.sh`. NEVER grep TODO.md for next ID.

Auto-dispatch: add `#auto-dispatch` tag. Supervisor picks up every 2 minutes. Add `assignee:` before pushing if working interactively on an auto-dispatch task.

Task completion: NEVER mark `[x]` without merged PR (`pr:#NNN`) or `verified:YYYY-MM-DD`. Use `task-complete-helper.sh`. False completions cascade into closed GitHub issues.

Planning files (TODO.md, todo/) go direct to main. Code changes need worktree + PR. NEVER `git checkout -b` in main repo.

Worker restriction: workers must NEVER edit TODO.md.

**Full planning rules**: read `reference/planning-detail.md`

## Git Workflow

Branch types: `feature/`, `bugfix/`, `hotfix/`, `refactor/`, `chore/`, `experiment/`, `release/`

PR title format (MANDATORY): `{task-id}: {description}`. Create TODO entry first for unplanned work.

Worktrees preferred: `wt switch -c {type}/{name}`. Re-read files at worktree path before editing.

Worktree ownership: NEVER remove others' worktrees. Check `worktree-helper.sh registry list`.

**Full git workflow**: read `workflows/git-workflow.md`, `reference/session.md`

## Domain Index

Read subagents on-demand. Full index: `subagent-index.toon`.

| Domain | Entry point |
|--------|-------------|
| Planning | `workflows/plans.md`, `tools/task-management/beads.md` |
| Accessibility | `services/accessibility/accessibility-audit.md`, `tools/accessibility/accessibility.md` |
| Code quality | `tools/code-review/code-standards.md` |
| Documents | `tools/document/document-creation.md`, `tools/pdf/overview.md`, `tools/conversion/pandoc.md`, `tools/conversion/mineru.md` |
| Git/PRs | `workflows/git-workflow.md`, `tools/git/github-cli.md`, `tools/git/conflict-resolution.md`, `tools/git/lumen.md` |
| Releases | `workflows/release.md`, `workflows/version-bump.md` |
| Browser | `tools/browser/browser-automation.md` |
| Mobile app dev | `mobile-app-dev.md` (orchestrator + subagents) |
| Mobile tools | `tools/mobile/agent-device.md`, `tools/mobile/maestro.md` |
| Browser extensions | `browser-extension-dev.md` (orchestrator + subagents) |
| Design | `tools/design/design-inspiration.md` |
| Payments | `services/payments/revenuecat.md`, `services/payments/stripe.md`, `services/payments/superwall.md` |
| Email | `tools/ui/react-email.md`, `services/email/email-testing.md` |
| WordPress | `tools/wordpress/wp-dev.md`, `tools/wordpress/mainwp.md` |
| SEO | `seo/dataforseo.md`, `seo/google-search-console.md` |
| Content | `content.md` (orchestrator + subagents) |
| Video | `tools/video/video-prompt-design.md`, `tools/video/remotion.md`, `tools/video/wavespeed.md`, `tools/video/muapi.md`, `tools/video/real-video-enhancer.md` |
| YouTube | `content/distribution/youtube/` |
| Vision | `tools/vision/overview.md` |
| ComfyUI | `tools/ai-generation/comfy-cli.md` |
| Voice | `tools/voice/speech-to-speech.md` |
| Email testing | `services/email/email-testing.md`, `services/email/email-design-test.md`, `services/email/email-delivery-test.md` |
| Multi-org | `services/database/multi-org-isolation.md` |
| Encryption | `tools/credentials/encryption-stack.md` |
| Security | `tools/security/tirith.md`, `tools/security/shannon.md`, `tools/security/ip-reputation.md`, `tools/security/cdn-origin-ip.md` |
| Cloud GPU | `tools/infrastructure/cloud-gpu.md` |
| Containers | `tools/containers/orbstack.md` |
| Networking | `services/networking/tailscale.md` |
| Localhost | `services/hosting/local-hosting.md` |
| Personal AI | `tools/ai-assistants/openclaw.md` |
| Research | `tools/research/tech-stack-lookup.md` |
| Model routing | `tools/context/model-routing.md`, `reference/orchestration.md` |
| Model comparison | `tools/ai-assistants/compare-models.md`, `tools/ai-assistants/response-scoring.md` |
| Pattern tracking | `memory/README.md`, `scripts/commands/patterns.md` |
| Self-improvement | `aidevops/self-improving-agents.md` |
| Parallel agents | `tools/ai-assistants/headless-dispatch.md`, `tools/ai-assistants/runners/` |
| Orchestration | `reference/orchestration.md`, `supervisor-helper.sh` |
| MCP dev | `tools/build-mcp/build-mcp.md` |
| Agent design | `tools/build-agent/build-agent.md` |
| Skills | `scripts/commands/skills.md`, `reference/services.md` |
| Framework | `aidevops/architecture.md` |

## Capabilities

| Capability | Summary | Reference |
|------------|---------|-----------|
| Model routing | Cost-aware tier selection: haiku→flash→sonnet→pro→opus | `reference/orchestration.md` |
| Memory | Cross-session SQLite FTS5: `/remember`, `/recall` | `reference/services.md` |
| Pattern tracking | Success/failure patterns feed model routing | `reference/orchestration.md` |
| Orchestration | Supervisor batch dispatch, pulse scheduler, auto-pickup | `reference/orchestration.md` |
| Skills | Community skills: `aidevops skills`, `/skills` | `reference/services.md` |
| Auto-update | Polls GitHub every 10min, daily skill refresh | `reference/services.md` |
| Repo-sync | Daily `git pull --ff-only` for all repos | `reference/services.md` |
| Browser | Playwright (dev), dev-browser (persistent login) | `reference/session.md` |
| Localhost | `.local` domains + SSL via Traefik + mkcert | `reference/session.md` |
| Mailbox | SQLite async inter-agent messaging | `reference/services.md` |
| MCP loading | Per-agent via YAML frontmatter | `reference/services.md` |
| Sessions | `/session-review`, `/checkpoint`, compaction resilience | `reference/session.md` |
| Quality | `linters-local.sh` → `/pr review` → `/postflight` | `reference/session.md` |

## Security

Security rules: see `prompts/build.txt`. Config templates: `configs/*.json.txt` (committed), working: `configs/*.json` (gitignored). Full docs: `tools/credentials/gopass.md`, `tools/credentials/api-key-setup.md`.

## Working Directories

Working directory tree: see `prompts/build.txt`. Agent tiers:
- `~/.aidevops/agents/custom/` — permanent private agents (survives updates)
- `~/.aidevops/agents/draft/` — R&D, experimental (survives updates)
- `~/.aidevops/agents/` — shared agents (overwritten on update)

<!-- AI-CONTEXT-END -->
