---
mode: subagent
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->
# t2207: Split pre-commit hook — fast local checks stay, slow network checks move to pre-push

## Origin

- **Created:** 2026-04-18
- **Session:** OpenCode interactive (marcusquinn)
- **Created by:** marcusquinn (human-directed AI-interactive)
- **Parent task:** t2191 (follow-up)
- **Conversation context:** While wiring up the pre-commit hook installer in t2191, we discovered the hook itself (which already existed but was never installed anywhere) runs secretlint + a SonarCloud API call + optional CodeRabbit CLI, and collectively these exceeded the 2-minute interactive commit timeout on the canonical aidevops repo. The t2191 PR ended up committing with `--no-verify`. A hook that gets routinely bypassed is worse than no hook, because it trains authors to ignore it.

## What

Split `pre-commit-hook.sh main()` into two paths:

- **pre-commit** (fast, local-only, target <5s): TODO.md validation, repo-root-files allowlist, shellcheck, shell lint rules. Runs on every `git commit`.
- **pre-push** (slower, network-dependent, target <60s): secretlint, SonarCloud API call, optional CodeRabbit CLI. Runs on `git push`.

Update `install-hooks-helper.sh` so `setup.sh` installs both hooks; update `install_pre_commit_hook()` added in t2191 and add a sibling `install_pre_commit_push_checks_hook()` that chains into the existing privacy-guard / gh-wrapper-guard pre-push hook.

## Why

- A 2-minute pre-commit hook is a broken feedback loop. Authors learn `--no-verify` as muscle memory and the hook stops catching anything.
- Secretlint, SonarCloud, and CodeRabbit CLI are valuable but not time-critical at commit time — they're equally useful one level later at push time (and a push doesn't block the author's local flow the way a commit does).
- The split also clarifies the hook's purpose: pre-commit is "did you write code that's syntactically wrong"; pre-push is "did your commits introduce policy violations worth gating the shared branch".

## Tier

### Tier checklist (verify before assigning)

- [ ] 2 or fewer files to modify? — **No** (3 files: pre-commit-hook.sh, install-hooks-helper.sh, possibly a new tests/ regression test).
- [ ] Every target file under 500 lines? — **No** (pre-commit-hook.sh is 634 lines).
- [ ] Exact `oldString`/`newString` for every edit? — **No** (refactor — main() body splits into two functions).
- [x] No judgment or design decisions? — **Yes** (the split boundary is clear: local vs network).
- [x] No error handling or fallback logic to design? — **Yes** (existing hooks' error handling transfers).
- [x] No cross-package or cross-module changes? — **Yes**.
- [ ] Estimate 1h or less? — **No** (estimate ~2h with testing).
- [x] 4 or fewer acceptance criteria? — **Yes**.

**Selected tier:** `tier:standard`

**Tier rationale:** Refactor of a 634-line file plus coordinated installer change. Clear pattern to follow (install_gh_wrapper_guard_hook exists and models the pre-push install pattern). Sonnet is sufficient.

## PR Conventions

Leaf (non-parent) issue. Use `Resolves #19693` in the PR body.

## How (Approach)

### Files to Modify

- `EDIT: .agents/scripts/pre-commit-hook.sh:541` — `main()`. Split into `main_pre_commit()` (fast path) and `main_pre_push()` (slow path). Dispatcher at bottom picks based on `$(basename "$0")` or a `HOOK_MODE` env var.
- `EDIT: .agents/scripts/install-hooks-helper.sh` — add `install_pre_push_quality_hook()` modelled on `install_gh_wrapper_guard_hook` (which already exists). Call it from `install_hook()` alongside the existing `install_pre_commit_hook` and `install_gh_wrapper_guard_hook`.
- `NEW: .agents/scripts/tests/test-pre-commit-split.sh` — regression test covering both paths (commit rejected on SC2086; push rejected on a fabricated exposed-secret in test fixture).

### Implementation Steps

1. **Refactor `pre-commit-hook.sh`:**
   - Extract the first half of `main()` (TODO validation + repo-root check + shellcheck + shell lint rules) into `main_pre_commit()`.
   - Extract the second half (secretlint, check_quality_standards, CodeRabbit CLI) into `main_pre_push()`.
   - Keep `main()` as a dispatcher:

     ```bash
     main() {
       local mode="${HOOK_MODE:-}"
       if [[ -z "$mode" ]]; then
         case "$(basename "$0")" in
           pre-commit) mode="pre-commit" ;;
           pre-push)   mode="pre-push" ;;
           *)          mode="pre-commit" ;;  # default for CLI invocation
         esac
       fi
       case "$mode" in
         pre-commit) main_pre_commit "$@" ;;
         pre-push)   main_pre_push "$@" ;;
         all)        main_pre_commit "$@" && main_pre_push "$@" ;;
         *)          print_error "Unknown HOOK_MODE: $mode"; return 1 ;;
       esac
     }
     ```

2. **Update `install-hooks-helper.sh`:**
   - Add `install_pre_push_quality_hook()` function. It chains into the existing `.git/hooks/pre-push` (which already runs `gh-wrapper-guard` and `privacy-guard`). Use the same marker-based detection pattern (`# aidevops-pre-push-quality-hook`).
   - Call it from `install_hook()` after `install_gh_wrapper_guard_hook`.
   - Update `check_status()` to report pre-push quality hook state.
   - Update `uninstall_hook()` to tear down cleanly.

3. **Write regression test** `tests/test-pre-commit-split.sh`:
   - Creates a temp git repo.
   - Installs both hooks via `install-hooks-helper.sh install`.
   - Commits a file with shellcheck SC2086 → expect rejection.
   - Commits a clean file → expect success.
   - Prepares a push with a fabricated secret in the fixture → expect pre-push rejection.
   - Pushes a clean commit → expect success.

4. **Timing verification** — commit a single file in the aidevops repo with both hooks installed, time it:

   ```bash
   time git commit --allow-empty -m "timing test"
   # Expected: real < 5s.
   ```

5. **Update dispatcher in `install-hooks-helper.sh`** — both installed hooks should call the same `pre-commit-hook.sh` with different `HOOK_MODE` env vars:

   ```bash
   # .git/hooks/pre-commit dispatcher:
   HOOK_MODE=pre-commit "$repo/.agents/scripts/pre-commit-hook.sh" "$@"

   # .git/hooks/pre-push dispatcher (chained):
   HOOK_MODE=pre-push "$repo/.agents/scripts/pre-commit-hook.sh" "$@"
   ```

### Verification

```bash
# Local smoke test on this very repo:
bash .agents/scripts/tests/test-pre-commit-split.sh

# Timing check on the aidevops repo itself:
cd ~/Git/aidevops
time git commit --allow-empty -m "timing check" && git reset HEAD^
# Expected: real < 5s.

# Confirm both hooks installed:
bash .agents/scripts/install-hooks-helper.sh status
# Expected: pre-commit-hook: installed AND pre-push-quality-hook: installed.
```

## Acceptance Criteria

- [ ] `pre-commit-hook.sh` `main()` split into `main_pre_commit()` (fast) and `main_pre_push()` (slow) with a clear dispatcher.
- [ ] `install-hooks-helper.sh install` installs BOTH hooks on first run; `status` reports both; `uninstall` removes both cleanly.
- [ ] Timing: on the aidevops repo, `git commit --allow-empty` completes in under 5s with both hooks installed.
- [ ] Regression test `tests/test-pre-commit-split.sh` covers both paths and passes.

## Context & Decisions

- **Why not just skip the slow checks when `--no-verify` is easy:** authors who habitually `--no-verify` to get past timeouts bypass ALL checks including the fast ones. Splitting preserves gate coverage while keeping commit feedback fast.
- **Why not `pre-commit-hook.sh` ships two scripts:** one script with a mode switch is easier to keep in sync than two scripts that duplicate validation helpers (TODO parsing, file filtering, allowlist loading).
- **Why pre-push, not post-commit:** post-commit runs after the commit already exists; rejecting at that point means the author has to `git reset` + re-commit. Pre-push rejection just means `git push` fails and the author can amend/rebase before pushing.
- **Relation to the dispatcher pattern in install-hooks-helper.sh:** the installer already creates a dispatcher for pre-commit that delegates to the canonical script. This task extends the same pattern to pre-push (with HOOK_MODE env var distinguishing them).

## Relevant Files

- `.agents/scripts/pre-commit-hook.sh:541` — `main()` to split.
- `.agents/scripts/install-hooks-helper.sh:79` — `install_gh_wrapper_guard_hook()` as the reference chain-install pattern.
- `.agents/scripts/install-hooks-helper.sh:163` (t2191) — `install_pre_commit_hook()` to be extended with sibling `install_pre_push_quality_hook()`.
- PR #19683 (t2191) — context for why this split exists.

## Dependencies

- **Blocked by:** none (t2191 merged 2026-04-18).
- **Blocks:** none.
- **External:** none.

## Estimate Breakdown

| Phase | Time |
|-------|------|
| Split pre-commit-hook.sh main() | 45m |
| Extend install-hooks-helper.sh | 30m |
| Regression test | 30m |
| Timing verification + fixups | 15m |
| **Total** | **~2h** |
