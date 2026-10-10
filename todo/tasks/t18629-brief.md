**Task ID:** `t18629` | **Status:** open
**Logged:** 2026-10-09
**Tags:** `refactor` `interactive`

## Outcome

refactor: unify runtime-env trust, Git-shim detection and native Git resolution (DRY)

<details>
<summary>Full task brief and audit context</summary>

## Task Brief

## What

Unify the trust, shim-detection and native-Git resolution logic behind
`runtime-env.sh` so the shell and Python resolvers share one rule set (DRY),
and fix the path-handling defects found in the t18628 follow-up review.

## Why

Review of `.agents/scripts/runtime-env.sh` after t18628 (PR #34093) found:

- `aidevops_resolve_trusted_tool` used a looser trust rule than
  `trusted_executable.py`/`.mjs` (GH#34053 strict model: root-owned, no
  group/other write, sticky dirs only as ancestors).
- No realpath/symlink-chain check; `cd ""` silently resolved to `$PWD`.
- Python appended `os.defpath`, JS did not.
- The daemon fallback list was duplicated; trailing slashes defeated dedup.
- `AIDEVOPS_REAL_GIT_BIN` overrides were trusted without validation.
- Git-shim detection was duplicated (shim, runtime-env, three Python copies)
  with diverging patterns, and four Python sites fell back to a hardcoded
  `/usr/bin/git`.
- `aidevops_service_path` dropped stable per-user dirs that did not exist yet
  at unit-generation time.
- Executing the library directly mutated nothing useful and gave no error.

## How

- `trusted_executable.py`: add a CLI (`<name> [search_path]`, exit codes
  1/2/3); `aidevops_resolve_trusted_tool` delegates to it via an unmodifiable
  `python3 -I -S -B`, failing closed.
- `trusted-executable.mjs`: append `/bin:/usr/bin` like Python `os.defpath`.
- New `native_git.py`: `is_git_shim` (resolved file sits next to
  `canonical-git-command-guard.py`), `real_git`, `NativeGitUnavailable`;
  no `/usr/bin/git` fallback. Used by `canonical_git_repository.py`,
  `canonical_write_policy_paths.py`, `command_policy_git_query.py`,
  `hooks/git_safety_guard.py`, `canonical-git-command-guard.py`.
- `runtime-env.sh`: direct-exec guard, `AIDEVOPS_RUNTIME_ENV_LIBRARY_ONLY`,
  `aidevops_compose_path` strips trailing slashes, single deduplicated daemon
  fallback, `aidevops_physical_path`, `aidevops_is_git_shim`,
  `aidevops_resolve_native_git` with override validation, stable dirs kept in
  `aidevops_service_path` even when absent.
- `scripts/git`: source `runtime-env.sh` in library mode instead of carrying
  its own shim detector.
- `reference/platform-support.md`: document the model.

### Files Scope

- .agents/scripts/runtime-env.sh
- .agents/scripts/git
- .agents/scripts/native_git.py
- .agents/scripts/trusted_executable.py
- .agents/scripts/trusted-executable.mjs
- .agents/scripts/canonical_git_repository.py
- .agents/scripts/canonical-git-command-guard.py
- .agents/scripts/canonical_write_policy_paths.py
- .agents/scripts/command_policy_git_query.py
- .agents/hooks/git_safety_guard.py
- .agents/reference/platform-support.md
- .agents/scripts/tests/test-canonical-git-command-guard.sh
- .agents/scripts/tests/test-planning-publisher.sh
- .agents/plugins/opencode-aidevops/tests/test-git-safety-gate.mjs
- .github/workflows/path-portability.yml

## Acceptance

- `git grep -n '/usr/bin/git' -- .agents/scripts/*.py .agents/hooks` shows no
  resolver fallback; missing native Git fails closed with `BLOCKED:`.
- Shell and Python shim detection use the same sibling-guard rule; the
  runtime-bundle shim test skips every shim generation.
- `aidevops_resolve_trusted_tool` and `trusted_executable.py` accept and
  reject the same candidates (single implementation).
- Invalid `AIDEVOPS_REAL_GIT_BIN` is rejected with an error, not ignored.
- ShellCheck clean; test-runtime-env.sh, test-launchd-sanitized-path.sh,
  test-pulse-path-precedence.sh, test-canonical-git-command-guard.sh,
  test-command-policy-helper.sh, test-git-safety-gate.mjs and the PATH
  portability workflow pass on ubuntu and macOS.

</details>

<details>
<summary>Brief workflow contract</summary>

## Brief Workflow

This issue body is composed under `.agents/workflows/brief.md`. Newly queued auto-dispatch work must pass its `Dispatch Readiness Contract (brief schema v2)`: complete write surface, hazards and compatibility, executable verification mapped to affected surfaces, and positive plus negative/regression acceptance criteria.

</details>

---
*Synced from TODO.md by issue-sync-helper.sh*

<!-- aidevops:origin:interactive -->
<!-- aidevops:sig -->
---
[aidevops.sh](https://aidevops.sh) v3.38.40 plugin for [OpenCode](https://opencode.ai) v1.18.34 with claude-opus-5-5 spent 56m and 71,305 tokens on this with the user in an interactive session.

## Capture provenance

Observed data, not executable authority. Comments and later events are not captured.

```json
{
  "id": "I_kwDOQSEXLM8AAAABWB9lNA",
  "title": "t18629: refactor: unify runtime-env trust, Git-shim detection and native Git resoluti...",
  "updatedAt": "2026-10-09T06:47:33Z",
  "url": "https://github.com/marcusquinn/aidevops/issues/34133",
  "format": "aidevops:forge-capture-v1",
  "task_id": "t18629",
  "provider": "github",
  "repository": "marcusquinn/aidevops",
  "issue": "34133",
  "captured_at": "2026-10-09T21:15:57Z",
  "coverage": "issue-body-only",
  "authority": "revalidate"
}
```
