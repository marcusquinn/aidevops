<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# t1540: fix: gh auth token missing workflow scope blocks CI workflow PRs

## Session Origin

Pulse cycle 2026-03-17. Issue GH#5138 filed after worker for wpallstars/wp-plugin-starter-template-for-ai-coding issue #57 completed implementation but could not push branch containing `.github/workflows/` changes.

## What

Add the `workflow` scope to the required GitHub OAuth scopes in the aidevops setup flow, and add pre-push detection so workers fail early (with actionable guidance) rather than silently failing at push time.

## Why

Any issue that requires CI workflow changes (retry logic, caching, action version pins, new jobs) will silently fail at push time. The worker completes, the branch exists locally, but no PR is created. The issue stays open indefinitely. This is a real blocker for CI-related tasks across all managed repos.

## How

1. **setup.sh / auth flow**: Add `workflow` to the required scopes list. When running `gh auth login` or `gh auth refresh`, include `-s workflow`. Update the scope validation check to verify `workflow` is present.

2. **Pre-push detection** (headless-runtime-helper.sh or pre-edit-check.sh): Before `git push`, check if any staged/committed files match `.github/workflows/*`. If so, verify the current `gh` token has `workflow` scope via `gh auth status`. If missing, emit a clear error with `gh auth refresh -s workflow` instructions and block the push.

3. **Worker fallback**: When push fails with the workflow scope error pattern (`refusing to allow an OAuth App to create or update workflow`), the worker should comment on the issue with the branch name and manual push instructions. This is a safety net, not the primary fix.

4. **Docs**: Update any auth setup documentation to mention the `workflow` scope requirement.

## Acceptance Criteria

- `gh auth status` after fresh setup includes `workflow` scope
- Worker pushing a branch with `.github/workflows/` changes succeeds
- Pre-push check detects missing `workflow` scope and provides actionable error
- ShellCheck clean on all modified scripts
- Existing auth flows (non-workflow PRs) unaffected

## Context

- Error message: `refusing to allow an OAuth App to create or update workflow without workflow scope`
- Current scopes: `admin:public_key, gist, read:org, repo`
- Missing scope: `workflow`
- `gh auth refresh -s workflow` is the one-line fix for existing installations
- setup.sh auth flow needs to request this scope for new installations
