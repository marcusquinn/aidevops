# Allow the framework's pull_request_target gates through GitHub's Actions event policy before the default block

## What

Add `.agents/scripts/actions-event-policy-helper.sh`. It plans, applies and verifies a repository Actions event policy that explicitly allows `pull_request_target` for the workflow files that declare it. It also gives the security posture check and `sync-workflows` a way to report public repositories that would lose their `pull_request_target` gates. The repositories in scope are aidevops itself and every public downstream repository that uses the canonical caller templates.

## Why

GitHub blocks `pull_request_target` by default in public repositories from **2026-12-02**, unless an applicable Actions event policy explicitly allows it. Two brownouts enforce the block early, on **2026-11-09 and 2026-11-16, 16:00–18:00 UTC** (changelog, 2026-11-02: https://github.blog/changelog/2026-11-02-pull_request_target-blocked-by-default-december-2). The framework's required merge gates run on `pull_request_target`: Maintainer Gate, Linked Issue Check, Review Bot Gate callers, Issue Sync, URL Allowlist, and others.

Observed during the 2026-11-09 brownout in `marcusquinn/aidevops`, which has no Actions policies (`gh api repos/marcusquinn/aidevops/actions/policies` → `{"total_count":0,"policies":[]}`):

- Every `pull_request_target` run from 16:08:28Z ended `startup_failure` with zero jobs: 40+ runs across 15 workflow files, including worker PRs.
- `pull_request`, `issues`, `issue_comment`, `push`, `schedule` and `workflow_dispatch` runs kept succeeding.
- The last success was 15:57:54Z on the same default-branch commit. `githubstatus.com` showed no incident.
- The required `maintainer-gate` check could not report, so no PR could merge during the window.

From 2026-12-02 this is permanent for every public managed repository that has these workflows.

## How

1. New helper `.agents/scripts/actions-event-policy-helper.sh`. Follow `.agents/scripts/release-publication-settings-helper.sh` for structure: a validated slug, read-only API helpers, and fail-closed `jq` checks.
   - `status --repo OWNER/REPO`: visibility, the `.github/workflows/*.yml` files on the default branch that declare `pull_request_target`, and whether an applicable policy (`GET repos/{slug}/actions/policies?has_parents=true`) allows the event for each of them. Exit 0 when covered or not applicable (private or internal repo, or no such workflow). Exit 1 when uncovered.
   - `plan --repo OWNER/REPO`: print the exact JSON body. Use name `aidevops-pull-request-target-gates`, `enforcement: active`, `conditions.workflow_path.include` = the exact workflow paths (no globs; `exclude: []`), and one `restrict_action_events` rule.
   - **Critical:** `restrict_action_events` restricts the targeted workflows to `allowed_events`. These files also trigger on `issues`, `issue_comment`, `pull_request`, `push`, `schedule`, `workflow_dispatch` and so on (for example `.github/workflows/issue-sync.yml:11-60`). `allowed_events` must therefore be the union of every event declared in the targeted files' `on:` blocks, plus `workflow_call` if any of them call local reusable workflows.
   - Parse `on:` with a real YAML parser. Beware that YAML 1.1 loaders such as PyYAML read the key `on` as boolean `True`.
   - `apply --repo OWNER/REPO`: create, or update in place by name (`POST`/`PUT repos/{slug}/actions/policies[/{id}]`). It is idempotent, and it refuses when `plan` finds a workflow whose events it cannot parse. Log through `audit-log-helper.sh` (type `config.change`, no credentials).
   - `--all-managed`: iterate `~/.config/aidevops/repos.json` public entries for `status` and `plan`. `apply` stays per repository and explicit.
   - API reference: https://docs.github.com/en/rest/actions/policies (`X-GitHub-Api-Version: 2026-03-10`).
2. `.agents/scripts/security-posture-helper-repo.sh`: add a finding next to `_actions_can_create_pull_requests` (~:1273) when `status` reports uncovered `pull_request_target` workflows in a public repository. Give the deadline and the fix command.
3. `.agents/scripts/sync-workflows-helper.sh`: after installing a caller template that uses `pull_request_target`, run `status` for public targets and print the `apply` command when the repository is uncovered. Warn only; do not mutate settings from sync.
4. `.agents/reference/reusable-workflows.md`: next to the `default_workflow_permissions: read` note (~:273), add a short section covering the default block, the brownout dates, the full event union requirement, and the helper commands.

## Hazards

- A policy with a too-narrow `allowed_events` silently stops `issues`, `push` and `schedule` triggers for the targeted files. Verify the union against every targeted file before `apply`.
- Repository settings are security-relevant. Workers implement and dry-run (`status`, `plan`) only. The interactive maintainer session runs `apply` for `marcusquinn/aidevops` after merge, and downstream owners run it per repository.
- Keep private repository names out of PR and issue text; report counts only.

### Files Scope

- `.agents/scripts/actions-event-policy-helper.sh`
- `.agents/scripts/security-posture-helper-repo.sh`
- `.agents/scripts/sync-workflows-helper.sh`
- `.agents/reference/reusable-workflows.md`
- `.agents/scripts/tests/test-actions-event-policy-helper.sh`

## Acceptance

- `actions-event-policy-helper.sh status --repo marcusquinn/aidevops` exits 1 today. It lists exactly the workflow files on `main` that declare `pull_request_target` (`rg -l 'pull_request_target' .github/workflows` gives the same set).
- `plan --repo marcusquinn/aidevops` prints valid JSON. `workflow_path.include` equals that file set, and `allowed_events` contains `pull_request_target` plus every other event those files declare (`issues`, `issue_comment`, `pull_request`, `push`, `schedule`, `workflow_dispatch`, among others).
- `status` exits 0 for a private repository and for a public repository without `pull_request_target` workflows.
- ShellCheck reports zero violations. Every function has explicit returns and the script is Bash 3.2 compatible.
- After merge and an explicit `apply` on `marcusquinn/aidevops`, `status` exits 0. `issues`, `push` and `schedule` runs of the targeted workflows keep succeeding. During the 2026-11-16 16:00–18:00 UTC brownout, `pull_request_target` runs succeed instead of ending `startup_failure`.
