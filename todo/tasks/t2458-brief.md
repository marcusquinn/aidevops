---
mode: subagent
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->
# t2458: prevent credential-bearing URLs in helper output (sanitize + retrofit + guard + audit)

## Pre-flight (auto-populated by briefing workflow)

- [x] Memory recall: `credential URL sanitize scrub` / `secret exposure tool output transcript` → 0 hits — no relevant accumulated lessons for this specific class; the seed regex exists in `contributor-insight-helper.sh:89` as local code, not as a memory.
- [x] Discovery pass: 0 commits / 0 merged PRs / 0 open PRs touch target files in last 48h (verified via `git log --since=48h`, `gh pr list --search "credential sanitize"`)
- [x] File refs verified: 5 emit sites confirmed at `claim-task-id.sh:1569`, `agent-sources-helper.sh:442`, `opencode-github-setup-helper.sh:253,275`, `contributor-activity-helper.sh:1286`; template `.agents/hooks/gh-wrapper-guard-pre-push.sh` verified; registration pattern `.agents/scripts/install-pre-push-guards.sh` verified
- [x] Tier: `tier:standard` — multiple files, retrofit + new hook + audit subcommand + test authoring; Sonnet territory; no skeletons, so not `tier:simple`; known patterns exist, so not `tier:thinking`

## Origin

- **Created:** 2026-04-21
- **Session:** claude-code:aidevops-t2450-postmerge
- **Created by:** marcusquinn (ai-interactive)
- **Parent task:** — (standalone)
- **Conversation context:** During the t2450 session, a `gho_*` GitHub token surfaced verbatim in tool output when `git remote get-url origin` was captured and re-emitted by `claim-task-id.sh`. The credential was rotated immediately. User directed a multi-layer prevention design: shared sanitizer + retrofit + pre-push guard + remote audit, all in one PR; a fourth layer (transcript-side plugin scrub) was filed separately as it touches runtime plugin code rather than framework helpers.

## What

Build three cooperating layers that prevent credential-bearing URLs from reaching the LLM transcript via helper-script output:

1. **Layer 1 — Shared sanitizer + retrofit.** New `scrub_credentials()` and `sanitize_url()` functions in `shared-constants.sh`, plus retrofit of the 5 known emit sites.
2. **Layer 2 — Pre-push guard.** New hook that blocks new unsanitized emissions of `$remote_url` in `.agents/scripts/**.sh` and `.agents/hooks/**.sh`.
3. **Layer 3 — Per-repo remote audit.** New `aidevops security scan-remotes` subcommand that walks `repos.json` and reports remotes with credential-bearing URLs, emitting an advisory when findings exist.

A 4th layer (transcript-side plugin scrub that catches leaks the helpers can't) is filed as a separate follow-up task.

## Why

- The t2450 leak demonstrates that file-scoped defenses (`privacy-filter-helper.sh`, `secret-hygiene-helper.sh scan`, `contributor-insight-helper.sh`) do NOT cover live stdout/stderr from helper scripts. The leak was not in any file; it was in a `echo` of `git remote get-url` output.
- Verified `gh` CLI itself does not leak tokens (even `GH_DEBUG=1 gh api /user` keeps `Authorization` out of stdout/stderr). The primary emit vector is `git remote get-url` on machines configured with an embedded-credential helper (which we discovered can exist in the wild even when the current machine's config is clean).
- A prevention-at-emit layer catches every source (git config, gopass misconfig, accidental `git remote set-url` with a token) without having to enumerate them.
- Pre-push guard prevents future regressions — the retrofit alone is a point-in-time fix.
- Per-repo audit catches machines that already have a dirty remote before the leak happens.

## Tier

### Tier checklist (verify before assigning)

- [ ] 2 or fewer files to modify? — No (11 files: 5 retrofits, 1 shared add, 1 guard new, 1 guard-installer edit, 1 audit add, 3 tests)
- [ ] Every target file under 500 lines? — No (`shared-gh-wrappers.sh`, `claim-task-id.sh`, `shared-constants.sh` all exceed)
- [ ] Exact `oldString`/`newString` for every edit? — No (retrofits are mechanical but test files and new guard are skeleton-level)
- [x] No judgment or design decisions? — Design choices in sanitizer contract (strip vs redact) and advisory body format
- [x] No error handling or fallback logic to design? — Pre-push guard needs fail-open-when-missing semantics
- [x] No cross-package or cross-module changes? — All within `.agents/`
- [ ] Estimate 1h or less? — No (2-3h range)
- [ ] 4 or fewer acceptance criteria? — No (8 criteria)

Not checked: 6/8. `tier:standard`.

**Selected tier:** `tier:standard`

**Tier rationale:** 11 files, multiple new scripts, test authoring, a pre-push guard with fail-open semantics, and a security-audit subcommand design. All patterns exist in the codebase (`gh-wrapper-guard-pre-push.sh`, `install-pre-push-guards.sh`, `secret-hygiene-helper.sh`) so the worker is following rather than inventing — Sonnet is sufficient.

## PR Conventions

Leaf issue — PR body will use `Resolves #20203`. Not parent-task.

## How (Approach)

### Worker Quick-Start

```bash
# 1. Seed regex (canonical, from contributor-insight-helper.sh:89):
#    Pattern already matches: sk-, ghp_, gho_, ghs_, ghu_, glpat-, xoxb-, xoxp-
#    Add for t2458: github_pat_ (fine-grained PAT prefix)
sed -E 's/(sk-|ghp_|gho_|ghs_|ghu_|github_pat_|glpat-|xoxb-|xoxp-)[A-Za-z0-9_-]{10,}/[redacted-credential]/g'

# 2. URL authority strip pattern:
#    https://user:password@host/path  -> https://host/path
#    https://token@host/path          -> https://host/path
sed -E 's|^(https?://)[^@/]+@|\1|'

# 3. Pre-push guard template: .agents/hooks/gh-wrapper-guard-pre-push.sh (90 lines)
# 4. Registration pattern: .agents/scripts/install-pre-push-guards.sh
#    (currently handles 'privacy' + 'complexity'; add 'credential' as third)
```

### Files to Modify

- `EDIT: .agents/scripts/shared-constants.sh` — add `scrub_credentials()` + `sanitize_url()` near the end of file (before the final `source ...shared-gh-wrappers.sh` line), with doc comments.
- `EDIT: .agents/scripts/claim-task-id.sh:1569` — wrap `${remote_url}` with `$(sanitize_url "${remote_url}")`.
- `EDIT: .agents/scripts/agent-sources-helper.sh:442` — same retrofit.
- `EDIT: .agents/scripts/opencode-github-setup-helper.sh:253,275` — retrofit both.
- `EDIT: .agents/scripts/contributor-activity-helper.sh:1286` — retrofit the error message path.
- `NEW: .agents/hooks/credential-emission-pre-push.sh` — ~90-line guard modeled on `gh-wrapper-guard-pre-push.sh`. Scans `git diff --cached` (pre-commit mode) or `git diff <base>..<head>` (pre-push mode) for unsanitized emissions; blocks on violation.
- `EDIT: .agents/scripts/install-pre-push-guards.sh` — add `credential` to guard filter choices, add deployed-hook constant, add `_find_hook_src` case, add `_write_dispatcher` block, update install/status/uninstall to handle third guard. Update help text.
- `EDIT: .agents/scripts/secret-hygiene-helper.sh` — add `scan-remotes` subcommand that iterates `repos.json initialized_repos[]` and reports dirty remotes. Advisory emission on findings.
- `NEW: .agents/scripts/tests/test-credential-sanitizer.sh` — unit tests for every token prefix + URL-authority case.
- `NEW: .agents/scripts/tests/test-credential-emission-guard.sh` — happy + violation fixtures for the pre-push hook.
- `NEW: .agents/scripts/tests/test-remote-url-audit.sh` — fixtures for clean and credential-embedded remotes.
- `EDIT: TODO.md` — add t2458 entry with `ref:GH#20203`.
- `NEW: todo/tasks/t2458-brief.md` — this file.

### Implementation Steps

1. Add sanitizer functions to `shared-constants.sh`:

   ```bash
   # scrub_credentials: redact token-prefix patterns from arbitrary text.
   # Idempotent. Safe to pipe through multiple times.
   # Usage: scrub_credentials "text possibly containing tokens"
   scrub_credentials() {
     local text="$1"
     printf '%s' "$text" | sed -E 's/(sk-|ghp_|gho_|ghs_|ghu_|github_pat_|glpat-|xoxb-|xoxp-)[A-Za-z0-9_-]{10,}/[redacted-credential]/g'
     return 0
   }

   # sanitize_url: strip credential-bearing authority from a URL, then
   # scrub any residual token-prefix patterns in the remainder.
   # https://token@host/x -> https://host/x
   # https://user:pass@host/x -> https://host/x
   # Usage: sanitize_url "$(git remote get-url origin)"
   sanitize_url() {
     local url="$1"
     # Strip user:pass@ or token@ from URL authority
     local stripped
     stripped=$(printf '%s' "$url" | sed -E 's|^([a-z]+://)[^@/]+@|\1|')
     # Also scrub anywhere else the token might appear
     scrub_credentials "$stripped"
     return 0
   }
   ```

2. Retrofit the 5 emit sites. Example for `claim-task-id.sh:1569`:

   ```bash
   # before:
   echo "issue_url=${remote_url}/issues/${first_issue_num}"
   # after:
   echo "issue_url=$(sanitize_url "${remote_url}")/issues/${first_issue_num}"
   ```

3. Write `.agents/hooks/credential-emission-pre-push.sh`:
   - Follow `gh-wrapper-guard-pre-push.sh` structure (lines 1-90).
   - Use `git diff` against pushing commits to find added/modified lines in `.agents/{scripts,hooks}/*.sh`.
   - Block when a new line contains `echo|printf|log_` + `$remote_url` + no `sanitize_url` or `scrub_credentials` on the same line.
   - Env vars: `CREDENTIAL_GUARD_DISABLE=1`, `CREDENTIAL_GUARD_DEBUG=1`.

4. Extend `install-pre-push-guards.sh`:
   - Add `DEPLOYED_CREDENTIAL_HOOK="$HOME/.aidevops/agents/hooks/credential-emission-pre-push.sh"`.
   - Add `HOOK_MARKER_CREDENTIAL="# guard:credential"`.
   - Add `credential)` case in `_find_hook_src`.
   - Add `_inc_credential` logic in `cmd_install` mirroring `_inc_privacy`/`_inc_complexity`.
   - Add a `CREDENTIAL_BLOCK` heredoc in `_write_dispatcher` mirroring `PRIVACY_BLOCK`/`COMPLEXITY_BLOCK`.
   - Update `status` command to report the new guard.
   - Update `help` text header.

5. Add `scan-remotes` to `secret-hygiene-helper.sh`:
   - Function `cmd_check_remotes()` that reads `~/.config/aidevops/repos.json`, iterates `initialized_repos[].path`, runs `git -C <path> remote get-url origin 2>/dev/null`, matches against credential-URL pattern (`://[^@/]+@`).
   - On finding: emit `[DIRTY] <slug>: <remediation>` (NEVER emit the URL itself).
   - On summary: if any dirty, write advisory file to `~/.aidevops/advisories/remote-credentials-<date>.advisory`.
   - Register in `main` dispatcher.

6. Write three test files following `test-privacy-guard.sh` pattern. Each script creates a temp repo, exercises the target, asserts expected behavior.

7. Run shellcheck, markdownlint, and tests.

### Verification

```bash
# Direct unit test of sanitizers:
cd ~/Git/aidevops-bugfix-t2458-credential-url-sanitize
bash -c 'source .agents/scripts/shared-constants.sh
  test "$(sanitize_url "https://gho_ABCD1234abcd5678xyz@github.com/o/r.git")" = \
       "https://github.com/o/r.git" && echo PASS || echo FAIL'

# Full test suite
bash .agents/scripts/tests/test-credential-sanitizer.sh
bash .agents/scripts/tests/test-credential-emission-guard.sh
bash .agents/scripts/tests/test-remote-url-audit.sh

# Shellcheck
shellcheck .agents/scripts/shared-constants.sh \
  .agents/scripts/claim-task-id.sh \
  .agents/scripts/agent-sources-helper.sh \
  .agents/scripts/opencode-github-setup-helper.sh \
  .agents/scripts/contributor-activity-helper.sh \
  .agents/scripts/install-pre-push-guards.sh \
  .agents/scripts/secret-hygiene-helper.sh \
  .agents/hooks/credential-emission-pre-push.sh \
  .agents/scripts/tests/test-credential-sanitizer.sh \
  .agents/scripts/tests/test-credential-emission-guard.sh \
  .agents/scripts/tests/test-remote-url-audit.sh

# Markdown
npx --yes markdownlint-cli2 todo/tasks/t2458-brief.md
```

## Files Scope

- `.agents/scripts/shared-constants.sh`
- `.agents/scripts/claim-task-id.sh`
- `.agents/scripts/agent-sources-helper.sh`
- `.agents/scripts/opencode-github-setup-helper.sh`
- `.agents/scripts/contributor-activity-helper.sh`
- `.agents/scripts/install-pre-push-guards.sh`
- `.agents/scripts/secret-hygiene-helper.sh`
- `.agents/hooks/credential-emission-pre-push.sh`
- `.agents/scripts/tests/test-credential-sanitizer.sh`
- `.agents/scripts/tests/test-credential-emission-guard.sh`
- `.agents/scripts/tests/test-remote-url-audit.sh`
- `todo/tasks/t2458-brief.md`
- `TODO.md`
- `.gitignore`
- `.secretlintignore`

## Acceptance Criteria

- [ ] `scrub_credentials` and `sanitize_url` defined in `shared-constants.sh` and available via `source`.

  ```yaml
  verify:
    method: bash
    run: "source .agents/scripts/shared-constants.sh && declare -F scrub_credentials sanitize_url >/dev/null"
  ```

- [ ] All 5 identified emit sites pipe through `sanitize_url`.

  ```yaml
  verify:
    method: codebase
    pattern: "echo\\s+\"[^\"]*\\$\\{?remote_url\\}?[^\"]*\"(?!.*sanitize_url)"
    path: ".agents/scripts/claim-task-id.sh .agents/scripts/agent-sources-helper.sh .agents/scripts/opencode-github-setup-helper.sh .agents/scripts/contributor-activity-helper.sh"
    expect: absent
  ```

- [ ] New pre-push guard exists and is executable.

  ```yaml
  verify:
    method: bash
    run: "test -x .agents/hooks/credential-emission-pre-push.sh"
  ```

- [ ] `install-pre-push-guards.sh install --guard credential` installs the guard.

  ```yaml
  verify:
    method: bash
    run: ".agents/scripts/install-pre-push-guards.sh install --guard credential && .agents/scripts/install-pre-push-guards.sh status | grep -q credential"
  ```

- [ ] `secret-hygiene-helper.sh scan-remotes` audits repos and reports without exposing credentials.

  ```yaml
  verify:
    method: bash
    run: ".agents/scripts/secret-hygiene-helper.sh scan-remotes >/dev/null"
  ```

- [ ] Unit tests pass.

  ```yaml
  verify:
    method: bash
    run: "bash .agents/scripts/tests/test-credential-sanitizer.sh"
  ```

- [ ] Guard integration test passes.

  ```yaml
  verify:
    method: bash
    run: "bash .agents/scripts/tests/test-credential-emission-guard.sh"
  ```

- [ ] Audit integration test passes.

  ```yaml
  verify:
    method: bash
    run: "bash .agents/scripts/tests/test-remote-url-audit.sh"
  ```

- [ ] Shellcheck clean on all modified and new `.sh` files.
- [ ] Layer 4 (runtime-plugin transcript scrub) filed as a separate task with its own brief and task ID.

## Context & Decisions

- **Why strip authority AND scrub rather than only scrub:** a `sanitize_url` that only ran `scrub_credentials` would leave `https://[redacted-credential]@github.com/...` visible in output — better than leaking the value, but still shows that the URL HAD credentials. Stripping authority first produces `https://github.com/...` which is both safe and clean.
- **Why `github_pat_` wasn't in the seed regex:** `contributor-insight-helper.sh:89` was written before fine-grained PAT prefixes existed. Adding it here as a fix.
- **Why a pre-push hook, not pre-commit:** pre-push is where the centralized `install-pre-push-guards.sh` infrastructure lives; pre-commit is per-repo and doesn't have a unified installer. The emit pattern is static (grep-able in the diff) so either would work — we pick pre-push for consistency with the other guards.
- **Why not transcript-side (Layer 4) in the same PR:** plugin code is a separate surface with different test infrastructure (TypeScript, plugin runtime, not shell), different review cadence, different release cadence. Keeping it separate makes both PRs smaller and reviewable. Filed as separate task.
- **Why the audit reads `repos.json` and not `git config --list --show-origin`:** we want cross-repo coverage; a given machine might have dozens of repos, not all in `repos.json`. But `repos.json` is the framework's source of truth for "repos we care about", so scanning it finds the ones that matter.

## Relevant Files

- `.agents/scripts/contributor-insight-helper.sh:89` — seed regex location.
- `.agents/scripts/profile-readme-helper.sh:1216` — existing `_sanitize_url` (different purpose: URL validation for markdown safety).
- `.agents/scripts/prompt-guard-helper.sh:594` — existing URL query-param redaction pattern.
- `.agents/hooks/gh-wrapper-guard-pre-push.sh` — template for new pre-push guard (90 lines).
- `.agents/hooks/privacy-guard-pre-push.sh` — secondary template reference.
- `.agents/scripts/install-pre-push-guards.sh` — registration pattern (currently `privacy` + `complexity`).
- `.agents/scripts/secret-hygiene-helper.sh` — existing `aidevops security` subcommand dispatcher.

## Dependencies

- **Blocked by:** — (none)
- **Blocks:** Layer 4 follow-up task (transcript-side plugin scrub) — depends on sanitizer regex being finalized here so the plugin uses the same pattern.
- **External:** — (none)

## Estimate Breakdown

| Phase | Time | Notes |
|-------|------|-------|
| Research/read | 20m | Already done during brief authoring |
| Implementation | 2h | Layer 1 (30m) + Layer 2 (45m) + Layer 3 (30m) + tests (15m) |
| Testing | 30m | Run each test, fix shellcheck, markdownlint |
| **Total** | **~3h** | |
