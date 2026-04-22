# Pre-Push Guards Reference (t1965, t2198, t2745)

Four opt-in `pre-push` hooks block common mistakes before they hit CI.

Install all: `install-pre-push-guards.sh install`
Install individual: `install-pre-push-guards.sh --guard privacy|complexity|scope|credential|dup-todo`
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

## Duplicate TODO Guard

**File:** `.agents/hooks/pre-push-dup-todo-guard.sh`

Blocks pushes when the pushed commit's `TODO.md` contains two or more checkbox lines with the same task ID (t2745). Root cause: `_seed_orphan_todo_line` in `issue-sync-lib.sh` appends a minimal entry for an issue that already has a rich planning-PR entry. After `git rebase main`, both entries coexist with no merge conflict (different line numbers). This hook catches the duplicate at push time, before it reaches the remote.

Detection pattern: `^[whitespace]*- \[.\] tNNN[.N]* ` — supports top-level and indented subtasks, and hierarchical IDs (e.g., `t1271.1`). Anchored to checkbox-and-task-ID prefix; description-only mentions of a task ID (e.g., `See t2743 for context`) are not flagged.

Fix: `grep -nE '^[[:space:]]*- \[.\] tNNN([[:space:]]|$)' TODO.md` to find both entries, remove the minimal (orphan-seeded) one, amend, and push again.

- Bypass (warning logged to stderr): `DUP_TODO_GUARD_DISABLE=1 git push ...`
- Bypass all hooks: `git push --no-verify` (no warning)
- **Fail-open** when: `TODO.md` is absent from the pushed commit, or `git show` fails
- Test harness: `.agents/scripts/tests/test-pre-push-dup-todo-guard.sh`
