<!-- aidevops:brief-schema=v2 -->

# t18965: Regression test — emptied gopass namespace must not block plaintext secret resolution

> **Scope narrowed 2026-11-11 08:40Z:** the behaviour fix landed independently
> as t18966 / pr:#37724 (whole-store `gopass ls --flat` instead of a prefix
> listing) while this session was answering follow-up questions. The duplicate
> implementation in this branch was dropped in favour of the merged one; the
> remaining deliverable is the regression test, which pr:#37724 did not add.
> The test is written against the behaviour, not the implementation: a prefix
> listing that fails while the store still lists must resolve from
> `credentials.sh`.

## Pre-flight (auto-populated by briefing workflow)

- [x] Memory recall: `gopass plaintext credentials secret resolution` → `0` hits — no relevant stored lessons
- [x] Discovery pass: `0` commits / `0` merged PRs / `0` open PRs touch `.agents/scripts/secret-helper.sh` in last 48h
- [x] File refs verified: `3` refs checked, all present at HEAD (`secret-helper.sh:130-138`, `secret-helper.sh:466-469`, `tests/test-secret-helper.sh:48-114`)
- [x] Tier: `tier:standard` — a secret-resolution trust boundary is changed, with a verified reference pattern and an existing stubbed test harness
- [x] Seeded draft PR decision recorded: skipped — the interactive session implemented and verified the fix directly

## Origin

- **Created:** 2026-11-11
- **Session:** opencode:ses_e3e38920effefaR0s7jWbZHzKx
- **Created by:** ai-interactive
- **Blocked by:** none
- **Conversation context:** The maintainer asked to migrate every secret out of gopass into the plaintext `credentials.sh` store. After the four `aidevops/` entries were copied, digest-verified and removed from gopass, every `aidevops secret` operation stopped resolving, including the 32 keys that had always been in `credentials.sh`.

## What

`secret-helper.sh` must treat an absent or emptied `aidevops/` gopass namespace
as "gopass owns nothing" and fall through to the plaintext credential files,
while still failing closed when the gopass store itself cannot be listed.
`secret check`, `secret get` and subprocess injection must all keep working for
a user who has migrated every secret out of gopass.

## Why

Observed failure on a real installation: once `aidevops/` was empty,
`gopass ls --flat aidevops/` exits non-zero with `Entry "aidevops" not found`.
`gopass_owns_secret()` mapped any listing failure to "owned", so every name
routed to `gopass show`, which then failed. `build_secret_env()` aborted the
whole injection with `Unable to list gopass secrets for injection`. The result
was total loss of secret resolution for 36 keys that were present and readable
in `credentials.sh`. Migration out of gopass is a supported direction (the
helper ships `import-credentials` and `prune-plaintext`), so the reverse path
must not brick the store.

## Tier

**Selected tier:** `tier:standard`

**Tier rationale:** The change narrows a fail-closed secret-resolution rule, so
it needs a correct distinction between "namespace absent" and "store
unreadable"; the target functions and the stubbed test harness are already
verified.

## PR Conventions

Leaf task: the delivering PR uses a closing keyword for its issue.

## How (Approach)

### Files to Modify

- `EDIT: .agents/scripts/secret-helper.sh:130-138` — in `gopass_owns_secret()`, when the namespace listing fails, probe the store with a bare `gopass ls`; a listable store means the name is not gopass-owned
- `EDIT: .agents/scripts/secret-helper.sh:466-469` — in `build_secret_env()`, only abort when the bare `gopass ls` probe also fails; otherwise continue with an empty gopass set so the plaintext supplement runs
- `EDIT: .agents/scripts/tests/test-secret-helper.sh:48-114` — add an `AIDEVOPS_TEST_EMPTY_NAMESPACE` branch to the gopass stub: bare `ls` succeeds, `ls --flat aidevops/` prints the not-found error to stderr and exits 1
- `EDIT: .agents/scripts/tests/test-secret-helper.sh` — add `test_empty_gopass_namespace_uses_plaintext` and register it in the runner list

### Complete Write Surface

- **Callers/readers:** `get_secret_value()`, `cmd_check`, `cmd_get` and `build_secret_env()` are the only readers of `gopass_owns_secret()`; `secret run`/`secret NAME -- cmd` are the injection entry points
- **Writers/mutation paths:** none — this task changes read/resolution only; `cmd_set`, `import-credentials` and `prune-plaintext` are untouched
- **Existing verification/tests:** `.agents/scripts/tests/test-secret-helper.sh` (51 cases incl. locked-store and fail-closed paths), `.agents/scripts/tests/test-secret-read-guards.sh`
- **Schemas/config:** evidence-backed N/A — no config or schema change; `GOPASS_PREFIX` stays `aidevops`
- **Generated/deployed mirrors:** `~/.aidevops/agents/scripts/secret-helper.sh` is the deployed mirror, refreshed by `setup.sh --non-interactive`
- **Migrations/backfills:** evidence-backed N/A — no stored state
- **Cleanup/rollback paths:** reverting the commit restores the previous fail-closed behaviour; no data migration to undo

### Implementation Steps

1. `gopass_owns_secret()`: replace `listing=$(gopass ls --flat "${GOPASS_PREFIX}/" 2>/dev/null) || return 0` with a branch that, on listing failure, runs `gopass ls &>/dev/null && return 1` before the historical `return 0`.
2. `build_secret_env()`: on a failed namespace listing, probe `gopass ls &>/dev/null`; print the existing error and `return 1` only when the probe fails, otherwise set `available_secrets=""` and continue.
3. Extend the test stub with `AIDEVOPS_TEST_EMPTY_NAMESPACE=true` and add the regression test asserting: `check` exits 0, injection runs the child command, the output contains no `Unable to list gopass secrets` error, and the placeholder value never appears in output.
4. Keep comments explaining why a listing failure is not evidence of an unreadable store (`gopass ls` reads entry names without decrypting).

### Hazards and Compatibility

- **Concurrency/atomicity:** evidence-backed N/A — read-only resolution, no shared state written
- **Migration/rollback:** none; a revert restores prior behaviour without touching stored secrets
- **Mixed-version/backward compatibility:** installations that still keep secrets in gopass are unaffected, because a successful namespace listing takes the original path
- **Idempotency/retry:** resolution is pure; repeated calls behave identically
- **Partial failure/recovery:** a genuinely unreadable store still fails closed with the original message, so a locked GPG cannot silently fall back to a stale plaintext value

### Complexity Impact

- **Target function:** `gopass_owns_secret` / `build_secret_env` in `.agents/scripts/secret-helper.sh`
- **Current line count:** 9 / 49 lines (threshold: 100 lines for function-complexity)
- **Estimated growth:** +7 / +6 lines
- **Projected post-change:** 16 / 55 lines (16% / 55% of threshold)
- **Action required:** None

### Verification Before Dispatch

```bash
bash .agents/scripts/tests/test-secret-helper.sh
bash .agents/scripts/tests/test-secret-read-guards.sh
shellcheck .agents/scripts/secret-helper.sh .agents/scripts/tests/test-secret-helper.sh
.agents/scripts/secret-helper.sh check TYPESAFE_API_KEY
```

- **Surface mapping:** the secret-helper suite proves resolution, injection,
  locked-store fail-closed behaviour and the new empty-namespace path; the
  read-guards suite proves no secret-read guard regressed; ShellCheck covers the
  two edited scripts; the `check` invocation exercises the real installation
  whose `aidevops/` namespace is empty.
- **Broad verification trigger:** Not required — two edited shell files, no
  shared config, dependency graph or release surface involved.

### Scope Boundaries

**Hard boundaries:** do not change `cmd_set`, `import-credentials`,
`prune-plaintext`, the plaintext escaping format, or the locked-store
fail-closed behaviour; do not weaken redaction; no secret value in test output.

**AI brief owner:** interactive session `ses_e3e38920effefaR0s7jWbZHzKx`

### Files Scope

- `.agents/scripts/secret-helper.sh`
- `.agents/scripts/tests/test-secret-helper.sh`

## Acceptance Criteria

- [ ] With a listable store and no `aidevops/` namespace, `secret check NAME` exits 0 and injection runs the child command for a plaintext-only secret

  ```yaml
  verify:
    method: bash
    run: "bash .agents/scripts/tests/test-secret-helper.sh"
  ```

- [ ] A genuinely unlistable gopass store still fails closed rather than reading plaintext

  ```yaml
  verify:
    method: codebase
    pattern: "Unable to list gopass secrets for injection"
    path: ".agents/scripts/secret-helper.sh"
  ```

- [ ] No secret value reaches test output or error text

  ```yaml
  verify:
    method: codebase
    pattern: "migrated-placeholder-value"
    path: ".agents/scripts/tests/test-secret-helper.sh"
  ```

- [ ] ShellCheck is clean on both edited scripts
- [ ] `test-secret-read-guards.sh` passes unchanged

## Context & Decisions

- `gopass ls` reads entry names from the store layout and needs no decryption,
  so a namespace listing failure is not evidence that GPG or the store is
  unavailable. That distinction is the whole fix.
- Rejected: keeping a placeholder entry in `aidevops/` to make the listing
  succeed. It hides the bug for one installation and leaves the trap for every
  other user who migrates out.
- Rejected: dropping the fail-closed rule entirely. A locked store must still
  refuse to serve a possibly stale plaintext value.
- Related framework-side observation from the same session: the plaintext store
  accepts only `export NAME="value"` with `\"`/`\\` escaping, and silently
  mis-parses single-quoted assignments. Out of scope here; worth a separate
  task if import tooling grows.

## Relevant Files

- `.agents/scripts/secret-helper.sh:130-138` — ownership decision
- `.agents/scripts/secret-helper.sh:466-469` — injection abort path
- `.agents/scripts/secret-helper.sh:773` — canonical plaintext assignment format
- `.agents/scripts/tests/test-secret-helper.sh:48-114` — gopass stub harness

## Dependencies

- **Blocked by:** none
- **Blocks:** nothing queued; unblocks any installation that migrates fully out of gopass
- **External:** none

## Estimate Breakdown

| Phase | Time | Notes |
|-------|------|-------|
| Research/read | 20m | locate ownership and injection paths, read stub harness |
| Implementation | 30m | two guarded branches plus stub flag and regression test |
| Verification | 20m | two suites, ShellCheck, real-install check, hot deploy |
| **Total** | **1h 10m** | |
