# Pre-Push Guards Reference (t1965, t2198)

Three opt-in `pre-push` hooks block common mistakes before they hit CI.

Install all: `install-pre-push-guards.sh install`
Install individual: `install-pre-push-guards.sh --guard privacy|complexity|scope`
Status: `install-pre-push-guards.sh status`
Bypass all: `git push --no-verify`

## Privacy Guard

**File:** `.agents/hooks/privacy-guard-pre-push.sh`

Blocks pushes to public GitHub repos that contain private repo slugs in `TODO.md`, `todo/**`, `README.md`, or `.github/ISSUE_TEMPLATE/**`.

Private slugs are enumerated from `initialized_repos[]` entries with `mirror_upstream` or `local_only: true`, plus optional extras in `~/.aidevops/configs/privacy-guard-extra-slugs.txt`.

- Bypass: `PRIVACY_GUARD_DISABLE=1 git push ...`
- Fail-open on offline/unauthenticated `gh`
- Test harness: `.agents/scripts/test-privacy-guard.sh`
- Back-compat: `install-privacy-guard.sh install` is a deprecated shim that delegates to `install-pre-push-guards.sh --guard privacy`

## Complexity Regression Guard

**File:** `.agents/hooks/complexity-regression-pre-push.sh`

Blocks pushes that introduce new violations of three complexity metrics:
- Function body > 100 lines
- Nesting depth > 8
- File > 1500 lines

Wraps `complexity-regression-helper.sh check` for each metric. Uses `git merge-base HEAD <origin-default>` as base, where `<origin-default>` is resolved via `origin/HEAD` → `origin/main` → `origin/master` → `@{u}`. This avoids spurious false-positives after a rebase (GH#20045).

- Bypass: `COMPLEXITY_GUARD_DISABLE=1 git push ...`
- Fail-open when helper is missing or upstream is unreachable

## Scope Guard

**File:** `.agents/hooks/scope-guard-pre-push.sh`

Blocks pushes that modify files outside the brief's declared `### Files Scope` section (or `## Files Scope` in older briefs). Prevents accidental scope-leak during rebase or implementation drift (t2445, GH#19808).

Reads the brief file for the current branch's task ID and enforces the declared glob patterns.

- Bypass: `SCOPE_GUARD_DISABLE=1 git push ...`
- **Fail-open** when: branch name has no task ID, or no brief file exists
- **Fail-closed** when: brief exists but has no `Files Scope` section or the section is empty — this is a configuration error that must be fixed before pushing
