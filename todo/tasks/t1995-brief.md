<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->
# t1995: git post-checkout hook — enforce canonical stays on main at the git-operation level

## Origin

- **Created:** 2026-04-12
- **Session:** claude-code:interactive (follow-up to t1990)
- **Created by:** ai-interactive
- **Parent task:** t1990 (merged via PR #18414)
- **Conversation context:** t1990 tightened `pre-edit-check.sh` to enforce "canonical stays on main" in interactive sessions at **edit time**. That's sufficient for agent-driven file edits but does nothing to prevent an interactive operator (or another session) from running `git checkout <feature-branch>` directly in the canonical dir. Earlier today, PR #18396 landed in a canonical dir that was silently checked out to `bugfix/t1980-claim-task-id-dedup`, causing a planning commit to land on a stale merged branch. The edit-time check was too late to help. t1995 closes this gap with a git `post-checkout` hook that warns or blocks non-main checkouts in the canonical repo directory.

## What

A `post-checkout` hook at `.agents/hooks/canonical-on-main-guard.sh` plus a per-repo installer (`install-canonical-guard.sh`) modelled on the privacy-guard installer from t1965. The hook:

1. Fires after any `git checkout`, `git switch`, or `git clone`
2. Identifies whether the current working copy is the **canonical directory** for the repo (i.e. `$(git rev-parse --show-toplevel)` matches one of the paths listed in `~/.config/aidevops/repos.json` `initialized_repos[].path`)
3. Identifies whether the **new branch is non-main** (not `main`/`master`)
4. Identifies whether the session is **interactive** (none of the known headless env vars set — same detection as t1990)
5. If all three conditions hold: **warn loudly** (stderr banner), and:
   - **Interactive mode (default):** print a sharp warning with remediation instructions (`git checkout main && wt add ...`), but don't block — git hooks shouldn't prevent legitimate interactive recovery work
   - **Strict mode (`AIDEVOPS_CANONICAL_GUARD=strict`):** also return non-zero to fail the checkout (caller can then retry on main or create a worktree)

The hook fails open under all ambiguity (missing repos.json, unrecognised repo, non-github remote, etc.) to avoid breaking legitimate work.

## Why

**Concrete failure mode from earlier this session:**

1. I was working in canonical `~/Git/aidevops` on `main`
2. A parallel session (`alex-solovyev`) checked out `bugfix/t1980-claim-task-id-dedup` in the same directory — no warning
3. My next edit (planning commit for t1983-t1985 briefs) landed on `bugfix/t1980-claim-task-id-dedup` because that's where HEAD was
4. `pre-edit-check.sh --loop-mode --file todo/tasks/...` returned `LOOP_DECISION=stay` because its allowlist logic saw a planning path and approved — but `stay` meant "stay on the current branch", which was no longer main
5. Recovery: cherry-pick into a fresh worktree, re-push, delete dead commit. ~15 minutes lost.

The t1990 edit-time check prevents this for interactive sessions *if* they honour pre-edit-check. It does nothing to prevent the original branch switch that put the canonical in the wrong state. A `post-checkout` hook catches the exact moment the canonical goes off main and alerts the next operator immediately, not when they're already mid-commit.

## Tier

### Tier checklist

- [x] **2 or fewer files to modify?** — 3 new files (hook, installer, test harness). 1 over.
- [x] **Complete code blocks for every edit?** — yes, full implementations below
- [x] **No judgment or design decisions?** — warn-vs-block decision is settled (warn by default, strict mode via env var)
- [x] **No error handling or fallback logic to design?** — fail-open semantics are specified
- [x] **Estimate 1h or less?** — ~45m
- [x] **4 or fewer acceptance criteria?** — 4

**Selected tier:** `tier:standard` (3 files > 2, but each is small and fully-specified)

## How (Approach)

### Files to Create

- `NEW: .agents/hooks/canonical-on-main-guard.sh` — the post-checkout hook body
- `NEW: .agents/scripts/install-canonical-guard.sh` — per-repo installer (model on `install-privacy-guard.sh` from t1965)
- `NEW: .agents/scripts/test-canonical-guard.sh` — test harness (model on `test-privacy-guard.sh` from t1969)

### Files to Modify

- `EDIT: .agents/scripts/setup/_privacy_guard.sh` OR `NEW: .agents/scripts/setup/_canonical_guard.sh` — auto-install step during `setup.sh` non-interactive runs, mirroring t1968's privacy-guard auto-install pattern

### Implementation Steps

1. **Hook body** (`canonical-on-main-guard.sh`):

    ```bash
    #!/usr/bin/env bash
    # post-checkout hook: warn when the canonical repo directory is moved off main/master.
    #
    # Git post-checkout args:
    #   $1 = previous HEAD ref
    #   $2 = new HEAD ref
    #   $3 = flag (1 = branch checkout, 0 = file checkout)
    #
    # Only fire on branch checkouts ($3 == 1).

    set -u

    # Only fire on full branch checkouts
    [[ "${3:-0}" == "1" ]] || exit 0

    # Detect session origin (same pattern as pre-edit-check.sh t1990)
    if [[ "${FULL_LOOP_HEADLESS:-}" == "true" ]] \
        || [[ "${AIDEVOPS_HEADLESS:-}" == "true" ]] \
        || [[ "${OPENCODE_HEADLESS:-}" == "true" ]] \
        || [[ "${GITHUB_ACTIONS:-}" == "true" ]]; then
        # Headless session: skip the check, let the worker do whatever the
        # dispatch logic requires.
        exit 0
    fi

    # Determine current branch
    current_branch=$(git symbolic-ref --short HEAD 2>/dev/null || echo "")
    [[ -z "$current_branch" ]] && exit 0  # detached HEAD — not our concern

    # If new branch IS main/master, nothing to warn about
    case "$current_branch" in
        main|master) exit 0 ;;
    esac

    # Determine if current working copy is a canonical directory.
    # Canonical = git-common-dir == git-dir (not a worktree).
    git_dir=$(git rev-parse --git-dir 2>/dev/null || echo "")
    git_common_dir=$(git rev-parse --git-common-dir 2>/dev/null || echo "")
    if [[ -z "$git_dir" ]] || [[ -z "$git_common_dir" ]]; then
        exit 0  # not in a git repo — fail open
    fi
    if [[ "$git_dir" != "$git_common_dir" ]]; then
        # This is a worktree, not the canonical — worktrees are supposed to
        # be on non-main branches, so no warning.
        exit 0
    fi

    # Cross-check against repos.json: is this path actually a registered
    # canonical? If repos.json is missing or the path is not listed, fail
    # open — we only guard repos we know about.
    repo_root=$(git rev-parse --show-toplevel 2>/dev/null || echo "")
    repos_config="${HOME}/.config/aidevops/repos.json"
    if [[ ! -f "$repos_config" ]]; then
        exit 0
    fi
    known_canonical=$(jq -r --arg root "$repo_root" \
        '.initialized_repos[]? | select(.path == $root) | .path' \
        "$repos_config" 2>/dev/null)
    [[ -z "$known_canonical" ]] && exit 0

    # All conditions met: interactive + canonical + non-main branch.
    RED=$'\033[0;31m'; YELLOW=$'\033[1;33m'; NC=$'\033[0m'
    {
        printf '\n'
        printf '%s============================================================%s\n' "$RED" "$NC"
        printf '%s[canonical-on-main-guard] WARNING%s\n' "$RED" "$NC"
        printf '%s============================================================%s\n' "$RED" "$NC"
        printf '\n'
        printf 'The canonical repo directory %s%s%s has been switched to\n' \
            "$YELLOW" "$repo_root" "$NC"
        printf 'branch %s%s%s, which is NOT main/master.\n' "$YELLOW" "$current_branch" "$NC"
        printf '\n'
        printf 'aidevops convention (t1990): canonical directories stay on main.\n'
        printf 'Worktrees are used for all non-main work.\n'
        printf '\n'
        printf 'To recover:\n'
        printf '  git checkout main\n'
        printf '  wt add <feature/bugfix/chore>/%s   # if you want to keep the branch\n' "$current_branch"
        printf '\n'
        printf 'To bypass this warning (e.g. rebasing) set:\n'
        printf '  AIDEVOPS_CANONICAL_GUARD=bypass\n'
        printf '\n'
        printf '%s============================================================%s\n' "$RED" "$NC"
        printf '\n'
    } >&2

    # Strict mode: fail the checkout
    if [[ "${AIDEVOPS_CANONICAL_GUARD:-warn}" == "strict" ]]; then
        exit 1
    fi

    # Default: warn-only, don't block
    exit 0
    ```

2. **Installer** (`install-canonical-guard.sh`): mirror the structure of `install-privacy-guard.sh` but target `post-checkout` instead of `pre-push`. Install/uninstall/status/test subcommands. Writes a dispatcher script to `$(git rev-parse --git-common-dir)/hooks/post-checkout` that invokes the deployed hook at `~/.aidevops/agents/hooks/canonical-on-main-guard.sh`. Refuses to overwrite unmanaged hooks.

3. **Setup integration** (`.agents/scripts/setup/_canonical_guard.sh`): mirror `_privacy_guard.sh` from t1968. `setup.sh` iterates `initialized_repos[]` and calls `install-canonical-guard.sh install` for each one with a local `.git` present. Opt-out via `AIDEVOPS_CANONICAL_GUARD_INSTALL=false`. Wire the call into the non-interactive `_setup_run_non_interactive` path (NOT the already-over-complexity interactive path — per t1968 post-mortem).

4. **Test harness** (`test-canonical-guard.sh`): mirror `test-privacy-guard.sh` with stub-based tests. Create a scratch git repo, simulate various post-checkout scenarios (interactive main-to-feature, headless main-to-feature, worktree main-to-feature, strict mode, bypass mode), assert expected exit codes and stderr content.

5. Add a small note to `.agents/AGENTS.md` "Quick Reference" section documenting the hook and its env vars.

### Verification

```bash
# Lint
shellcheck .agents/hooks/canonical-on-main-guard.sh \
    .agents/scripts/install-canonical-guard.sh \
    .agents/scripts/test-canonical-guard.sh \
    .agents/scripts/setup/_canonical_guard.sh

# Unit tests
bash .agents/scripts/test-canonical-guard.sh

# Live install in the aidevops repo and manually test
.agents/scripts/install-canonical-guard.sh install
# Then:
git checkout -b test/canonical-guard-sanity   # should warn
git checkout main                              # should NOT warn
git branch -D test/canonical-guard-sanity
```

## Acceptance Criteria

- [ ] Post-checkout hook warns (stderr) when an interactive session switches the canonical directory from main to a non-main branch. Warning includes the branch name, the canonical path, and recovery instructions.
- [ ] Hook does NOT warn when checking out main/master, when the current working copy is a worktree (non-canonical), when the session is headless, or when the checkout is a file-level checkout (`$3 != 1`).
- [ ] `AIDEVOPS_CANONICAL_GUARD=strict` causes the hook to exit non-zero (block the checkout); default is warn-only (exit 0).
- [ ] `install-canonical-guard.sh install` wires the hook into `$(git rev-parse --git-common-dir)/hooks/post-checkout`. `setup.sh` auto-installs across all initialized repos.

## Context & Decisions

- **Warn-only by default, not block:** git `post-checkout` hooks that fail can break legitimate workflows (e.g. rebase interactives, pull operations that implicitly checkout). A loud stderr warning is sufficient to catch operator mistakes without breaking automation. Strict mode is available for users who want hard enforcement.
- **Canonical detection via `git-dir == git-common-dir`:** this is the canonical git way to distinguish a working copy from a linked worktree. Don't try to match against `repos.json` paths alone — operators may have repos outside the registry.
- **Cross-check against `repos.json`:** limits the guard to repos we explicitly manage, avoiding false positives on ad-hoc clones. Fail-open if `repos.json` is missing.
- **Install via `setup.sh` auto-install:** mirrors t1968's privacy-guard rollout. Every initialized repo gets the guard on the next `aidevops update` cycle. No manual rollout needed.
- **Why not a git `pre-checkout` hook instead:** git has no `pre-checkout` hook. The closest is `pre-receive` (wrong direction — server-side) or `post-checkout` (after-the-fact). Accept the "after the fact" semantics and mitigate with clear warnings and recovery instructions.
- **Interaction with t1990's edit-time check:** complementary. t1990 catches attempts to write files. t1995 catches the branch switch BEFORE any writes happen. Both layers needed.

## Relevant Files

- `.agents/hooks/privacy-guard-pre-push.sh` — model for hook structure
- `.agents/scripts/install-privacy-guard.sh` — model for installer
- `.agents/scripts/test-privacy-guard.sh` — model for test harness
- `.agents/scripts/setup/_privacy_guard.sh` — model for setup integration
- `.agents/scripts/pre-edit-check.sh:186-195` — t1990's edit-time check (complementary layer)

## Dependencies

- **Blocked by:** t1990 (merged) — defined the rule; t1995 is a deeper enforcement layer
- **Blocks:** none
- **External:** none

## Estimate Breakdown

| Phase | Time | Notes |
|-------|------|-------|
| Hook body | 10m | |
| Installer | 15m | Model on install-privacy-guard.sh |
| Setup integration | 10m | Model on _privacy_guard.sh |
| Test harness | 15m | Model on test-privacy-guard.sh |
| Verification + PR | 15m | Shellcheck + manual + PR |

**Total estimate:** ~65m
