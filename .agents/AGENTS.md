---
mode: subagent
---
# AI DevOps Framework - User Guide

New to aidevops? Type `/onboarding`.

**Runtimes:** [Claude Code](https://claude.ai/code), [OpenCode](https://opencode.ai/). Headless: `headless-runtime-helper.sh run` — never bare CLIs.

**Identity**: AI DevOps (framework). Name host app from version-check only. Don't adopt MCP tool identities.

**Runtime-aware**: Confirm active runtime before suggesting app-specific commands.

## Runtime-Specific References

**Session databases** (memory lookup Tier 2):
- **OpenCode**: `~/.local/share/opencode/opencode.db` — SQLite. `sqlite3 ... "SELECT id,title FROM session WHERE title LIKE '%keyword%' ORDER BY time_created DESC LIMIT 5"`
- **Claude Code**: `~/.claude/projects/` — JSONL transcripts. `rg "keyword" ~/.claude/projects/`

**Write-time quality hooks:**
- **Claude Code**: `PreToolUse` hook via `~/.aidevops/hooks/git_safety_guard.py`. Install: `install-hooks-helper.sh install`.
- **OpenCode**: `opencode-aidevops` plugin `tool.execute.before/after` hooks.
- **Neither**: Prompt-level discipline + explicit tool calls.

**Primary agent**: Build+ — auto-detects intent (deliberation vs execution).
**Specialist subagents**: `@aidevops`, `@seo`, `@wordpress`, etc.

## Pre-Edit Git Check

> Skip if no Edit/Write/Bash tools (e.g., Plan+).

Rules: `prompts/build.txt`. Details: `workflows/pre-edit.md`.
On `main`/`master`, subagents may ONLY write to `README.md`, `TODO.md`, `todo/PLANS.md`, `todo/tasks/*`.

---

## Development Lifecycle

1. `/define` (interview) or `/new-task` (quick) — brief at `todo/tasks/{task_id}-brief.md` is MANDATORY
2. Brief: session origin, what, why, how, acceptance criteria, context
3. Implement now or queue? Full-loop: main → worktree → implement → test → verify → PR
4. Never skip testing. Never declare "done" without verification.

---

## Operational Routines (Non-Code Work)

- **Code change** → `/full-loop`
- **Operational execution** (reports, audits, monitoring) → domain agent directly, no worktree ceremony

Details: `/routine` or `scripts/commands/routine.md`.

---

## Self-Improvement

Every session should improve the system. Observe outcomes, file issues for systemic problems, route framework issues to `marcusquinn/aidevops` via `framework-issue-helper.sh log`. Full guide: `reference/self-improvement.md`

---

## Agent Routing

Route tasks via `--agent <name>`. Default: Build+ (code). Full list and dispatch examples: `reference/agent-routing.md`
**Headless dispatch:** ALWAYS `headless-runtime-helper.sh run` — never bare `opencode run` or `claude`.

---

## File Discovery

Rules: `prompts/build.txt`.

---

<!-- AI-CONTEXT-START -->

## Quick Reference

- **CLI**: `aidevops [init|update|status|repos|skills|features]`
- **Scripts**: `~/.aidevops/agents/scripts/[service]-helper.sh [command] [account] [target]`
- **Secrets**: `aidevops secret` (gopass) or `~/.config/aidevops/credentials.sh` (600 perms)
- **Subagent Index**: `subagent-index.toon`
- **Rules**: `prompts/build.txt`

## Planning & Tasks

Format: `- [ ] t001 Description @owner #tag ~4h started:ISO blocked-by:t002`
Task IDs: `/new-task` or `claim-task-id.sh`. NEVER grep TODO.md.

**Briefs MANDATORY.** `todo/tasks/{task_id}-brief.md`: session origin, what, why, how, acceptance criteria. `/define` or `/new-task`.

**Auto-dispatch**: Add `#auto-dispatch` unless needs credentials, decomposition, or user preference. Quality gate: 2+ acceptance criteria, file refs, clear deliverable.

**Model tiers** (GitHub labels): `tier:thinking` (opus), `tier:simple` (haiku), default: sonnet. See `reference/task-taxonomy.md`.

**Completion**: NEVER mark `[x]` without merged PR (`pr:#NNN`) or `verified:YYYY-MM-DD`. Use `task-complete-helper.sh`.

Planning → main. Code → worktree + PR. Workers NEVER edit TODO.md.

**Cross-repo awareness**: Supervisor manages repos in `repos.json` where `pulse: true`. Use `slug` field for `gh` commands. `local_only: true` = skip `gh` ops.

**Repo registration**: New repos → add to `repos.json` immediately. Fields:
- `pulse: true/false` — active dev vs passive
- `pulse_hours` — `{"start": N, "end": N}` dispatch window (optional)
- `pulse_expires` — `"YYYY-MM-DD"` auto-disable (optional)
- `contributed: true` — external repos we've commented on (monitor only)
- `local_only: true` — no remote
- `priority` — `"tooling"`, `"product"`, `"profile"`
- `maintainer` — GitHub username

**Cross-repo tasks**: `claim-task-id.sh` (atomic) → create issue → add TODO with `ref:GH#NNN` in same commit. Full rules: `reference/planning-detail.md`

## Git Workflow

Prefixes: `feature/`, `bugfix/`, `hotfix/`, `refactor/`, `chore/`, `experiment/`, `release/`
PR title: `{task-id}: {description}`. Worktrees: `wt switch -c {type}/{name}`. Keep canonical on `main`. NEVER remove others' worktrees.
Full: `workflows/git-workflow.md`, `reference/session.md`

## Slash Command Resolution

Read `scripts/commands/<command>.md` before executing any slash command. On-disk doc is source of truth. List commands: `ls ~/.aidevops/agents/scripts/commands/`.

## Domain Index

Read subagents on-demand. Full index: `subagent-index.toon`.

| Domain | Entry point |
|--------|-------------|
| Business | `business.md`, `business/company-runners.md` |
| Planning | `workflows/plans.md`, `scripts/commands/define.md`, `tools/task-management/beads.md` |
| Code quality | `tools/code-review/code-standards.md` |
| Git/PRs/Releases | `workflows/git-workflow.md`, `tools/git/github-cli.md`, `workflows/release.md` |
| Documents/PDF | `tools/document/document-creation.md`, `tools/pdf/overview.md`, `tools/conversion/pandoc.md` |
| OCR | `tools/ocr/overview.md`, `tools/ocr/paddleocr.md`, `tools/ocr/glm-ocr.md` |
| Product | `product/validation.md`, `product/onboarding.md`, `product/monetisation.md`, `product/growth.md`, `product/ui-design.md`, `product/analytics.md` |
| Browser/Mobile | `tools/browser/browser-automation.md`, `tools/browser/browser-qa.md`, `tools/browser/browser-use.md`, `tools/browser/skyvern.md`, `tools/mobile/app-dev.md`, `tools/mobile/app-store-connect.md`, `tools/browser/extension-dev.md` |
| Content/Video/Voice | `content.md`, `tools/video/video-prompt-design.md`, `tools/voice/speech-to-speech.md`, `tools/voice/transcription.md` |
| Design | `tools/design/ui-ux-inspiration.md`, `tools/design/ui-ux-catalogue.toon`, `tools/design/brand-identity.md` |
| SEO | `seo/dataforseo.md`, `seo/google-search-console.md` |
| Paid Ads/CRO | `tools/marketing/meta-ads/SKILL.md`, `tools/marketing/ad-creative/SKILL.md`, `tools/marketing/direct-response-copy/SKILL.md`, `tools/marketing/cro/SKILL.md` |
| WordPress | `tools/wordpress/wp-dev.md`, `tools/wordpress/mainwp.md` |
| Communications | `services/communications/bitchat.md`, `services/communications/convos.md`, `services/communications/discord.md`, `services/communications/google-chat.md`, `services/communications/imessage.md`, `services/communications/matterbridge.md`, `services/communications/matrix-bot.md`, `services/communications/msteams.md`, `services/communications/nextcloud-talk.md`, `services/communications/nostr.md`, `services/communications/signal.md`, `services/communications/simplex.md`, `services/communications/slack.md`, `services/communications/telegram.md`, `services/communications/urbit.md`, `services/communications/whatsapp.md`, `services/communications/xmtp.md` |
| Email | `tools/ui/react-email.md`, `services/email/email-agent.md`, `services/email/email-mailbox.md`, `services/email/email-actions.md`, `services/email/email-intelligence.md`, `services/email/email-providers.md`, `services/email/email-security.md`, `services/email/email-testing.md`, `services/email/email-composition.md`, `services/email/email-inbound-commands.md`, `services/email/google-workspace.md` |
| Outreach | `services/outreach/cold-outreach.md`, `services/outreach/smartlead.md`, `services/outreach/instantly.md`, `services/outreach/manyreach.md` |
| Payments | `services/payments/revenuecat.md`, `services/payments/stripe.md`, `services/payments/procurement.md` |
| Auth | `tools/credentials/auth-troubleshooting.md` |
| Security | `tools/security/tirith.md`, `tools/security/opsec.md`, `tools/security/prompt-injection-defender.md`, `tools/security/tamper-evident-audit.md`, `tools/credentials/encryption-stack.md`, `scripts/secret-hygiene-helper.sh` |
| Database | `tools/database/pglite-local-first.md`, `services/database/postgres-drizzle-skill.md` |
| Vector Search | `tools/database/vector-search.md`, `tools/database/vector-search/zvec.md` |
| Hosting/Deployment | `tools/deployment/hosting-comparison.md`, `tools/deployment/fly-io.md`, `tools/deployment/coolify.md`, `tools/deployment/vercel.md`, `tools/deployment/uncloud.md`, `tools/deployment/daytona.md`, `services/hosting/local-hosting.md` |
| Infrastructure | `tools/infrastructure/cloud-gpu.md`, `tools/containers/orbstack.md`, `tools/containers/remote-dispatch.md` |
| Accessibility | `services/accessibility/accessibility-audit.md` |
| Local models | `tools/local-models/local-models.md`, `tools/local-models/huggingface.md`, `scripts/local-model-helper.sh` |
| Bundles/Routing | `bundles/*.json`, `scripts/bundle-helper.sh`, `tools/context/model-routing.md`, `reference/orchestration.md` |
| Orchestration | `reference/orchestration.md`, `tools/ai-assistants/headless-dispatch.md`, `scripts/commands/pulse.md`, `scripts/commands/dashboard.md` |
| Testing | `scripts/commands/testing-setup.md`, `tools/build-agent/agent-testing.md` |
| Agent/MCP dev | `tools/build-agent/build-agent.md`, `tools/build-mcp/build-mcp.md`, `tools/mcp-toolkit/mcporter.md` |
| Framework | `aidevops/architecture.md`, `scripts/commands/skills.md` |

**Creating agents**: Always read `tools/build-agent/build-agent.md` first.

## Capabilities

Details: `reference/orchestration.md`, `reference/services.md`, `reference/session.md`.

- **Model routing**: local→haiku→flash→sonnet→pro→opus. See `tools/context/model-routing.md`.
- **Bundles**: Project-type defaults for tiers, quality, routing. `bundles/`, `bundle-helper.sh`.
- **Memory**: cross-session SQLite FTS5 (`/remember`, `/recall`)
- **Orchestration**: supervisor dispatch, pulse, auto-pickup, cross-repo visibility
- **Contribution watch**: `contribution-watch-helper.sh` — monitors external issues/PRs for replies needed
- **Upstream watch**: `upstream-watch-helper.sh` — tracks external repos for new releases
- **Skills**: `aidevops skills`, `/skills`
- **Auto-update**: `auto-update-helper.sh` — GitHub poll + daily checks
- **Browser**: Playwright, dev-browser (persistent login)
- **Quality**: Write-time linting → `linters-local.sh` → `/pr review` → `/postflight`
- **Sessions**: `/session-review`, `/checkpoint`, compaction resilience
- **Auth recovery**: `tools/credentials/auth-troubleshooting.md`

## Security

Rules: `prompts/build.txt`. Secrets: `gopass` preferred; `credentials.sh` fallback (600 perms). Docs: `tools/credentials/gopass.md`.

**`aidevops security`** — runs all checks. Subcommands: `posture`, `scan`, `check`, `dismiss <id>`.
Advisories shown in greeting until dismissed. Remediation in **separate terminal**, never AI chat.

**Cross-repo privacy:** NEVER include private repo names in public TODO.md/issues.

## Working Directories

Agent tiers: `custom/` (permanent), `draft/` (R&D), root (shared, overwritten on update).
Lifecycle: `tools/build-agent/build-agent.md`.

## Scheduled Tasks (launchd/cron)

Prefix: `sh.aidevops.<name>` (label), `sh.aidevops.<name>.plist` (file), `# aidevops: <desc>` (cron).

<!-- AI-CONTEXT-END -->
