<!-- aidevops:brief-schema=v2 -->

# fix-the-fixer detector classifies 0 of 10 issues: ai-research cannot authenticate the simple tier in the isolated runtime

## Origin

- **Created:** 2026-11-16
- **Created by:** ai-interactive
- **Conversation context:** Interactive pulse log review found `[fix-the-fixer-detector] WARN ... classified=0, apply-failed=0, skipped:auth-error=10` repeating in `pulse-wrapper.log`, and a direct ai-research call reproduced the underlying auth failure.

## What

Make the fix-the-fixer detector produce real classifications on an install that authenticates through Anthropic OAuth with no `ANTHROPIC_API_KEY`, or make it fail loudly and visibly instead of degrading silently every cycle.

## Why

Observed in `~/.aidevops/logs/pulse-wrapper.log` (7 occurrences, most recent `2026-11-14T13:27Z`):

```text
[fix-the-fixer-detector] WARN: processed 10 issue(s) across 2 repo(s) — classified=0,
apply-failed=0, skipped:auth-error=10, skipped:LLM-failure=0
(detector observability degraded; AI research credentials invalid)
```

Every one of the 10 processed issues was skipped on auth, so the detector has produced zero signal while still consuming a pulse stage each cycle.

Reproduced directly from an interactive session on the same host:

```text
Error: The isolated OpenCode runtime cannot authenticate the Anthropic OAuth provider
for the simple tier. Pure public triage does not load the provider-auth plugin;
select a provider with native authentication.
```

So the failure is not a bad key — it is that the detector's research path runs in an isolated/pure runtime that deliberately does not load the provider-auth plugin, while the host has no `ANTHROPIC_API_KEY` to fall back to. `pulse-fix-the-fixer-detector.sh:145-152` builds its config stamp from `ANTHROPIC_API_KEY` plus the mtimes of `~/.config/aidevops/credentials.sh` and the ai-research helper, and `_is_auth_error()` at lines 155-163 matches `unauthorized` / `invalid api key` / `authentication_error` — which is why the message is classified as an auth error rather than a runtime/plugin configuration error.

The cooldown from GH#23430 works (the cooldown file `~/.aidevops/cache/fix-the-fixer-detector-auth.cooldown` is absent, i.e. expired rather than stuck), but a cooldown only reduces the log noise. The capability stays dead and nothing surfaces it outside a manual log read: `pulse-check-helper.sh report` does not list a finding for it.

## Tier

**Selected tier:** `tier:standard`

**Tier rationale:** The target files and failure signature are verified, but the worker must choose between provider fallback, an explicit configuration requirement, and a visible-degradation path, so the exact execution contract is not fully supplied.

## PR Conventions

Leaf task: use a closing keyword referencing this issue.

## How (Approach)

### Progressive Context Plan

- **Read first:** `.agents/scripts/pulse-fix-the-fixer-detector.sh:140-330` — the auth-error classification, cooldown and per-issue skip path.
- **Read first:** `.agents/scripts/ai-research-helper.sh` provider/tier selection — the code that produces the isolated-runtime message.
- **Load only if** changing provider selection: the prior art in GH#37205 and GH#30649 (both closed) to avoid reintroducing a fixed provider pin or an OAuth-token-as-x-api-key fallback.
- **Why:** The previous fixes in this area were about provider pinning and OAuth fallback; a naive "add a fallback" change risks reintroducing them.
- **Stop when:** it is clear whether the correct behaviour is a provider fallback, a hard configuration requirement, or a visible pulse-check finding.

### Worker Quick-Start

```bash
# Reproduce the underlying auth failure (no pulse needed):
~/.aidevops/agents/scripts/ai-research-helper.sh --prompt "reply OK" 2>&1 | head -5

# Observe the detector's own reporting:
rg -n 'AI research credentials invalid' ~/.aidevops/logs/pulse-wrapper.log | tail -3

# Key verified facts:
#  auth cooldown file: ~/.aidevops/cache/fix-the-fixer-detector-auth.cooldown (absent = expired)
#  config stamp inputs: ANTHROPIC_API_KEY, credentials.sh mtime, ai-research-helper mtime
#    (pulse-fix-the-fixer-detector.sh:145-152)
#  auth-error matcher: pulse-fix-the-fixer-detector.sh:155-163
```

### Files to Modify

- `EDIT: .agents/scripts/pulse-fix-the-fixer-detector.sh:155-163` — `_is_auth_error()` currently cannot distinguish "credential is invalid" from "this runtime cannot load the provider-auth plugin". Separate the two so the rationale and the operator guidance are accurate.
- `EDIT: .agents/scripts/pulse-fix-the-fixer-detector.sh:520-560` — the summary/rationale emission, so a fully-skipped run is reported as a degraded capability rather than a routine WARN.
- `EDIT: .agents/scripts/ai-research-helper.sh` — the tier/provider selection that currently cannot authenticate the simple tier in the isolated runtime. The decision between selecting a natively-authenticating provider and requiring explicit configuration belongs to this task.
- `EDIT: .agents/scripts/pulse-check-helper.sh` — add a finding so a detector that classified 0 of N issues on auth appears in `pulse-check report` instead of only in the raw log.

### Complete Write Surface

- **Callers/readers:** `.agents/scripts/pulse-fix-the-fixer-detector.sh` is invoked from the pulse cycle (`rg -n 'fix-the-fixer' .agents/scripts/pulse-*.sh`); `ai-research-helper.sh` is called from many domain helpers, so a provider-selection change has broad blast radius.
- **Writers/mutation paths:** `~/.aidevops/cache/fix-the-fixer-detector-auth.cooldown` (`pulse-fix-the-fixer-detector.sh:165-177`), `~/.aidevops/cache/pulse-fix-the-fixer-last-run`, the `fix-the-fixer` issue label, and `pulse-wrapper.log`.
- **Existing verification/tests:** `.agents/scripts/tests/test-pulse-fix-the-fixer-detector-auth-cooldown.sh`, `.agents/scripts/tests/test-pulse-fix-the-fixer-label.sh`, `.agents/scripts/tests/test-pulse-check-helper.sh`.
- **Schemas/config:** the cooldown file format (`created_at`, `cooldown_seconds`, `config_stamp`, `reason`) — a stamp-input change invalidates existing cooldowns, which is acceptable but must be intentional.
- **Generated/deployed mirrors:** `setup.sh --non-interactive` redeploys to `~/.aidevops/agents/scripts/`.
- **Migrations/backfills:** none — cooldown files are disposable.
- **Cleanup/rollback paths:** `_auth_cooldown_active()` already deletes a cooldown whose `config_stamp` no longer matches (`pulse-fix-the-fixer-detector.sh:195-198`); preserve that self-healing behaviour.

### Implementation Steps

1. Reproduce with the Worker Quick-Start commands and capture the exact helper exit code and stderr, so the classification change is based on the real signature rather than the log paraphrase.
2. Decide the resolution and record it in the PR body: (a) ai-research selects a natively-authenticating provider for the simple tier in an isolated runtime; (b) the detector requires explicit credentials and reports an actionable configuration instruction; or (c) both, with the detector degrading visibly whenever no usable provider exists. Name why the chosen option does not reintroduce GH#37205 (provider pinned, no Anthropic fallback) or GH#30649 (OAuth token sent as `x-api-key`).
3. Split runtime/plugin-capability errors from credential-invalid errors in `_is_auth_error()` and carry the distinction into `RATIONALE`.
4. Make a run where every processed issue was skipped on auth report a degraded capability, including the one concrete operator action (for example `aidevops secret set ANTHROPIC_API_KEY`) rather than only a count.
5. Add the `pulse-check-helper.sh` finding so the degradation is visible in `pulse-check report`.
6. Extend the existing auth-cooldown test with the new classification, and the pulse-check test with the new finding.

### Hazards and Compatibility

- **Concurrency/atomicity:** the cooldown file is written non-atomically today (`pulse-fix-the-fixer-detector.sh:170-175`); do not make concurrent pulse stages depend on it being complete.
- **Migration/rollback:** changing the `config_stamp` inputs invalidates existing cooldowns, causing one extra attempt per install. Acceptable, but state it in the PR body.
- **Mixed-version/backward compatibility:** `ai-research-helper.sh` is shared. A provider-selection change must not alter behaviour for callers that already authenticate successfully.
- **Idempotency/retry:** the detector must not start retrying every cycle when no provider can ever authenticate — the cooldown must still apply to the new error class.
- **Partial failure/recovery:** a detector that cannot classify must never apply a label or close an issue on partial evidence.

### Verification Before Dispatch

```bash
bash .agents/scripts/tests/test-pulse-fix-the-fixer-detector-auth-cooldown.sh
bash .agents/scripts/tests/test-pulse-fix-the-fixer-label.sh
bash .agents/scripts/tests/test-pulse-check-helper.sh
.agents/scripts/linters-local.sh --changed
# Production-facing evidence after setup.sh --non-interactive:
~/.aidevops/agents/scripts/ai-research-helper.sh --prompt "reply OK" 2>&1 | head -5
~/.aidevops/agents/scripts/pulse-check-helper.sh report --budget 60 2>&1 | rg -i 'fix-the-fixer|detector'
```

- **Surface mapping:** the cooldown test covers classification and cooldown behaviour, the label test covers the no-false-label guarantee, the pulse-check test covers the new finding, and the two production commands prove the user-visible outcome on this host.
- **Broad verification trigger:** Not required — changes are confined to two pulse helpers, the ai-research helper, and their existing tests.

### Scope Boundaries

**Hard boundaries:** Never send an OAuth token as an API key (GH#30649). Never log or echo credential values; the existing `_hash_text` digest approach stays. Do not make the detector apply labels, close issues, or dispatch work on unclassified evidence. Do not add new test infrastructure — extend the three existing tests.

**AI brief owner:** interactive session that filed this issue.

### Files Scope

- `.agents/scripts/pulse-fix-the-fixer-detector.sh`
- `.agents/scripts/ai-research-helper.sh`
- `.agents/scripts/pulse-check-helper.sh`
- `.agents/scripts/tests/test-pulse-fix-the-fixer-detector-auth-cooldown.sh`
- `.agents/scripts/tests/test-pulse-check-helper.sh`

## Acceptance Criteria

- [ ] On a host with no `ANTHROPIC_API_KEY`, the detector either classifies issues successfully or reports a degraded capability naming the one concrete operator action — not a bare `skipped:auth-error=N` count.

  ```yaml
  verify:
    method: bash
    run: "bash .agents/scripts/tests/test-pulse-fix-the-fixer-detector-auth-cooldown.sh"
  ```

- [ ] A runtime/plugin-capability failure is classified distinctly from an invalid credential, and the rationale text reflects which one occurred.

  ```yaml
  verify:
    method: bash
    run: "bash .agents/scripts/tests/test-pulse-fix-the-fixer-detector-auth-cooldown.sh"
  ```

- [ ] `pulse-check-helper.sh report` surfaces a finding when the detector classified 0 of N processed issues on auth.

  ```yaml
  verify:
    method: bash
    run: "bash .agents/scripts/tests/test-pulse-check-helper.sh"
  ```

- [ ] Negative guarantee: no OAuth token is ever sent as an `x-api-key`, and no credential value appears in logs or issue comments.

  ```yaml
  verify:
    method: codebase
    pattern: "x-api-key.*OAUTH|x-api-key.*oauth_token"
    path: ".agents/scripts"
    expect: absent
  ```

- [ ] Changed-file lint is clean, with zero ShellCheck violations in the edited scripts.

  ```yaml
  verify:
    method: bash
    run: ".agents/scripts/linters-local.sh --changed"
  ```

## Context & Decisions

- Prior art, all closed: GH#23430 added the auth cooldown (works as designed — it suppresses noise, not the root cause); GH#37205 fixed a provider pin that never fell back to Anthropic; GH#30649 fixed an OAuth-token-as-`x-api-key` fallback that could never succeed; GH#36707 fixed an exhausted-provider dispatch block.
- The cooldown is not the bug. Evidence: the cooldown file is absent (expired, self-healing) and the WARN still recurred across 7 cycles.
- Not a cause: a stale deployed script. All local pulse processes ran bundle `3.39.211`, matching the deployed `VERSION`.

## Relevant Files

- `.agents/scripts/pulse-fix-the-fixer-detector.sh:145-152` — `_auth_config_stamp()`, the `ANTHROPIC_API_KEY` dependency.
- `.agents/scripts/pulse-fix-the-fixer-detector.sh:155-163` — `_is_auth_error()`, the over-broad matcher.
- `.agents/scripts/pulse-fix-the-fixer-detector.sh:165-205` — cooldown write and expiry.
- `.agents/scripts/pulse-fix-the-fixer-detector.sh:544` — the summary line that produced the observed WARN.
- `.agents/scripts/ai-research-helper.sh` — provider/tier selection for the isolated runtime.

## Dependencies

- **Blocked by:** nothing.
- **Blocks:** fix-the-fixer classification signal; accurate pulse self-diagnosis.
- **External:** resolving by configuration would need an Anthropic API key stored via `aidevops secret set ANTHROPIC_API_KEY` — never in chat or in the issue.
