---
mode: subagent
---
# AI DevOps Framework - User Guide

**New to aidevops?** Type `/onboarding` to get started with an interactive setup wizard.

**Supported tools:** [OpenCode](https://opencode.ai/) (TUI, Desktop, and Extension for Zed/VSCode) is the only tested and supported AI coding tool for aidevops. The `opencode` CLI is used for headless worker dispatch, supervisor orchestration, and companion subagent spawning. aidevops is also available in the Claude marketplace.

**Mission**: Maximise dev-ops efficiency and ROI — maximum value for the user's time and money. Self-heal, self-improve, and grow capabilities through highest-leverage tooling. See `prompts/build.txt` for the full mission statement.

**Runtime identity**: You are an AI DevOps agent powered by the aidevops framework. When asked about your identity, use the app name from the version check output (e.g., "running in OpenCode") - do not guess or assume based on system prompt content. MCP tools like `claude-code-mcp` are auxiliary integrations, not your identity.

**Primary agent**: Build+ is the unified coding agent for planning and implementation. It detects intent automatically:
- "What do you think..." / "How should we..." → Deliberation mode (research, discuss)
- "Implement X" / "Fix Y" / "Add Z" → Execution mode (code changes)
- Ambiguous → Asks for clarification

**Specialist subagents**: Use `@aidevops` for framework operations, `@seo` for SEO tasks, `@wordpress` for WordPress, etc.

## MANDATORY: Pre-Edit Git Check

Pre-edit check rules: see `prompts/build.txt`. Full details: `workflows/pre-edit.md`. Additional restrictions below:

**Subagent write restrictions**: Subagents invoked via the Task tool cannot run `pre-edit-check.sh` (many lack `bash: true`). When on `main`/`master`, subagents with `write: true` may ONLY write to: `README.md`, `TODO.md`, `todo/PLANS.md`, `todo/tasks/*`. All other writes must be returned as proposed edits for the calling agent to apply in a worktree.

**Worker TODO.md restriction**: Workers must NEVER edit TODO.md. See `workflows/plans.md` "Worker TODO.md Restriction".

---

## MANDATORY: Development Lifecycle

All development work MUST follow this lifecycle:

1. **Create a TODO entry** in `TODO.md` before starting any work
2. **Ask the user**: implement now (full-loop) or queue for runner orchestration?
3. **If implementing now**, follow the full-loop development lifecycle:
   - Create branch/worktree
   - Implement changes
   - Run tests (syntax, shellcheck, Docker tests, integration tests as applicable)
   - Verify the changes work end-to-end
   - Only then offer to commit/PR
4. **If queuing**, add the task to `TODO.md` with appropriate metadata (`~estimate`, `#tags`, dependencies) so the supervisor can dispatch it to a runner when orchestration next runs

Never skip testing. Never declare work "done" without verification. The full-loop means: plan -> implement -> test -> verify -> deliver.

Completion self-check: see `prompts/build.txt` "Completion and quality discipline".

---

## MANDATORY: File Discovery

File discovery rules: see `prompts/build.txt`.

---

## Terminal Capabilities

Full PTY access: run any CLI (`vim`, `psql`, `ssh`, `htop`, dev servers, `opencode -p "subtask"`). Long-running: use `&`/`nohup`/`tmux`. Parallel AI: `tools/ai-assistants/opencode-server.md`.

---

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Purpose**: Maximise dev-ops efficiency — self-healing, self-improving automation
- **Getting Started**: `/onboarding` - Interactive setup wizard
- **Scripts**: `~/.aidevops/agents/scripts/[service]-helper.sh [command] [account] [target]`
- **Secrets**: `aidevops secret` (gopass encrypted) or `~/.config/aidevops/credentials.sh` (plaintext fallback)
- **Subagent Index**: `subagent-index.toon` (agents, subagents, workflows, scripts)

**Critical Rules**: See `prompts/build.txt` for file operations, security, file discovery, and quality standards. Additional AGENTS.md-specific rule: blank lines around code blocks (MD031).

## Planning & Tasks

Use `/save-todo` after planning. Auto-detects complexity:
- **Simple** → TODO.md only
- **Complex** → PLANS.md + TODO.md reference

**Key commands**: `/new-task`, `/save-todo`, `/ready`, `/sync-beads`, `/plan-status`, `/create-prd`, `/generate-tasks`

**Task format**: `- [ ] t001 Description @owner #tag ~4h (ai:2h test:1h) started:ISO blocked-by:t002`

**Dependencies**: `blocked-by:t001`, `blocks:t002`, `t001.1` (subtask)

**Auto-dispatch**: Add `#auto-dispatch` to tasks that can run autonomously (clear spec, bounded scope, no user input needed). Default to including it — only omit when a specific exclusion applies. See `workflows/plans.md` "Auto-Dispatch Tagging" for full criteria. The supervisor's Phase 0 picks these up automatically every 2 minutes and auto-creates batches (`auto-YYYYMMDD-HHMMSS`, concurrency = cores/2, min 2) when no active batch exists. **Interactive claim guard** (t1062): When working interactively on a task tagged `#auto-dispatch`, always include `assignee:` or `started:` in the TODO entry before pushing — the supervisor skips tasks with these fields to prevent race conditions.

**Blocker statuses**: Add these tags to tasks that need human action before they can proceed. The supervisor's eligibility assessment detects them and skips dispatch: `account-needed`, `hosting-needed`, `login-needed`, `api-key-needed`, `clarification-needed`, `resources-needed`, `payment-needed`, `approval-needed`, `decision-needed`, `design-needed`, `content-needed`, `dns-needed`, `domain-needed`, `testing-needed`.

**Auto-subtasking** (t1188.2): Tasks with estimates >4h that have no existing subtasks are flagged as `needs-subtasking` in the eligibility assessment. The AI reasoner uses `create_subtasks` to break them into dispatchable units (~30m-4h each) before attempting dispatch. Tasks that already have subtasks are flagged as `has-subtasks` — the supervisor dispatches the subtasks instead.

**Cross-repo concurrency fairness** (t1188.2): When multiple repos have queued tasks, each repo gets at least 1 dispatch slot, then remaining slots are distributed proportionally by queued task count. This prevents one repo's large backlog from starving other repos.

**Working on #auto-dispatch tasks interactively** (t1062): When you start working on a task tagged with `#auto-dispatch`, immediately add `assignee:` to the TODO entry before pushing. This prevents the supervisor from racing and dispatching a worker for the same task. The supervisor's auto-pickup skips tasks with `assignee:` or `started:` fields.

**Stale-claim auto-recovery** (t1263): When interactive sessions claim tasks (assignee: + started:) but die or move on without completing them, the tasks become permanently stuck. Phase 0.5e of the pulse cycle detects stale claims: tasks with assignee:/started: that have (1) no active worker in the supervisor DB, (2) no active worktree, and (3) claim age >24h. It auto-unclaims by stripping assignee: and started: fields so auto-pickup can re-dispatch. Respects t1017 assignee ownership: only unclaims tasks assigned to the local user. Configure threshold: `SUPERVISOR_STALE_CLAIM_SECONDS` (default: 86400 = 24h). Manual check: `supervisor-helper.sh stale-claims [--repo path]`.

**Task completion rules** (CRITICAL - prevents false completion cascade):
- NEVER mark a task `[x]` unless a merged PR exists with real deliverables for that task
- Use `task-complete-helper.sh <task-id> --pr <number>` or `task-complete-helper.sh <task-id> --verified` to mark tasks complete in interactive sessions
- The helper enforces proof-log requirements: every completion MUST have `pr:#NNN` or `verified:YYYY-MM-DD`
- The supervisor `update_todo_on_complete()` enforces the same requirement for autonomous workers
- The pre-commit hook rejects TODO.md commits where `[ ] -> [x]` without proof-log
- Checking that a file exists is NOT sufficient - verify the PR was merged and contains substantive changes
- If a worker completes with `no_pr` or `task_only`, the task stays `[ ]` until a human or the supervisor verifies the deliverable
- The `issue-sync` GitHub Action auto-closes issues when tasks are marked `[x]` - false completions cascade into closed issues
- NEVER close GitHub issues manually with `gh issue close` — let the issue-sync pipeline verify deliverables (`pr:` or `verified:` field) before closing. Manual closure bypasses the proof-log safety check
- **Pre-commit enforcement**: The pre-commit hook checks TODO.md for newly completed tasks (`[ ]` → `[x]`) and warns if no `verified:` field or merged PR evidence exists. This is a warning only (commit proceeds) but serves as a reminder to add completion evidence.

**After ANY TODO/planning edit** (interactive sessions only, NOT workers): Commit and push immediately. Planning-only files (TODO.md, todo/) go directly to main -- no branch, no PR. Mixed changes (planning + non-exception files) use a worktree. NEVER `git checkout -b` in the main repo.

**PR required for ALL non-planning changes** (MANDATORY): Every change to scripts, agents, configs, workflows, or any file outside `TODO.md`, `todo/`, and `VERIFY.md` MUST go through a worktree + PR + CI pipeline — no matter how small. "It's just one line" is not a valid reason to skip CI. The pre-edit-check script enforces this; never bypass it by editing directly on main.

**Task ID allocation** (MANDATORY): Use `/new-task` or `claim-task-id.sh` to allocate task IDs. NEVER manually scan TODO.md with grep to determine the next ID — this causes collisions in parallel sessions. The allocation flow:

1. `/new-task "Task title"` — interactive slash command (preferred in sessions)
2. `planning-commit-helper.sh next-id --title "Task title"` — wrapper function
3. `claim-task-id.sh --title "Task title" --repo-path "$(pwd)"` — direct script

**Atomic counter** (t1047): Task IDs are allocated from `.task-counter` — a single file in the repo root containing the next available integer. The allocation uses a CAS (compare-and-swap) loop: fetch counter from `origin/main`, increment, commit, push. If push fails (another session grabbed an ID), retry from fetch. This guarantees no two sessions can claim the same ID. Batch allocation: `--count N` claims N consecutive IDs in one atomic push. GitHub/GitLab issue creation happens after the ID is secured (optional, non-blocking). Offline fallback reads local `.task-counter` + 100 offset (reconcile when back online). Output format: `task_id=tNNN ref=GH#NNN` (offline: `ref=offline reconcile=true`; batch: adds `task_id_last=tNNN task_count=N`).

**Task ID collision prevention**: The `.task-counter` CAS loop handles this automatically. If push fails, the script retries (up to 10 attempts with backoff). No manual intervention needed.

**Full docs**: `workflows/plans.md`, `tools/task-management/beads.md`

## Model Routing

Cost-aware routing matches task complexity to the optimal model tier. Use the cheapest model that produces acceptable quality.

**Tiers**: `haiku` (classification, formatting) → `flash` (large context, summarization) → `sonnet` (code, default) → `pro` (large codebase + reasoning) → `opus` (architecture, novel problems)

**Subagent frontmatter**: Add `model: <tier>` to YAML frontmatter. The supervisor resolves this to a concrete model during headless dispatch, with automatic cross-provider fallback.

**Commands**: `/route <task>` (suggest optimal tier with pattern data), `/compare-models` (side-by-side pricing/capabilities)

**Pre-dispatch availability**: `model-availability-helper.sh check <provider>` — cached health probes (~1-2s) verify providers are responding before dispatch. Exit codes: 0=available, 1=unavailable, 2=rate-limited, 3=invalid-key.

**Fallback chains**: Each tier has a primary model and cross-provider fallback (e.g., opus: claude-opus-4 → o3). The supervisor and `fallback-chain-helper.sh` handle this automatically.

**Budget-aware routing** (t1100): Two strategies based on billing model:

- **Token-billed APIs** (Anthropic direct, OpenRouter): Track daily spend per provider. Proactively degrade to cheaper tier when approaching budget cap (e.g., 80% of daily opus budget spent → route remaining to sonnet unless critical).
- **Subscription APIs** (OAuth with periodic allowances): Maximise utilisation within period. Prefer subscription providers when allowance is available to avoid token costs. Alert when approaching period limit.

**CLI**: `budget-tracker-helper.sh [record|check|recommend|status|configure|burn-rate]`

**Quick setup**:

```bash
# Configure Anthropic with $50/day budget
budget-tracker-helper.sh configure anthropic --billing-type token --daily-budget 50

# Configure OpenCode as subscription with monthly allowance
budget-tracker-helper.sh configure opencode --billing-type subscription
budget-tracker-helper.sh configure-period opencode --start 2026-02-01 --end 2026-03-01 --allowance 200
```

**Integration**: Dispatch.sh checks budget state before model selection. Spend is recorded automatically after each worker evaluation.

**Full docs**: `tools/context/model-routing.md`, `tools/ai-assistants/compare-models.md`

## Memory

Cross-session SQLite FTS5 memory. Commands: `/remember {content}`, `/recall {query}`, `/recall --recent`

**CLI**: `memory-helper.sh [store|recall|log|stats|prune|consolidate|export|graduate]`

**Session distillation**: `session-distill-helper.sh auto` (extract learnings at session end)

**Auto-capture log**: `/memory-log` or `memory-helper.sh log` (review auto-captured memories)

**Graduation**: `/graduate-memories` or `memory-graduate-helper.sh` — promote validated memories into shared docs so all users benefit. Memories qualify at high confidence or 3+ accesses.

**Semantic search** (opt-in): `memory-embeddings-helper.sh setup --provider local` enables vector similarity search. Use `--semantic` or `--hybrid` flags with recall for meaning-based search beyond keywords.

**Memory audit**: `memory-audit-pulse.sh run` — periodic hygiene (dedup, prune, graduate, scan for improvement opportunities). Runs automatically as Phase 9 of the supervisor pulse cycle.

**Namespaces**: Runners can have isolated memory via `--namespace <name>`. Use `--shared` to also search global memory. List with `memory-helper.sh namespaces`.

**Auto-recall**: Memories are automatically recalled at key entry points:
- **Interactive session start**: Recent memories (last 5) surface via conversation-starter.md
- **Session resume**: After loading checkpoint, recent memories provide context
- **Runner dispatch**: Before task execution, runners recall recent + task-specific memories
- **Objective runner**: On first step, recalls recent + objective-specific + failure pattern memories

Auto-recall is silent (no output if no memories found) and uses namespace isolation for runners.

**Full docs**: `memory/README.md`

**Proactive memory**: When you detect solutions, preferences, workarounds, failed approaches, or decisions — proactively suggest `/remember {description}`. Use `memory-helper.sh store --auto` for auto-captured memories. Privacy: `<private>` blocks stripped, secrets rejected.

## Pattern Tracking

Track success/failure patterns across task types, models, and approaches. Patterns feed into model routing recommendations for data-driven dispatch.

**CLI**: `pattern-tracker-helper.sh [record|suggest|recommend|analyze|stats|report|export]`

**Commands**: `/patterns <task>` (suggest approach), `/patterns report` (full report), `/patterns recommend <type>` (model recommendation)

**Automatic capture**: The supervisor stores `SUCCESS_PATTERN` and `FAILURE_PATTERN` entries after each task evaluation, tagged with model tier, duration, and retry count.

**Integration with model routing**: `/route <task>` combines routing rules with pattern history. If pattern data shows >75% success rate with 3+ samples for a tier, it is weighted heavily in the recommendation.

**Full docs**: `memory/README.md` "Pattern Tracking" section, `scripts/commands/patterns.md`

## Inter-Agent Mailbox

SQLite-backed async communication between parallel agent sessions.

**CLI**: `mail-helper.sh [send|check|read|archive|prune|status|register|deregister|agents|migrate]`

**Message types**: task_dispatch, status_report, discovery, request, broadcast

**Lifecycle**: send → check → read → archive (history preserved, prune is manual)

**Runner integration**: Runners automatically check inbox before work and send status reports after. Unread messages are prepended as context to the runner's prompt.

**Storage**: `mail-helper.sh prune` shows storage report. Use `--force` to delete old archived messages. Migration from TOON files runs automatically on `aidevops update`.

## MCP On-Demand Loading

MCPs disabled globally, enabled per-agent via YAML frontmatter.

**Discovery**: `mcp-index-helper.sh search "capability"` or `mcp-index-helper.sh get-mcp "tool-name"`

**Full docs**: `tools/context/mcp-discovery.md`

## Git Workflow

**Before edits**: Run pre-edit check (see top of file).

**After branch creation**:
1. Check TODO.md for matching tasks, record `started:` timestamp
2. Call `session-rename_sync_branch` tool
3. Read `workflows/git-workflow.md` for full guidance

**Worktrees** (preferred for parallel work):

```bash
wt switch -c feature/my-feature   # Worktrunk (preferred)
worktree-helper.sh add feature/x  # Fallback
```

**After switching to a worktree**: Re-read any file at its worktree path before editing. The Edit tool tracks reads by exact absolute path — a read from the main repo path does NOT satisfy the worktree path.

**After completing changes**, offer: 1) Preflight checks 2) Skip preflight 3) Continue editing

**PR title format** (MANDATORY): All PRs MUST include task ID from TODO.md: `{task-id}: {description}`. For unplanned work (hotfix, quick fix), create TODO entry first with `~15m` estimate, then create PR. No work should be untraceable. See `workflows/git-workflow.md` "PR Title Requirements" for full guidance.

**Branch types**: `feature/`, `bugfix/`, `hotfix/`, `refactor/`, `chore/`, `experiment/`, `release/`

**Worktree ownership** (CRITICAL): NEVER remove a worktree unless (a) you created it in this session, (b) it belongs to a task in your active batch, AND the task is deployed/complete, or (c) the user explicitly asks. Worktrees may belong to parallel sessions — removing them destroys another agent's working directory mid-work. When cleaning up, only touch worktrees for tasks you personally merged. Use `git worktree list` to see all worktrees but do NOT assume unrecognized ones are safe to remove. The ownership registry (`worktree-helper.sh registry list`) tracks which PID owns each worktree — `remove` and `clean` commands automatically refuse to touch worktrees owned by other live processes.

**Safety hooks** (Claude Code only): Destructive commands (`git reset --hard`, `rm -rf`, etc.) are blocked by a PreToolUse hook. Run `install-hooks.sh --test` to verify. See `workflows/git-workflow.md` "Destructive Command Safety Hooks" section.

**Full docs**: `workflows/git-workflow.md`, `tools/git/worktrunk.md`

## Autonomous Orchestration

**CLI**: `opencode` is the ONLY supported CLI for worker dispatch. Never use `claude` CLI.

**Supervisor** (`supervisor-helper.sh`): Manages parallel task execution with SQLite state machine.

```bash
# Add tasks and create batch
supervisor-helper.sh add t001 --repo "$(pwd)" --description "Task description"
supervisor-helper.sh batch "my-batch" --concurrency 3 --tasks "t001,t002,t003"

# Task claiming (t165 — provider-agnostic, TODO.md primary)
supervisor-helper.sh claim t001     # Adds assignee: to TODO.md, optional GH sync
supervisor-helper.sh unclaim t001   # Releases claim (removes assignee:)
# Claiming is automatic during dispatch. Manual claim/unclaim for coordination.

# Install pulse scheduler (REQUIRED for autonomous operation)
# macOS: installs ~/Library/LaunchAgents/com.aidevops.supervisor-pulse.plist
# Linux: installs crontab entry
supervisor-helper.sh cron install

# Manual pulse (scheduler does this automatically every 2 minutes)
supervisor-helper.sh pulse --batch <batch-id>

# Monitor
supervisor-helper.sh dashboard --batch <batch-id>
supervisor-helper.sh status <batch-id>
```

**Task claiming** (t165): TODO.md `assignee:` field is the authoritative claim source. Works offline, with any git host. GitHub Issue sync is optional best-effort (requires `gh` CLI + `ref:GH#` in TODO.md). GH Issue creation is opt-in: use `--with-issue` flag or `SUPERVISOR_AUTO_ISSUE=true`.

**Assignee ownership** (t1017): NEVER remove or change `assignee:` on a task without explicit user confirmation. The assignee may be a contributor on another host whose work you cannot see. `unclaim` requires `--force` to release a task claimed by someone else. The full-loop claims the task automatically before starting work — if the task is already claimed by another, the loop stops.

**Pulse scheduler is mandatory** for autonomous operation. Without it, the supervisor is passive and requires manual `pulse` calls. The pulse cycle: check workers -> evaluate outcomes -> dispatch next -> cleanup. On macOS, `cron install` uses launchd (no cron dependency); on Linux, it uses crontab.

**Session memory monitoring + respawn** (t264, t264.1): Long-running OpenCode/Bun sessions accumulate WebKit malloc dirty pages that are never returned to the OS (25GB+ observed). Phase 11 of the pulse cycle checks the parent session's `phys_footprint` when a batch wave completes (no running/queued tasks). If memory exceeds `SUPERVISOR_SELF_MEM_LIMIT` (default: 8192MB), it saves a checkpoint, logs the respawn event to `~/.aidevops/logs/respawn-history.log`, and exits cleanly for the next cron pulse to start fresh. Use `supervisor-helper.sh mem-check` to inspect memory and `supervisor-helper.sh respawn-history` to review respawn patterns.

**Full docs**: `tools/ai-assistants/headless-dispatch.md`, `supervisor-helper.sh help`

## Session Completion

Run `/session-review` before ending. Suggest new sessions after PR merge, domain switch, or 3+ hours.

**Cleanup**: Commit/stash changes, run `wt merge` to clean merged worktrees.

**Full docs**: `workflows/session-manager.md`

## Context Compaction Resilience

When context is compacted (long sessions, autonomous loops), operational state is lost unless persisted to disk. Use `/checkpoint` to save and restore session state.

**Commands**:

- `/checkpoint` or `session-checkpoint-helper.sh save --task <id> --next <ids>` — save current state
- `session-checkpoint-helper.sh load` — reload state after compaction
- `session-checkpoint-helper.sh continuation` — generate a full continuation prompt for new sessions

**When to checkpoint**: After each task completion, before large operations, after PR creation/merge.

**Compaction survival rule**: See `prompts/build.txt` "Context Compaction Survival".

**Full docs**: `workflows/session-manager.md` "Compaction Resilience" section

## Agents & Subagents

See `subagent-index.toon` for complete listing of agents, subagents, workflows, and scripts.

**Strategy**: Read subagents on-demand when tasks require domain expertise. This keeps context focused.

**Agent tiers** (user-created agents survive `aidevops update`):

| Tier | Location | Purpose |
|------|----------|---------|
| **Draft** | `~/.aidevops/agents/draft/` | R&D, experimental, auto-created by orchestration tasks |
| **Custom** | `~/.aidevops/agents/custom/` | User's permanent private agents |
| **Shared** | `.agents/` in repo | Open-source, distributed to all users |

Orchestration agents can create drafts in `draft/` for reusable parallel processing context. See `tools/build-agent/build-agent.md` for the full lifecycle and promotion workflow.

**Progressive disclosure by domain**:

| Domain | Read |
|--------|------|
| Planning | `workflows/plans.md`, `tools/task-management/beads.md` |
| Accessibility | `services/accessibility/accessibility-audit.md`, `tools/accessibility/accessibility.md`, `accessibility-helper.sh` |
| Code quality | `tools/code-review/code-standards.md` |
| Documents | `tools/document/document-creation.md` (conversion, creation, templates), `document-creation-helper.sh`, `tools/pdf/overview.md`, `tools/conversion/pandoc.md`, `tools/conversion/mineru.md`, `tools/document/document-extraction.md` |
| Git/PRs | `workflows/git-workflow.md`, `tools/git/github-cli.md`, `tools/git/conflict-resolution.md`, `tools/git/lumen.md` |
| Releases | `workflows/release.md`, `workflows/version-bump.md` |
| Browser | `tools/browser/browser-automation.md` (decision tree, then tool-specific subagent) |
| Mobile app dev | `mobile-app-dev.md` (orchestrator), `mobile-app-dev/planning.md`, `mobile-app-dev/expo.md`, `mobile-app-dev/swift.md`, `mobile-app-dev/ui-design.md`, `mobile-app-dev/testing.md`, `mobile-app-dev/publishing.md`, `mobile-app-dev/monetisation.md`, `mobile-app-dev/onboarding.md`, `mobile-app-dev/analytics.md`, `mobile-app-dev/backend.md`, `mobile-app-dev/notifications.md`, `mobile-app-dev/assets.md` |
| Mobile tools | `tools/mobile/agent-device.md`, `tools/mobile/xcodebuild-mcp.md`, `tools/mobile/axe-cli.md`, `tools/mobile/maestro.md`, `tools/mobile/ios-simulator-mcp.md`, `tools/mobile/minisim.md` |
| Browser extensions | `browser-extension-dev.md` (orchestrator), `browser-extension-dev/development.md`, `browser-extension-dev/testing.md`, `browser-extension-dev/publishing.md`, `tools/browser/chrome-webstore-release.md`, `tools/ui/wxt.md` |
| Design inspiration | `tools/design/design-inspiration.md` (60+ UI/UX resources: Mobbin, Screenlane, Dribbble, Awwwards, etc.) |
| Payments | `services/payments/revenuecat.md` (mobile subscriptions), `services/payments/stripe.md` (web/extension payments), `services/payments/superwall.md` (paywall A/B testing) |
| Email | `tools/ui/react-email.md` (templates), `services/email/email-testing.md` (delivery testing) |
| WordPress | `tools/wordpress/wp-dev.md`, `tools/wordpress/mainwp.md` |
| SEO | `seo/dataforseo.md`, `seo/google-search-console.md` |
| Content | `content.md` (orchestrator), `content/research.md`, `content/story.md`, `content/production/`, `content/distribution/`, `content/optimization.md` |
| Video | `tools/video/video-prompt-design.md`, `tools/video/remotion.md`, `tools/video/higgsfield.md`, `tools/video/runway.md`, `tools/video/wavespeed.md` (200+ models), `wavespeed-helper.sh`, `tools/video/muapi.md` (multimodal: image/video/audio/VFX/workflows/agents), `muapi-helper.sh`, `tools/video/real-video-enhancer.md` (upscale/interpolate/denoise), `real-video-enhancer-helper.sh` |
| YouTube | `content/distribution/youtube/` (migrated from root, see content.md) |
| Vision | `tools/vision/overview.md` (decision tree, then `image-generation.md`, `image-understanding.md`, `image-editing.md`) |
| ComfyUI | `tools/ai-generation/comfy-cli.md`, `comfy-cli-helper.sh` |
| Voice | `tools/voice/speech-to-speech.md`, `voice-helper.sh talk` (voice bridge) |
| Email testing | `services/email/email-testing.md` (overview), `services/email/email-design-test.md`, `services/email/email-delivery-test.md`, `email-test-suite-helper.sh` |
| Multi-org | `services/database/multi-org-isolation.md` (schema, RLS, context model), `multi-org-helper.sh` |
| Encryption | `tools/credentials/encryption-stack.md` (decision tree), `tools/credentials/sops.md`, `tools/credentials/gocryptfs.md`, `tools/credentials/gopass.md` |
| Security | `tools/security/tirith.md` (terminal guard), `tools/security/shannon.md` (pentesting), `tools/security/ip-reputation.md` (IP reputation), `tools/security/cdn-origin-ip.md` (CDN origin leak), `/ip-check <ip>`, `aidevops ip-check` |
| Cloud GPU | `tools/infrastructure/cloud-gpu.md` |
| Containers | `tools/containers/orbstack.md` |
| Networking | `services/networking/tailscale.md` |
| Localhost | `services/hosting/local-hosting.md` (primary — localdev-helper.sh, dnsmasq, Traefik, mkcert, port registry), `services/hosting/localhost.md` (legacy reference) |
| Personal AI | `tools/ai-assistants/openclaw.md` (deployment tiers, security, channels) |
| Research | `tools/research/tech-stack-lookup.md`, `tech-stack-helper.sh`, `/tech-stack` (tech stack detection, reverse lookup) |
| Model routing | `tools/context/model-routing.md`, `model-registry-helper.sh`, `fallback-chain-helper.sh`, `model-availability-helper.sh`, `budget-tracker-helper.sh` |
| Model comparison | `tools/ai-assistants/compare-models.md`, `tools/ai-assistants/response-scoring.md`, `/compare-models`, `/compare-models-free`, `/score-responses` |
| Pattern tracking | `memory/README.md` "Pattern Tracking", `pattern-tracker-helper.sh`, `scripts/commands/patterns.md` |
| Self-improvement | `aidevops/self-improving-agents.md`, `self-improve-helper.sh` (analyze → refine → test → pr) |
| Parallel agents | `tools/ai-assistants/headless-dispatch.md`, `tools/ai-assistants/runners/` |
| Orchestration | `supervisor-helper.sh` (batch dispatch, cron pulse, self-healing), `/runners-check` (quick queue status) |
| MCP dev | `tools/build-mcp/build-mcp.md` |
| Agent design | `tools/build-agent/build-agent.md` |
| Skills | `scripts/commands/skills.md`, `skills-helper.sh` (search, browse, describe, recommend), `/skills` |
| Framework | `aidevops/architecture.md` |

<!-- AI-CONTEXT-END -->

## Getting Started

**CLI**: `aidevops [init|update|auto-update|status|repos|skill|skills|detect|features|uninstall]`. See `/onboarding` for setup wizard.

## Auto-Update

Automatic polling for new releases. Checks GitHub every 10 minutes and runs `aidevops update` when a new version is available. Safe to run while AI sessions are active.

**CLI**: `aidevops auto-update [enable|disable|status|check|logs]`

**Enable**: `aidevops auto-update enable` (also offered during `setup.sh`)

**Disable**: `aidevops auto-update disable`

**Scheduler**: macOS uses launchd (`~/Library/LaunchAgents/com.aidevops.auto-update.plist`); Linux uses cron. Auto-migrates existing cron entries on macOS when `enable` is run.

**Env override**: `AIDEVOPS_AUTO_UPDATE=false` disables even if scheduler is installed.

**Logs**: `~/.aidevops/logs/auto-update.log`

**Daily skill refresh**: Each auto-update check also runs a 24h-gated skill freshness check. If >24h have passed since the last check, `skill-update-helper.sh --auto-update --quiet` pulls upstream changes for all imported skills. State is tracked in `~/.aidevops/cache/auto-update-state.json` (`last_skill_check`, `skill_updates_applied`). Disable with `AIDEVOPS_SKILL_AUTO_UPDATE=false`; adjust frequency with `AIDEVOPS_SKILL_FRESHNESS_HOURS=<hours>` (default: 24). View skill check status with `aidevops auto-update status`.

**Repo version wins on update**: When `aidevops update` runs, shared agents in `~/.aidevops/agents/` are overwritten by the repo version. Only `custom/` and `draft/` directories are preserved. Imported skills stored outside these directories will be overwritten. To keep a skill across updates, either re-import it after each update or move it to `custom/`.

## Repo Sync

Automatic daily `git pull` for all git repos in configured parent directories. Keeps local clones up to date without manual intervention. Safe by design: only fast-forward pulls on clean, default-branch checkouts.

**CLI**: `aidevops repo-sync [enable|disable|status|check|dirs|config|logs]`

**Enable**: `aidevops repo-sync enable` (also offered during `/onboarding`)

**Disable**: `aidevops repo-sync disable`

**One-shot sync**: `aidevops repo-sync check` (runs immediately, no scheduler needed)

**Scheduler**: macOS uses launchd (`~/Library/LaunchAgents/com.aidevops.aidevops-repo-sync.plist`); Linux uses cron (daily at 3am).

**Env overrides**:

- `AIDEVOPS_REPO_SYNC=false` — disable even if scheduler is installed
- `AIDEVOPS_REPO_SYNC_INTERVAL=1440` — minutes between syncs (default: 1440 = daily)

**Configuration** (`~/.config/aidevops/repos.json`):

```json
{"git_parent_dirs": ["~/Git", "~/Projects"]}
```

Default: `~/Git`. Manage with:

```bash
aidevops repo-sync dirs list           # Show configured directories
aidevops repo-sync dirs add ~/Projects # Add a parent directory
aidevops repo-sync dirs remove ~/Old   # Remove a parent directory
aidevops repo-sync config              # Show current config
```

**Safety**: Only runs `git pull --ff-only`. Skips repos with dirty working trees, repos not on their default branch, repos with no remote, and git worktrees (only main checkouts are synced).

**Logs**: `~/.aidevops/logs/repo-sync.log` — view with `aidevops repo-sync logs [--tail N]` or `aidevops repo-sync logs --follow`.

**Status**: `aidevops repo-sync status` — shows scheduler state, configured directories, and last sync results (pulled/skipped/failed counts).

## Bot Reviewer Feedback

AI suggestion verification: see `prompts/build.txt`. Dismiss incorrect suggestions with evidence; address valid ones.

## Quality Workflow

```text
Development → @code-standards → /code-simplifier → /linters-local → /pr review → /postflight
```

**Quick commands**: `linters-local.sh` (pre-commit), `/pr review` (full), `version-manager.sh release [type]`

## Skills & Cross-Tool

Import community skills: `aidevops skill add <source>` (→ `*-skill.md` suffix)

**Discover skills**: `aidevops skills` or `/skills` in chat. Search, browse by category, get detailed descriptions, and get task-based recommendations.

**Commands**: `aidevops skills search <query>`, `aidevops skills browse <category>`, `aidevops skills describe <name>`, `aidevops skills categories`, `aidevops skills recommend "<task>"`, `aidevops skills list [--imported]`

**Online registry search**: Search the public [skills.sh](https://skills.sh/) registry for community skills:

```bash
aidevops skills search --registry "browser automation"
aidevops skills search --online "seo"
aidevops skills install vercel-labs/agent-browser@agent-browser
```

When local search returns no results, the `/skills` command suggests searching the public registry automatically.

**Cross-tool**: Claude marketplace plugin, Agent Skills (SKILL.md), Claude Code agents, manual AGENTS.md reference.

**Skill persistence**: Imported skills are stored in `~/.aidevops/agents/` and tracked in `configs/skill-sources.json`. The daily auto-update skill refresh (see Auto-Update above) keeps them current from upstream. Note: `aidevops update` overwrites shared agent files — only `custom/` and `draft/` survive. Re-import skills after an update, or place them in `custom/` for persistence.

**Full docs**: `scripts/commands/add-skill.md`, `scripts/commands/skills.md`

## Security

Security rules: see `prompts/build.txt`. Additional details:

- Config templates: `configs/*.json.txt` (committed), working: `configs/*.json` (gitignored)

**Full docs**: `tools/credentials/gopass.md`, `tools/credentials/api-key-setup.md`

## Working Directories

Working directory tree: see `prompts/build.txt`. Agent file locations:

- `~/.aidevops/agents/custom/` — User's permanent private agents (survives updates)
- `~/.aidevops/agents/draft/` — R&D, experimental agents (survives updates)
- `~/.aidevops/agents/` — Shared agents (deployed from repo, overwritten on update)

## Browser Automation

Proactively use a browser for: dev server verification, form testing, deployment checks, frontend debugging. Read `tools/browser/browser-automation.md` for tool selection. Quick default: Playwright for dev testing, dev-browser for persistent login.

**CRITICAL: Never use curl/HTTP to verify frontend fixes.** Server returns 200 even when React crashes client-side because error boundaries render successfully. The crash happens during hydration which curl never executes. Always use browser screenshots (dev-browser agent, Playwright) to verify frontend fixes work.

## Localhost Standards

`.local` domains + SSL via Traefik + mkcert. See `services/hosting/local-hosting.md` (primary) or `services/hosting/localhost.md` (legacy).
