# t18637: fix(pulse): TODO ref sync fails every cycle for SSH remotes and contributor repos

## Origin

- Created: 2026-10-09, interactive session, found while tracing why stale `publication:pending` issues were not repaired.
- Issue: GH#34185.

## What

Pulse's TODO ref sync (`sync_todo_refs_for_repo`) fails at `stage=workspace` on every cycle for two classes of registered repos, so `issue-sync-helper.sh pull` never runs for them. That means no ref sync, no orphan seeding and no stale `publication:pending` repair (GH#34149):

1. **GitHub SSH remotes under launchd.** `_pulse_create_todo_sync_workspace` clones the canonical checkout's `origin` URL verbatim. For `git@github.com:owner/repo.git` the launchd pulse has no SSH agent, so the clone fails with `ssh_askpass ... Permission denied (publickey)`. `gh` is authenticated with Git protocol `https`, so the HTTPS equivalent would succeed.
2. **Contributor repos and non-`origin` remotes.** The repo selector (`pulse-wrapper-cycle.sh` around line 1061) has no `role` filter. A `role: "contributor"` upstream checkout whose only remote is `upstream` fails `git remote get-url origin` silently, every cycle. A contributor repo should never get a TODO ref sync, since it can't publish planning to upstream.

## Why

Evidence in local `~/.aidevops/logs/pulse-wrapper.log`, from about 234k lines retained: one private maintainer repo with an SSH `origin` logged about 455 `stage=workspace` failures, all with the SSH publickey detail and still recurring today. One contributor repo with an `upstream`-only remote logged about 472 failures. Three repos that switched their remotes to HTTPS stopped failing. Each failed cycle also creates and removes a temp workspace for nothing.

## How

- `.agents/scripts/pulse-wrapper-cycle.sh` `_pulse_create_todo_sync_workspace` (around line 620): normalise GitHub SSH URLs (`git@github.com:owner/repo(.git)` and `ssh://git@github.com/owner/repo(.git)`) to `https://github.com/owner/repo.git` before `_ptsw_create_workspace`. Leave non-GitHub URLs unchanged. Prefer the remote named by `.aidevops.json` `remote` (same resolution as `claim-task-id.sh` `load_project_config`), falling back to `origin`.
- `.agents/scripts/pulse-wrapper-cycle.sh` repo selector (around line 1061): exclude `role == "contributor"` entries, logging one `status=skipped reason=contributor_role` line per repo like the existing `planning_not_enabled` skip.
- Reference: `claim-task-id.sh` already has an HTTPS↔SSH fallback for CAS pushes (GH#21904). Reuse its URL-conversion helper if one is exported; otherwise keep the conversion local and small.
- Update the relevant `.agents/scripts/tests/test-pulse-*todo*sync*` test if one covers workspace creation; otherwise verify by running the sync once for an SSH-remote fixture.

## Acceptance

- An SSH GitHub remote clones over HTTPS and the sync reaches `status=noop` or `committed`.
- A contributor-role repo is skipped with one reason line and no clone attempt.
- Non-GitHub remotes behave as before.
- ShellCheck is clean, and existing pulse TODO-sync tests pass.

### Files Scope

- `.agents/scripts/pulse-wrapper-cycle.sh`
- `.agents/scripts/pulse-todo-sync-workspace.sh`
