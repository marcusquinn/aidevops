# Pre-Commit Hooks: Self-Block Bootstrap Playbook

When a pre-commit validator has a bug that prevents editing the hook itself, the only path out is `--no-verify`. This playbook documents the incident pattern and the protocol for handling it.

## The Self-Block Pattern

A pre-commit validator rejects a commit that fixes the validator itself. Example:

- Validator checks: "no `--no-verify` in commit messages"
- You fix the validator to allow legitimate `--no-verify` uses
- The fix commit contains `--no-verify` in the message (documenting the change)
- The validator rejects the fix commit
- You cannot commit the fix without `--no-verify`

This is tolerable once per self-blocking class of validator bug, but institutional knowledge must make the path explicit.

## Triage

Before authorizing `--no-verify`, verify the block is caused by the validator being fixed — not a separate validator bug masking it.

**Questions to ask:**
1. Does the commit fix the validator that's blocking it?
2. Is the block a direct consequence of the fix, or is there a separate validator bug?
3. Have I read the validator code to confirm the bug?

If the answer to #1 is no, or if #2 suggests a separate bug, file a separate issue for the underlying validator bug and do NOT use `--no-verify` yet.

## Bootstrap

When you have confirmed the self-block:

1. **Ask the user for explicit `--no-verify` authorization**, citing:
   - The canonical "hook-fixes-itself" scenario
   - The specific validator name and the bug it has
   - The fact that this is a one-time bootstrap, not a general bypass

2. **Include a regression test in the same PR** that covers the specific bug pattern — without it, the fix ships untested and the bug may re-occur.

3. **Authorization does NOT extend to subsequent commits.** Each self-blocking class gets its own explicit authorization. If you discover a second validator with the same pattern, ask again.

4. **Document the incident** in the PR body or a comment so future sessions can reference it.

## Test

Every self-block fix PR must include a regression test. The test should:

- Reproduce the original bug (validator rejects a valid commit)
- Verify the fix (validator accepts the commit after the fix)
- Be runnable in CI or locally via `shellcheck` / `markdownlint-cli2` / relevant linter

Example test structure:
```bash
# Test: validator should allow --no-verify in fix commits
test_validator_allows_no_verify_in_fix_commits() {
  # Create a commit message that documents a --no-verify fix
  local msg="fix: allow --no-verify in validator (t2209)"
  
  # Run the validator
  if ! validator_check "$msg"; then
    echo "FAIL: validator rejected fix commit"
    return 1
  fi
  
  echo "PASS: validator accepts fix commit"
  return 0
}
```

## Siblings

When investigating a self-block, you may discover sibling validator bugs that would also need the same treatment. **Do NOT fix them in the same PR.** Instead:

1. File separate issues for each sibling bug
2. Tag them with `blocked-by:<this-PR-task>` so they're tracked as dependencies
3. Fix them in separate PRs after the base fix lands

This prevents scope creep and keeps the regression test focused on one bug per PR.

## Cross-Reference

For the runtime-debugging analogue (investigating deployed code that differs from source), see `prompts/build.txt` §"Stale-symptom investigations" (t2036).

For the general pre-commit hook architecture and installation, see `reference/pre-commit-hooks.md` (this file) and `.agents/scripts/install-hooks-helper.sh`.
