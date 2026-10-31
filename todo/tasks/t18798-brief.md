## What

Restore ordinary shell use for every OpenCode session. Since v3.39.87, `assertShellRead` in `.agents/plugins/opencode-aidevops/private-processing-policy.mjs` denies **every** shell command that is not a literal single command (pipes, `&&`, `;`, `$VAR`, globs, redirects) and every `sh -c` / `bash -c`. This applies in all sessions, including sessions with no local-only roots configured and bound local-only sessions.

## Why

f26477fca (GH#35978, PR #35985, released in v3.39.87) moved these two denials above the `if (binding.bound || !policy.roots.length) return;` exemption:

- `if (!words) deny("unclassifiable_shell_read");`
- the interpreter `-c` / `--command` denial

`assertPrivateProcessingRead` runs from `quality-hooks.mjs` `handleToolBefore` on every tool call, so these denials now cover every headless worker. Observed impact:

- Dates-lane batches in a private managed repository (three issues, 01:19Z on 2026-10-30, runner on v3.39.87) were each released as terminal blocker `permission_required` (fingerprint `acf05bf0adb333a56d232f79`) about 90 s after launch.
- On a second runner, a worker for the same repository recorded in `~/.aidevops/logs/worker-progress-blockers.jsonl` at 01:32Z: "The runtime vault policy denied the initial worktree inspection with `VAULT_POLICY_DENIED: unclassifiable_shell_read`". The same fingerprint was recorded.
- The first runner completed an earlier batch of the same lane under v3.39.85.

`permission_required` is a maintainer-gate retry class, so each affected issue waits for a human retry. Every repository's worker fleet stalls after its first compound command.

GH#35978's goal is still valid: relative and symlink aliases to `local-only-roots.json` and `local-ai-providers.conf` must not bypass the operator-config guard. That needs no fail-closed denial of all opaque shell syntax.

## How

EDIT `.agents/plugins/opencode-aidevops/private-processing-policy.mjs` `assertShellRead` (around lines 131-156):

1. Keep the canonical resolution of literal operands and the `classification_mutation` denial before the exemption. Those are cheap and exact.
2. In exempt sessions (`binding.bound || !policy.roots.length`), deny opaque commands (`!words`) and interpreter `-c`/`--command` scripts **only when the command text mentions a protected config file basename** (case-insensitive), with reason `unclassifiable_shell_read`. Otherwise return.
3. Unbound sessions with classified roots keep the existing strict path: literal readers only, and opaque or interpreter commands are denied.

EDIT `.agents/plugins/opencode-aidevops/tests/test-private-processing-policy.mjs`:

- Keep every GH#35978 alias assertion. Each one mentions the config basename, so each still throws.
- Rename "interpreter scripts fail closed before bound-session and empty-roots exemptions" to describe config-referencing scripts.
- Add a regression test: in bound and empty-roots sessions, `git status && git log -1 | head`, `rg foo $DIR`, `sh -c 'git status'` and the array form `["bash", "-lc", "pnpm test"]` must not throw.

### Files Scope

- `.agents/plugins/opencode-aidevops/private-processing-policy.mjs`
- `.agents/plugins/opencode-aidevops/tests/test-private-processing-policy.mjs`

## Acceptance

1. In bound sessions and sessions without classified roots, compound shell commands and `-c` scripts that do not mention a protected config basename are allowed.
2. Every existing GH#35978 alias, symlink and interpreter assertion still throws.
3. Unbound sessions with classified roots keep the strict literal-reader behaviour.
4. After release, a headless worker on a previously blocked lane batch passes its first worktree inspection.

## Verification

- `node --test .agents/plugins/opencode-aidevops/tests/test-private-processing-policy.mjs`
- `node --test .agents/plugins/opencode-aidevops/tests/` (plugin suite)
- After release: retry one previously blocked lane batch and confirm the worker runs past its initial inspection.
