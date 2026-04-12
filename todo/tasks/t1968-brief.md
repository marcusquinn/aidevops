<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->
# t1968: setup.sh — auto-install privacy guard pre-push hook in every initialized repo

## Origin

- **Created:** 2026-04-12
- **Session:** claude-code:interactive (follow-up to t1965)
- **Created by:** ai-interactive
- **Parent task:** t1965 (privacy guard, already merged via PR #18361)
- **Conversation context:** After t1965 landed we manually loop-installed the guard into 27 existing repos with a one-off script. For the rollout to be durable, every future `aidevops init` on a new repo and every `aidevops update` on an existing repo should install (or refresh) the hook automatically. Otherwise the guarantee decays: a cloned-from-scratch repo has no protection until the user remembers to run `install-privacy-guard.sh install`.

## What

Extend `.agents/scripts/setup/_routines.sh` (or a sibling `_privacy_guard.sh` module) so that `setup.sh` calls `install-privacy-guard.sh install` once per initialized repo on every `aidevops init` and `aidevops update` cycle. The installer is already idempotent (it refuses to overwrite unmanaged hooks, re-installs managed hooks cleanly), so repeat invocation is safe.

The change should:

- Run for every repo in `repos.json` with a valid local `.git` path (including nested repos like `cloudron/netbird-app`)
- Tolerate repos without `.git` (worktree parent dirs, archive-only paths) by skipping them with a debug-level log line, not a warning
- Tolerate conflict cases (user has a pre-existing non-aidevops pre-push hook) without failing the whole setup run — log at info and move on
- Respect an opt-out env var `AIDEVOPS_PRIVACY_GUARD=false` for users who explicitly don't want the hook installed globally
- Record install outcomes in the setup tracking buckets (`setup_track_configured` / `setup_track_skipped`)
- Not touch remote git state or network

## Why

Without this, the privacy guard is a point-in-time installation that erodes as new repos appear. A fresh `git clone` + `aidevops init` today does not get the hook. A teammate of the user who follows the setup docs does not get the hook. And the installed repos gradually fall out of sync with the framework's deployed helper because nothing refreshes the dispatcher when the hook path changes.

Integrating into `setup.sh` makes the guarantee durable: every `aidevops update` (which runs every ~10 minutes via launchd) will re-confirm the hook is present and pointing at the current deployed helper. New repos get protected immediately on init.

## Tier

### Tier checklist

- [x] **2 or fewer files to modify?** — 2 (`_routines.sh` or a new `setup/_privacy_guard.sh`, plus `setup.sh` itself if the latter needs a new sourced module)
- [x] **Complete code blocks for every edit?** — yes, diff provided below
- [x] **No judgment or design decisions?** — the design (idempotent call, opt-out env var) is settled in this brief
- [x] **No error handling or fallback logic to design?** — reuses existing installer's error handling
- [x] **Estimate 1h or less?** — yes, ~45m
- [x] **4 or fewer acceptance criteria?** — 4

**Selected tier:** `tier:simple`

**Tier rationale:** Very narrow addition to setup flow. The heavy lifting (the installer, the hook, the library) is already merged via t1965. This PR is just wiring: call the installer once per repo during setup.

## How (Approach)

### Files to Modify

- `NEW: .agents/scripts/setup/_privacy_guard.sh` — setup module that iterates initialized_repos and calls `install-privacy-guard.sh install` for each one with a `.git` present. Model on `.agents/scripts/setup/_routines.sh`.
- `EDIT: .agents/scripts/setup/_routines.sh:25-43` — not needed; that's just the reference pattern.
- `EDIT: setup.sh` — source and call `setup_privacy_guard` after the existing `setup_routines` call. Exact hook site: find the line that calls `setup_routines` in the main setup flow and add `setup_privacy_guard` immediately after.

### Implementation Steps

1. Create `.agents/scripts/setup/_privacy_guard.sh`:

    ```bash
    #!/usr/bin/env bash
    # SPDX-License-Identifier: MIT
    # SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
    # Setup module: install privacy-guard pre-push hook in every initialized repo.
    # Sourced by setup.sh — do not execute directly.

    _load_privacy_guard_installer() {
        local installer_path
        installer_path="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../install-privacy-guard.sh"
        if [[ ! -f "$installer_path" ]]; then
            print_warning "install-privacy-guard.sh not found at: $installer_path"
            return 1
        fi
        printf '%s' "$installer_path"
        return 0
    }

    # setup_privacy_guard — installs/refreshes the pre-push privacy guard in every
    # initialized repo listed in repos.json that has a local .git present.
    # Idempotent: re-installs managed hooks, skips unmanaged ones with a warning.
    # Opt out by exporting AIDEVOPS_PRIVACY_GUARD=false before running setup.
    setup_privacy_guard() {
        if [[ "${AIDEVOPS_PRIVACY_GUARD:-true}" == "false" ]]; then
            print_info "Privacy guard install disabled via AIDEVOPS_PRIVACY_GUARD=false"
            setup_track_skipped "Privacy guard" "opted out via AIDEVOPS_PRIVACY_GUARD=false"
            return 0
        fi

        print_info "Installing privacy guard pre-push hook across initialized repos..."

        local installer_path
        if ! installer_path=$(_load_privacy_guard_installer); then
            setup_track_skipped "Privacy guard" "installer not available"
            return 0
        fi

        local repos_config="${HOME}/.config/aidevops/repos.json"
        if [[ ! -f "$repos_config" ]]; then
            print_warning "repos.json not found — skipping privacy guard rollout"
            setup_track_skipped "Privacy guard" "repos.json not found"
            return 0
        fi

        local ok=0 already=0 conflict=0 skip=0 err=0
        local rawpath path result

        while IFS= read -r rawpath; do
            [[ -z "$rawpath" ]] && continue
            path="${rawpath/#\~/$HOME}"
            if [[ ! -e "$path/.git" ]]; then
                skip=$((skip + 1))
                continue
            fi
            result=$(cd "$path" && bash "$installer_path" install 2>&1 </dev/null || true)
            if [[ "$result" == *"installed privacy guard"* ]]; then
                ok=$((ok + 1))
            elif [[ "$result" == *"already installed"* ]]; then
                already=$((already + 1))
            elif [[ "$result" == *"Refusing to overwrite"* || "$result" == *"NOT managed"* ]]; then
                conflict=$((conflict + 1))
            else
                err=$((err + 1))
            fi
        done < <(jq -r '.initialized_repos[] | select(.path != null) | .path' "$repos_config")

        print_info "Privacy guard: ok=$ok already=$already conflict=$conflict skip=$skip err=$err"
        setup_track_configured "Privacy guard ($((ok + already)) repos)"
        return 0
    }
    ```

2. In `setup.sh`, find the existing `setup_routines` call and add a call to `setup_privacy_guard` immediately after. Also source the new module alongside `_routines.sh`.

3. Run `shellcheck` on the new file.

4. Test: `bash setup.sh --non-interactive` from `~/Git/aidevops` and verify stdout reports the privacy-guard summary line.

### Verification

```bash
shellcheck .agents/scripts/setup/_privacy_guard.sh
# End-to-end: wipe the hook from one repo, run setup, confirm it re-installed
rm -f ~/Git/awardsapp/.git/hooks/pre-push
bash setup.sh --non-interactive 2>&1 | grep "Privacy guard"
test -f ~/Git/awardsapp/.git/hooks/pre-push && echo "PASS"
# Opt-out
AIDEVOPS_PRIVACY_GUARD=false bash setup.sh --non-interactive 2>&1 | grep "opted out"
```

## Acceptance Criteria

- [ ] `setup.sh --non-interactive` installs the privacy guard in every initialized repo with a local `.git` present, reporting a summary line like `Privacy guard: ok=N already=N conflict=N skip=N err=N`.
- [ ] Re-running `setup.sh` on an already-installed repo is a no-op (no duplicate entries, no errors, counted in `already`).
- [ ] A repo with a pre-existing non-aidevops pre-push hook is counted in `conflict` and does NOT fail the whole setup run.
- [ ] Setting `AIDEVOPS_PRIVACY_GUARD=false` before running setup skips the privacy-guard step entirely and logs the opt-out.
- [ ] `shellcheck .agents/scripts/setup/_privacy_guard.sh` is clean.

## Context & Decisions

- **Why not call the installer from `install-hooks-helper.sh`:** that helper is scoped to Claude Code PreToolUse hooks (runtime-specific, installed to `~/.claude/settings.json`). The privacy guard is a git-level hook, different layer, different scope. Conflating them would tie the git hook to a specific runtime.
- **Why iterate via `setup.sh` rather than per-repo `aidevops init`:** both. `setup.sh` runs during `aidevops update` (every 10 min), which catches existing repos on every cycle. The per-repo `aidevops init` call also eventually lands in the same setup flow via the `Syncing Initialized Projects` step.
- **Opt-out via env var, not config file:** keeps the change minimal. If demand grows, a config file entry (`privacy_guard: false` in `repos.json` per repo) is a natural follow-up.

## Relevant Files

- `.agents/scripts/setup/_routines.sh` — model pattern for setup modules
- `.agents/scripts/install-privacy-guard.sh` — the installer called from the new module
- `setup.sh` — the top-level setup script where the new call is wired
- `/tmp/install-privacy-guard-loop.sh` — the manual loop script that rolled out the guard initially; this task replaces the manual path

## Dependencies

- **Blocked by:** t1965 (merged)
- **Blocks:** none

## Estimate Breakdown

| Phase | Time | Notes |
|-------|------|-------|
| Research/read | 5m | Already done in this session |
| Implementation | 20m | New file + 3-line setup.sh edit |
| Testing | 15m | opt-out, conflict, fresh install scenarios |
| PR | 5m | |

**Total estimate:** ~45m
