---
description: Master git workflow orchestrator - read when coding work begins
mode: subagent
tools:
  read: true
  write: false
  edit: false
  bash: true
  glob: true
  grep: true
  webfetch: false
  task: true
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Git Workflow Orchestrator

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Principle**: Every change on a branch, never directly on main. Release/version-manager commands are allowed on `main` only after merged, verified changes and explicit user approval.
- **CRITICAL**: With parallel sessions, ALWAYS verify branch state before ANY file operation

**Pre-Edit Gate** (MANDATORY before ANY file edit/write/create):

```bash
git branch --show-current  # If result is `main` → STOP
```

If on `main`: STOP. Present branch options before proceeding. Exception: proceed for an approved release/version-manager command after verifying the working tree is clean and up to date with `origin/main`.

**First Actions** (before any code changes):

```bash
git fetch origin && git status --short
git log --oneline HEAD..origin/$(git branch --show-current) 2>/dev/null
```

Remote has new commits → pull/rebase first. Uncommitted local changes → stash or commit first.

**Worktrees** (DEFAULT for all feature work):

Main repo (`~/Git/{repo}/`) ALWAYS stays on `main`. All work in worktree directories under `~/Git/`; do not create durable implementation worktrees in runtime temp paths such as macOS `/var/folders/.../T/opencode/`.

```bash
${AIDEVOPS_DIR:-$HOME/.aidevops}/agents/scripts/worktree-helper.sh add feature/my-feature
# Creates: ~/Git/{repo}-feature-my-feature/
```

Non-git artifacts (`.venv/`, `node_modules/`, `dist/`, `.env`) don't transfer between worktrees — recreate in each. See `workflows/worktree.md`.

**Session-Branch Tracking**: After creating a branch for issue/PR work, title the session with the work item first (`Issue #123: succinct description` or `PR #456: succinct description`) so Tabby tabs and OpenCode search group by number. Use `session-rename_sync_branch` only when there is no issue/PR context or no meaningful title yet.

**Scope Monitoring**: When work evolves significantly from branch name/purpose, offer to create a new branch, continue on current, or stash and switch.

<!-- AI-CONTEXT-END -->

## Decision Tree

| Situation | Action |
|-----------|--------|
| On `main` branch | Create worktree — see `branch.md` for type selection |
| On feature/bugfix branch | Continue, follow `branch.md` lifecycle |
| Issue URL pasted | Parse and create appropriate branch (see Issue URL Handling) |
| Non-owner repo | Fork workflow — see `pr.md` |
| New empty repo | `git init && git checkout -b main`; suggest `release/0.1.0` (new), `release/1.0.0` (MVP), or `release/X.Y.Z` (existing) |

## Time Tracking

Record timestamps in TODO.md or PLANS.md. **Worker restriction**: Headless workers must NOT edit TODO.md — supervisor handles updates. See `workflows/plans.md`.

| Event | Field |
|-------|-------|
| Branch created | `started:` |
| Work session ends | `logged:` (cumulative) |
| PR merged | `completed:` |
| Release published | `actual:` |

## Branch Naming from Planning Files

Lookup: `grep -i "{keyword}" TODO.md todo/PLANS.md 2>/dev/null` and `ls todo/tasks/*{keyword}* 2>/dev/null`.

| Source | Pattern | Example |
|--------|---------|---------|
| TODO.md task | `{type}/{slugified-description}` | `feature/add-ahrefs-mcp-server` |
| PLANS.md / PRD | `{type}/{plan-or-feature-slug}` | `feature/user-authentication-overhaul` |

Slugification: lowercase, hyphens for spaces, remove special chars, truncate ~50 chars. Branch type selection: see `branch.md`.

## Issue URL Handling

Parse issue URLs to extract platform, owner, repo, and issue number, then create a worktree:

```bash
# Clone if not local: gh repo clone {owner}/{repo} ~/Git/{repo}
git checkout main && git pull origin main
${AIDEVOPS_DIR:-$HOME/.aidevops}/agents/scripts/worktree-helper.sh add {type}/{issue_number}-{slug-from-title}
```

Supported: `github.com`, `gitlab.com`, and Gitea (`{domain}/{owner}/{repo}/issues/{num}`).

**Repository ownership**: If `git remote get-url origin` owner differs from `gh api user --jq '.login'`, use fork workflow — see `workflows/pr.md`.

## Destructive Command Safety Hooks

Claude Code PreToolUse hooks block destructive git/filesystem commands before execution.

**Blocked**: `git checkout -- <files>`, `git restore <files>`, `git reset --hard`, `git clean -f`, `git push --force`/`-f`, `git branch -D`, `rm -rf` (non-temp), `git stash drop/clear`.

**Safe (allowlisted)**: `git checkout -b`, `git restore --staged`, `git clean -n`/`--dry-run`, `rm -rf /tmp/...`, `git push --force-with-lease`.

Management: `install-hooks-helper.sh [status|install|test|uninstall]`. Files: `~/.aidevops/hooks/git_safety_guard.py`, `~/.claude/settings.json`. Installed by `setup.sh`. Requires Python 3 + Claude Code restart.

**Limitations**: Regex-based; obfuscated commands may bypass. Safety net for honest mistakes, not a security boundary.

## Post-Change Workflow

After file changes: run preflight automatically. Pass → auto-commit with suggested message (confirm or override). Fail → show issues, offer fixes. After commit → auto-push, offer: create PR, continue working, or done.

**PR Title (MANDATORY)**: `{task-id}: {description}`. Task ID is `tNNN` (from TODO.md) or `GH#NNN` (GitHub issue number, for quality-debt/simplification-debt/issue-only work). Examples: `t318: Update PR workflow documentation`, `GH#12455: tighten hashline-edit-format.md`. NEVER use `qd-`, bare numbers, or invented prefixes. NEVER invent suffixes or variants either — `t2213b`, `t2213-2`, `t2213.fix`, `t2213-followup` are all forbidden. Task IDs come EXCLUSIVELY from `claim-task-id.sh` output; for follow-up work, claim a FRESH ID. For unplanned work: create TODO entry first.

**If changes include `.agents/` files**: Offer to run `./setup.sh` to deploy to `~/.aidevops/agents/`.

## Branch Cleanup

After postflight, delete merged branches. Keep unmerged unless stale (>30 days) — ask user. Prefer the aidevops cleanup route for remote branch sweeps because it checks merged/open-PR/worktree evidence before deletion.

```bash
git checkout main && git pull origin main
wt prune                                      # Local worktrees
aidevops cleanup remote-branches             # Dry-run remote audit
aidevops cleanup remote-branches --apply     # Delete safe remote candidates
git remote prune origin
```

## Override Handling

When user wants to work directly on main, acknowledge and proceed — never block. Note trade-offs (harder rollback, no PR review, harder collaboration) and continue.

## Database Schema Changes

See `workflows/sql-migrations.md`. **Critical rules**: Never modify pushed/deployed migrations — create new ones. Always commit schema + migration together. Always review generated migrations before committing. Branch naming: `feature/add-{table}-table`, `bugfix/fix-{description}`, `chore/backfill-{description}`.

## Related Workflows

| Workflow | When to Read |
|----------|--------------|
| `branch.md` | Branch naming, type selection, creation, lifecycle |
| `worktree.md` | Worktree creation, management, cleanup |
| `pr.md` | PR creation, review, merge, fork workflow |
| `preflight.md` | Quality checks before push |
| `postflight.md` | Verification after release |
| `version-bump.md` | Version management, release branches |
| `release.md` | Full release process |
| `sql-migrations.md` | Database schema version control |
| `tools/git/lumen.md` | AI-powered diffs, commit messages |
| `tools/security/opsec.md` | CI/CD AI agent security |

**Platform CLIs**: GitHub (`gh`), GitLab (`glab`), Gitea (`tea`). See `tools/git.md` for detailed usage.

## Extracted AGENTS.md Git Workflow Rules

Source: extracted from `.agents/AGENTS.md` Framework Rules and User Guide Git Workflow sections (Phase 3 of #22616 — progressive-disclosure decomposition). Read this section before creating worktrees/branches, claiming or releasing issues, writing PR bodies, handling parent-task PR keywords, reasoning about origin labels, or diagnosing auto-merge / dispatch-dedup behaviour.

## AGENTS.md Framework Rules Git Workflow

Git is the audit trail. Procedures: see the "## AGENTS.md User Guide Git Workflow" section below.

**Origin labelling (MANDATORY):**

- NEVER use raw `gh pr create` or `gh issue create` directly. Always use the wrappers: `gh_create_pr` and `gh_create_issue` (defined in `shared-constants.sh`, sourced via PATH). The wrappers automatically apply `origin:interactive` or `origin:worker` based on the session context. Raw `gh` calls produce unlabelled PRs that the pulse may auto-close.
- If `gh_create_pr` is unavailable (e.g. not sourced), pass `--label origin:interactive` explicitly when creating PRs in an interactive session.

**Interactive issue ownership (MANDATORY — AI-driven, t2056):**

When an interactive session engages with a GitHub issue — opening a worktree, claiming a task, or user identifies one — you MUST IMMEDIATELY call `interactive-session-helper.sh claim <N> <slug>`. Applies `status:in-review` + self-assign + crash-recovery stamp. No worker will dispatch while set. Do NOT assume `origin:interactive` alone is enough.

**Eager stamp creation (t2943):** `claim-task-id.sh` now atomically writes the crash-recovery stamp immediately when it self-assigns a newly created interactive task (via `_auto_assign_issue` → `interactive-session-helper.sh write-stamp`). This eliminates the historical stampless-claim window where `_auto_assign_issue` self-assigned but the subsequent `interactive-session-helper.sh claim` call failed. The explicit `interactive-session-helper.sh claim` call is still needed when picking up an EXISTING issue mid-lifecycle (the eager stamp only fires on new task creation); the claim step is now only mandatory for mid-lifecycle pickup, not immediately after `claim-task-id.sh`.

SCOPE LIMITATION (GH#19861): `claim` blocks dispatch path ONLY — not enrich, completion-sweep, or other pulse paths. For full insulation, use `lockdown` instead: `no-auto-dispatch` + `status:in-review` + conversation lock + audit comment.

- Release is YOUR responsibility, not the user's. When the user signals completion ("ship it", "I'm done", "moving on", "let a worker take over"), or when they switch to a different issue, call `interactive-session-helper.sh release <N> <slug>`. Never make the user type a release command. **PR merge auto-release (t2413):** when `pulse-merge.sh` merges an `origin:interactive` PR with a `Resolves #NNN` link and a claim stamp exists, `_release_interactive_claim_on_merge` fires automatically — no manual release required on merge. Manual release is still needed for task abandonment or mid-stream task switches.
- On every interactive session start, run `interactive-session-helper.sh scan-stale` and, if any dead claims surface, prompt the user to release them. Act on confirmation.
- Offline `gh` → the helper warns once and exits 0. Continue the session. A collision with a worker is harmless — the interactive work naturally becomes its own issue/PR.
- `/release-issue <N>` and `aidevops issue release <N>` exist as fallbacks only; the agent should never punt to them. Detect intent and act.

**Traceability (MANDATORY):**

- PR title MUST have task ID (`{task-id}: {description}`). No exceptions.
- NEVER invent task ID suffixes or variants — `t2213b`, `t2213-2`, `t2213.fix`, `t2213-followup` are all forbidden. Task IDs come EXCLUSIVELY from `claim-task-id.sh` output. For follow-up work on a merged task, claim a FRESH task ID via `claim-task-id.sh` — don't extend the old one. NEVER prefix `--title` with a `tNNN:` when calling `claim-task-id.sh` — always let the helper inject the claimed ID. Titles must describe the work, not assert an ID.
- **PR bodies MUST use `Resolves #NNN`** to link the PR to its issue. GitHub only creates the sidebar "Development" link (PR↔issue) when the PR body contains a closing keyword (`Closes`, `Fixes`, `Resolves`). Without it, the audit trail is broken — you can navigate from issue→commit but not issue↔PR. `Resolves` only triggers closure when the PR *merges*, so there is no risk of premature closure.
- **Planning-only commits** (TODO entries, briefs, docs) must use `For #NNN` or `Ref #NNN` — these reference the issue without triggering GitHub's auto-close. NEVER use `Closes`/`Fixes` in commits that only touch TODO.md or todo/*.
- **Code fix commit messages** may use `Fixes #NNN` — auto-closes when merged to the default branch. The dedup system checks commit messages to detect in-progress work.
- **Markdown formatting is INVISIBLE to the extraction regex (t2204).** `_extract_linked_issue` in `pulse-merge.sh` runs a plain `grep -ioE '(close[ds]?|fix(es|ed)?|resolve[ds]?)\s+#[0-9]+'` against the raw PR body. Backticks, code fences, blockquotes, HTML comments, and link text DO NOT shield closing keywords from the match. Writing `` `Closes #NNN` `` (as reference text), `> Resolves #NNN` (in a quote), or `[Fixes #NNN](url)` (as link text) in a planning-PR body will auto-close the issue on merge — the regex sees the literal string, not the formatting. If you must reference a closing keyword in narrative prose, rephrase: "the fix PR will use a closing keyword", "will resolve with a Closes-keyword", or split the `#` from the number. Canonical foot-gun: t2190 session PR #19680.
- Every dispatched task MUST have a GitHub issue. Issue number in TODO.md as `ref:GH#NNN`.

## AGENTS.md User Guide Git Workflow

Worktree naming prefixes: `feature/`, `bugfix/`, `hotfix/`, `refactor/`, `chore/`, `experiment/`, `release/`

PR title: `{task-id}: {description}`. Task ID is `tNNN` (from TODO.md) or `GH#NNN` (GitHub issue number, for debt/issue-only work). Examples: `t1702: integrate FOSS scanning`, `GH#12455: tighten hashline-edit-format.md`. NEVER use `qd-`, bare numbers, or invented prefixes. NEVER invent suffixes or variants either — `t2213b`, `t2213-2`, `t2213.fix`, `t2213-followup` are all forbidden. Task IDs come EXCLUSIVELY from `claim-task-id.sh` output; for follow-up work, claim a FRESH ID. Create TODO entry first for unplanned work.

Worktrees: `wt switch -c {type}/{name}`. Keep the canonical repo directory on `main`, and treat the Git ref as an internal detail inside the linked worktree. User-facing guidance should talk about the worktree path, not "using a branch". Re-read files at worktree path before editing. NEVER remove others' worktrees. **Auto-claim on creation (GH#20102):** when a worktree is created via `worktree-helper.sh add|switch` or `full-loop-helper.sh start`, the framework automatically calls `interactive-session-helper.sh claim <N> <slug>` if the branch name encodes a task ID (`feature/tNNN-*` with `ref:GH#NNN` in TODO.md) or a direct issue number (`feature/gh-<N>-*`). This closes the race window between worktree creation and manual claim. Opt out for bulk scripted operations with `AIDEVOPS_SKIP_AUTO_CLAIM=1`. Headless workers (`FULL_LOOP_HEADLESS`, `AIDEVOPS_HEADLESS`, `Claude_HEADLESS`, `GITHUB_ACTIONS`) are skipped automatically.

**Preview proxy (GH#21560):** `worktree-helper.sh add` automatically allocates a preview port and (if configured) registers a local proxy route so every worktree dev server gets its own subdomain (`https://<branch-slug>.<repo>.local`). On remove, the port and route are freed. Both best-effort and non-fatal. Config: `~/.config/aidevops/preview-proxy.json`. Per-project dev hints: `.aidevops.json` `preview` block. Full setup and backend docs: `reference/preview-proxy.md`.

**Worktree/session isolation (MANDATORY):** exactly one active session may own a writable worktree path at a time. Never reuse a live worktree across sessions (interactive or headless). If ownership conflict is detected, create a fresh worktree for the current task/session instead of continuing in the contested path.

**Interactive issue ownership:** Mandatory claim/release rules live in Framework Rules > Git Workflow. Use `interactive-session-helper.sh claim <N> <slug>` for existing issues, `--implementing` for interactive takeover of `auto-dispatch` issues, `lockdown` for full pulse insulation, and `release` on handoff/abandonment. Session-start stale-claim details and idle handover: `reference/session.md`.

**Traceability and signature footer:** Hard rules: see "Traceability" above and "Framework Rules > Signature footer hallucination" in `.agents/AGENTS.md`. Link both sides when closing (issue→PR, PR→issue). Do NOT pass `--issue` when creating new issues (the issue doesn't exist yet). See `scripts/commands/pulse.md` for dispatch/kill/merge comment templates.

**Stacked PRs (t2412):** Stacked PRs (`--base feature/<other-branch>`) are auto-retargeted to default branch before the parent merges — handled automatically by `pulse-merge.sh` and `full-loop-helper.sh merge`. For bare `gh pr merge` calls, retarget manually first: `gh pr list --base <head-ref> --state open --json number -q '.[].number' | xargs -I{} gh pr edit {} --base main`. Only direct children are retargeted; grandchildren handled when their own parent merges.

**Parent-task PR keyword rule (t2046 — MANDATORY).** When a PR delivers ANY work for a `parent-task`-labeled issue — including the initial plan-filing PR — use `For #NNN` or `Ref #NNN` in the PR body, NEVER `Closes`/`Resolves`/`Fixes`. The parent issue must stay open until ALL phase children merge; only the final phase PR uses `Closes #NNN`. `full-loop-helper.sh commit-and-pr` enforces this automatically (see `.github/workflows/parent-task-keyword-check.yml`). For leaf (non-parent) issues, use `Resolves #NNN` as normal. See `templates/brief-template.md` "PR Conventions" for the full rule.

**Self-improvement routing (t1541):** Framework-level tasks → `framework-routing-helper.sh log-framework-issue`. Project tasks → current repo. Framework tasks in project repos are invisible to maintainers.

**Pulse scope (t1405):** `PULSE_SCOPE_REPOS` limits code changes. Issues allowed anywhere. Empty/unset = no restriction.

**Cross-runner overrides (t2422):** Per-runner claim filtering lives in `~/.config/aidevops/dispatch-override.conf` (structured `DISPATCH_OVERRIDE_<LOGIN>=honour|ignore|warn|honour-only-above:V`). Preferred over the deprecated flat `DISPATCH_CLAIM_IGNORE_RUNNERS` — structured overrides auto-sunset on peer upgrade and compose with the global `DISPATCH_CLAIM_MIN_VERSION` floor. Simultaneous-claim races are resolved via deterministic `sort_by([.created_at, .nonce])` tiebreaker; close-window losses (<=`DISPATCH_TIEBREAKER_WINDOW`, default 5s) emit `CLAIM_DEFERRED` audit comments. Full config grammar and diagnosis in `reference/cross-runner-coordination.md` §8.

**External Repo Issue/PR Submission (t1407):** Check templates and CONTRIBUTING.md first. Bots auto-close non-conforming submissions. Full guide: `reference/external-repo-submissions.md`.

**Git-readiness:** Non-git project with ongoing development? Flag: "No git tracking. Consider `git init` + `aidevops init`."

**Review Bot Gate (t1382):** Before merging: `review-bot-gate-helper.sh check <PR_NUMBER>` and read bot reviews. Additive bot suggestions become follow-up tasks, not PR scope creep. Full workflow/overrides: `reference/review-bot-gate.md`.

**Qlty Regression Gate (t2065, GH#18773):** CI fails on net `qlty smells` increases; details/override/local check: `reference/shell-style-guide.md` "Quality gate pattern reference".

**Qlty New-File Smell Gate (t2068):** CI fails when brand-new source files ship with smells; details/override/local check: `reference/shell-style-guide.md` "Quality gate pattern reference".

**Cryptographic approval + NMR automation (t2386):** moved to `reference/task-lifecycle.md`; read before approving issues/PRs or clearing/preserving NMR.

**Task-ID collision guard (t2047):** t-IDs in commit subjects MUST be claimed via `claim-task-id.sh`; enforcement details live in `reference/shell-style-guide.md` "Quality gate pattern reference".

**Large-file splits (t2368):** file-size/function-complexity/nesting-depth scanner issues start with `reference/large-file-split.md`.

**Complexity Bump Override (t2370):** `complexity-bump-ok` label requirements live in `reference/large-file-split.md` "Known CI false-positive classes".

**Workflow Cascade Vulnerability Lint (t2229):** workflow cascade detection/override details live in `reference/shell-style-guide.md` "Quality gate pattern reference".

**Reusable workflows:** downstream repos use thin caller YAMLs that reference aidevops reusable workflows. Full architecture/pinning/drift tools: `reference/reusable-workflows.md`.

**Badge management (t2975):** README badge blocks and LOC badge workflows are managed by `aidevops badges`; full docs: `.agents/aidevops/badges.md`.

Related workflow reference: `reference/session.md`
