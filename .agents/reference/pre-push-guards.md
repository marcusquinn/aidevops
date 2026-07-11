# Pre-Push Guards Reference (t1965, t2198, t2745, t3224)

Six opt-in `pre-push` hooks block common mistakes before they hit CI.

Install all: `install-pre-push-guards.sh install`
Install individual: `install-pre-push-guards.sh --guard privacy|complexity|scope|credential|dup-todo|repo-verify`
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

Detection pattern: `^[whitespace]*- \[.\] tNNN[.N]*` — supports top-level and indented subtasks, and hierarchical IDs (e.g., `t1271.1`). Anchored to checkbox-and-task-ID prefix; description-only mentions of a task ID (e.g., `See t2743 for context`) are not flagged.

Fix: `grep -nE '^[[:space:]]*- \[.\] tNNN([[:space:]]|$)' TODO.md` to find both entries, remove the minimal (orphan-seeded) one, amend, and push again.

- Bypass (warning logged to stderr): `DUP_TODO_GUARD_DISABLE=1 git push ...`
- Bypass all hooks: `git push --no-verify` (no warning)
- **Fail-open** when: `TODO.md` is absent from the pushed commit, or `git show` fails
- Test harness: `.agents/scripts/tests/test-pre-push-dup-todo-guard.sh`

## Repo Verify Guard (t3224)

**File:** `.agents/hooks/repo-verify-pre-push.sh`

Runs the target repo's declared `format`/`lint`/`typecheck` commands BEFORE the push reaches CI. Closes the gap that lets workers ship PRs failing Format/Lint on the next CI cycle and then sit in a CI-feedback loop.

In headless sessions (pulse, CI workers, routines), the guard auto-fixes formatting/lint failures, amends them into HEAD, and re-runs the check. The push proceeds only if the recheck passes — no more "shipped, then failed Format on CI" round-trips. In interactive sessions the guard is fail-closed by default so the user sees and approves the autofix.

### Discovery cascade (first match wins)

1. **`<repo>/.aidevops.json` `.verify` block** (canonical):

   ```json
   {
     "verify": {
       "enabled": true,
        "format": "pnpm run format:check",
        "format_fix": "pnpm run format:fix",
        "lint": "pnpm run lint",
        "lint_fix": "pnpm run lint:fix",
        "typecheck": "pnpm run typecheck"
     }
   }
   ```

   Set `"enabled": false` to opt the repo out entirely. Omit any `*_fix` slot to disable autofix for that check (it falls through to the mentor message).

2. **`<repo>/package.json` scripts** — only exact, non-empty scripts from tracked project metadata are used. Format checks require `format:check`, `format-check`, or a `format` body containing a recognised check/no-write flag. Fix commands require declared `format:fix`/`format_fix` or `lint:fix`/`lint_fix` scripts; aidevops never appends guessed flags. Multiple package-manager lockfiles, or a `packageManager` declaration conflicting with the tracked lockfile, are ambiguous and block inference.

3. **`.agents/configs/repo-verify-defaults.conf`** — evidence-based toolchain detection from tracked files. Cargo and Go have standard commands; Python requires committed Ruff/Black/Flake8 configuration. `pyproject.toml` or `setup.py` alone is not sufficient evidence.

4. **No match: silent skip (exit 0).** Repo is not verify-eligible; nothing to enforce.

Audit with `aidevops lint audit [--repo PATH|--all] [--json] [--strict]`.
Preview configuration with `aidevops lint configure --dry-run`; apply current-repo
local policy with `--apply`. `configure --all` never edits canonical repositories;
`--write-pr-plan` writes worker-ready isolated-PR plans for tracked changes.
`aidevops init` installs the guard immediately when code quality is enabled, and
`aidevops update` reruns the idempotent migration/rollout when detector, hook,
defaults, init, update, or installer implementation changes.

### Auto-fix policy

- `AIDEVOPS_PREPUSH_AUTOFIX=1` (set explicitly): run `*_fix` on failure, `git add -A && git commit --amend --no-edit --no-verify`, re-run the check.
- `AIDEVOPS_PREPUSH_AUTOFIX=0`: emit a mentoring failure with the exact suggested fix command, exit 1.
- **Default (when unset):** ON in headless contexts (`FULL_LOOP_HEADLESS` / `AIDEVOPS_HEADLESS` / `OPENCODE_HEADLESS` / `GITHUB_ACTIONS`), OFF in interactive sessions. The interactive default keeps the user in the loop on automated commit-amends.
- **Typecheck never auto-fixes** — semantic failures need code changes regardless of `AUTOFIX`.

### Skip conditions (exit 0 fast)

- `AIDEVOPS_PREPUSH_REPO_VERIFY=0` (per-push bypass)
- `GITHUB_ACTIONS=true` (CI runs verify itself; redundant)
- Working tree dirty (a verify run would conflate WIP with the actual push state — warn + skip)
- No verify config resolved
- `jq` missing (config parsing requires it)

### Bypass

- One push: `AIDEVOPS_PREPUSH_REPO_VERIFY=0 git push ...`
- All hooks: `git push --no-verify`
- Disable autofix only: `AIDEVOPS_PREPUSH_AUTOFIX=0 git push ...`
- Debug discovery: `AIDEVOPS_PREPUSH_REPO_VERIFY_DEBUG=1 git push ...`

### Test harness

`.agents/scripts/tests/test-repo-verify-pre-push-hook.sh` — 14 hermetic end-to-end scenarios covering bypass paths, all three discovery layers, autofix amend + recheck, and the typecheck-never-autofixes invariant. Run: `bash .agents/scripts/tests/test-repo-verify-pre-push-hook.sh`.
