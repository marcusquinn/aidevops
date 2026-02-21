---
mode: subagent
---
# t1264: Daily repo sync: auto-pull latest for git repos in configured parent directories

## Origin

- **Created:** 2026-02-20
- **Session:** supervisor:disable (headless Claude CLI)
- **Created by:** ai-supervisor

- **Commit:** c11c76ca370b0d4ddb682f50d9f7d23cf171a5b0 — "chore: add t1264 daily repo sync feature to backlog"

## What

Daily repo sync: auto-pull latest for git repos in configured parent directories

## Specification

```markdown
- [ ] t1264 Daily repo sync: auto-pull latest for git repos in configured parent directories #feature #auto-dispatch ~4h model:sonnet category:automation ref:GH#1984 — New `repo-sync-helper.sh` script (follows auto-update-helper.sh pattern) that runs daily via launchd/cron. Scans configured parent directories (default: `~/Git/`) for git repos cloned from a remote, and runs `git pull --ff-only` on repos where the working tree is clean and on the default branch (main/master). Config: add `git_parent_dirs` array to `~/.config/aidevops/repos.json`. CLI: `aidevops repo-sync [enable|disable|status|check|logs]`. Setup.sh offers to enable during install (like auto-update and supervisor pulse). Onboarding asks user to specify parent directories. Safety: only ff-only pulls, skip dirty working trees, skip non-default branches, log failures without stopping. Worktrees are irrelevant — only the main checkout matters.
  - [x] t1264.1 Add `git_parent_dirs` config to repos.json — extend `init_repos_file()` in aidevops.sh to include `git_parent_dirs: ["~/Git"]` default. Add `aidevops repo-sync dirs [add|remove|list]` subcommand to manage the list. #auto-dispatch ~30m model:sonnet ref:GH#1985 pr:#1997 completed:2026-02-20
  - [ ] t1264.2 Create `repo-sync-helper.sh` — core script with enable/disable/status/check/logs commands. `check` scans all dirs in `git_parent_dirs`, finds git repos (has `.git/` and a remote), determines default branch, skips if dirty or not on default branch, runs `git pull --ff-only`. Logs results per-repo. Uses launchd on macOS (daily), cron on Linux. Follows auto-update-helper.sh patterns (lock, state file, logging). #auto-dispatch ~2h model:sonnet ref:GH#1986 assignee:marcusquinn started:2026-02-21T03:20:14Z
    - Notes: BLOCKED by supervisor: Stale state recovery (Phase 0.7/t1132): was evaluating with no live worker, retries exhausted (3/3, cause: eval_process_died)
  - [x] t1264.3 Integrate into aidevops CLI and setup.sh — add `repo-sync` command to aidevops.sh case statement (delegates to helper). Add enable prompt to setup.sh main() after supervisor pulse section. Add onboarding question to onboarding-helper.sh for specifying parent directories. #auto-dispatch ~1h model:sonnet ref:GH#1987 assignee:marcusquinn started:2026-02-20T17:50:11Z pr:#2016 completed:2026-02-20
  - [x] t1264.4 Update AGENTS.md documentation — add repo-sync to Auto-Update section or new section in .agents/AGENTS.md. Document CLI commands, env var overrides (AIDEVOPS_REPO_SYNC=true/false, AIDEVOPS_REPO_SYNC_HOUR=4), config format. #auto-dispatch ~30m model:sonnet ref:GH#1988 assignee:marcusquinn started:2026-02-20T18:59:08Z pr:#2023 completed:2026-02-20
```



## Supervisor Context

```
t1264|Daily repo sync: auto-pull latest for git repos in configured parent directories #feature #auto-dispatch ~4h model:sonnet category:automation ref:GH#1984 — New `repo-sync-helper.sh` script (follows auto-update-helper.sh pattern) that runs daily via launchd/cron. Scans configured parent directories (default: `~/Git/`) for git repos cloned from a remote, and runs `git pull --ff-only` on repos where the working tree is clean and on the default branch (main/master). Config: add `git_parent_dirs` array to `~/.config/aidevops/repos.json`. CLI: `aidevops repo-sync [enable|disable|status|check|logs]`. Setup.sh offers to enable during install (like auto-update and supervisor pulse). Onboarding asks user to specify parent directories. Safety: only ff-only pulls, skip dirty working trees, skip non-default branches, log failures without stopping. Worktrees are irrelevant — only the main checkout matters.|pid:15256|2026-02-21T03:16:29Z|2026-02-21T03:53:32Z
```

## Acceptance Criteria

- [ ] Implementation matches the specification above
- [ ] Tests pass
- [ ] Lint clean

## Relevant Files

<!-- TODO: Add relevant file paths after codebase analysis -->
