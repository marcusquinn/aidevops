<!-- aidevops:brief-schema=v2 -->

# t19008: fix(approval): accept every canonical terminal-blocker release the writer emits

## Pre-flight (auto-populated by briefing workflow)

- [x] Discovery: `approval-snapshot-v2.sh` `canonical_terminal_blocker_release` (line 138) is a hand-copied regex of `terminal-blocker-circuit.sh` `_terminal_blocker_recovery` (lines 999-1075). The writer changed (GH#36760 `aed371e4ed`, plus the runner-recovery and source-access classes) and the reader did not.
- [x] Reproduced on 2026-11-14 by feeding real writer output for every class through the reader's own jq definition (method under Verification Before Dispatch).

## Origin

- Created: 2026-11-14, interactive productivity-mission session (OpenCode), author ai-interactive, while preparing t19007.

## What

Trusted worker release comments posted after a maintainer approval must not stale that approval when they are exact writer output. Today six writer outputs are rejected:

| Writer output | Reader verdict |
|---|---|
| `missing_files_scope`, `files_scope_excluded`, `target_code_blocker`, `external_trigger_pending`, `permission_required`, `unknown` | canonical |
| `source_access_blocked owner=access-owner` | **not canonical** (class missing) |
| `push_policy_timeout`, `network_policy_timeout`, `runner_capability_unmet` (`owner=runner-recovery`) | **not canonical** (classes missing) |
| `input_required` with a sanitized question | **not canonical** (new Next action text and the `Input requested:` line) |
| `input_required` without a question | **not canonical** (fallback Next action text) |
| `unknown` with a `CHECKPOINT_UNKNOWN_TRIAGE pending_work ...` line | **not canonical** (extra line) |

## Why

A non-canonical trusted comment after the approval cutoff is treated as content drift, so the approval verifies as `STALE_APPROVAL` and a needs-maintainer-review issue returns to the maintainer for re-approval. A runner-capability release (for example, a runner lacking a declared secret) can therefore stale an approved issue even though it changed nothing the maintainer approved. No live occurrence was found in this runner's `pulse.log` (its 9 `STALE_APPROVAL` lines are one closed issue staled by completion releases), so this is a latent defect with a deterministic reproduction. The existing test hides the drift: `test-approval-helper-content-binding.sh:685` still uses the pre-GH#36760 `input_required` text, which the writer's own test (`test-terminal-blocker-circuit.sh:582`) asserts is no longer emitted.

## Tier

**Selected tier:** `tier:standard`

The fix is a bounded regex and test update at a marked trust boundary, with a verified reproduction.

## How (Approach)

### Files to Modify

- `EDIT: .agents/scripts/approval-snapshot-v2.sh:138` — extend `canonical_terminal_blocker_release`.
- `EDIT: .agents/scripts/tests/test-approval-helper-content-binding.sh:662-700` — build the release fixtures from the real writer and cover every class.

### Complete Write Surface

- **Callers/readers:** `canonical_terminal_blocker_release` is used only at `approval-snapshot-v2.sh:194`, in the trusted-author, post-cutoff comment exclusion.
- **Writers/mutation paths:** `.agents/scripts/terminal-blocker-circuit.sh` `terminal_blocker_observation_fragment` (line 705) and `_terminal_blocker_recovery` (line 999) produce the text; the release wrapper adds the `CLAIM_RELEASED reason=blocked ...` line and the worker footer. No writer change is needed.
- **Existing verification/tests:** `.agents/scripts/tests/test-approval-helper-content-binding.sh` (canonical release cases around lines 662-700) and `.agents/scripts/tests/test-terminal-blocker-circuit.sh` (writer text, question sanitizer around lines 560-600).
- **Schemas/config:** N/A because the public release comment format written by `terminal-blocker-circuit.sh` is unchanged; only its reader is corrected.
- **Generated/deployed mirrors:** `setup.sh` deploys `.agents/scripts/` to `~/.aidevops/agents/scripts/`; no generated output.
- **Migrations/backfills:** N/A because approvals are verified on read; already-stale approvals become `VERIFIED` again on the next read with no backfill.
- **Cleanup/rollback paths:** revert the PR in `.agents/scripts/approval-snapshot-v2.sh`; no state is written.

### Implementation Steps

1. In the reason alternatives add `source_access_blocked owner=access-owner` and `(?:push_policy_timeout|network_policy_timeout|runner_capability_unmet) owner=runner-recovery`.
2. In the Next action alternatives add the exact current strings from `_terminal_blocker_recovery` for those classes and the two current `input_required` strings (with question: "Supply the requested input in the issue brief; ..."; without: "no sanitized question recorded; the originating runner's recovery supervisor must publish one. No maintainer action is possible until then."). Keep the legacy `input_required` string so comments posted by older runners still verify.
3. After `Raw evidence remains in protected worker telemetry\\.\\n`, admit at most one optional line: either the literal prefix `Input requested:` plus one space, followed by 1-500 characters excluding control characters and `` <>`@ `` (the sanitizer contract in `_terminal_blocker_public_question`, lines 960-997), or `CHECKPOINT_UNKNOWN_TRIAGE pending_work brief=[a-f0-9]{64} head=[a-f0-9]{40,64}`. Keep the `^`/`$` anchors, so any other extra prose stays content-bound.
4. In the test, generate each release body by sourcing `terminal-blocker-circuit.sh` in a subshell and calling `terminal_blocker_observation_fragment`, rather than copying strings, so future writer changes fail this test instead of silently staling approvals. Replace the stale fixture at line 685.
5. Run the tests and `shellcheck`.

### Hazards and Compatibility

- **Concurrency/atomicity:** N/A because verification is a pure read of comment history; no locks or writes are involved.
- **Migration/rollback:** none; the reader is evaluated on every verification.
- **Mixed-version/backward compatibility:** keep every existing alternative, including the legacy `input_required` action, so comments from older runners still verify.
- **Idempotency/retry:** verification is deterministic for the same comment history.
- **Partial failure/recovery:** N/A because a regex mismatch fails closed to `STALE_APPROVAL`, today's behaviour.

### Verification Before Dispatch

```bash
bash .agents/scripts/tests/test-approval-helper-content-binding.sh
bash .agents/scripts/tests/test-terminal-blocker-circuit.sh
shellcheck .agents/scripts/approval-snapshot-v2.sh .agents/scripts/tests/test-approval-helper-content-binding.sh
```

- **Surface mapping:** `test-approval-helper-content-binding.sh` proves each writer class verifies as canonical (acceptance 1) and that extra prose, an unlisted owner and an external author stay content-bound (acceptance 2). `test-terminal-blocker-circuit.sh` proves the writer text is unchanged. `shellcheck` covers both touched files.
- **Broad verification trigger:** Not required. One reader regex and its test.

### Scope Boundaries

**Hard boundaries:** do not widen trusted associations, the cutoff or the anchors. Admit only exact writer output; free text is limited to the sanitized `Input requested:` line. Keep the `#aidevops:trust-boundary` comment.

**AI brief owner:** the interactive maintainer session that filed this task.

**Recovery:** preserve the current PR and use the structured runtime request and Pulse intake in `reference/worker-discipline.md` when local recovery is unsafe.

### Files Scope

- `.agents/scripts/approval-snapshot-v2.sh`
- `.agents/scripts/tests/test-approval-helper-content-binding.sh`
- `TODO.md`

## Acceptance Criteria

- [ ] Positive: a trusted, post-cutoff release comment generated by the current writer for every class in the table, including `input_required` with and without a question and `unknown` with a triage line, verifies as `VERIFIED`.
- [ ] Negative: the same comment with extra prose, an unlisted owner, an `Input requested:` line containing `<`, `@` or a newline, or a non-trusted author still verifies as `STALE_APPROVAL`.
- [ ] Negative: the existing approval binding tests pass unchanged apart from the replaced stale fixture.

## Context & Decisions

- Root cause is two hand-maintained copies of one format. Generating the test fixtures from the writer is the drift guard. A shared format module would be cleaner but touches the trust boundary more widely, so it is out of scope.
