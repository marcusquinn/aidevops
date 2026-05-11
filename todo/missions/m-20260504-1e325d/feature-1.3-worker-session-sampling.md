<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Feature 1.3: failed worker session sampling

## Scope

Sample failed worker sessions for missing context, wrong model/account routing, premature exits, and tool-use mistakes. Evidence is extracted from `.agents/scripts/worker-activity-helper.sh summary --since 24h --json --no-pr-check` plus representative failure excerpts. Local/private repository names and local paths are intentionally redacted.

## Window and aggregate evidence

Captured 2026-05-10 from the mission worktree:

```text
.agents/scripts/worker-activity-helper.sh summary --since 24h --json --no-pr-check
```

Summary:

| Metric | Count |
|---|---:|
| Total worker events | 65 |
| Success | 48 |
| Watchdog stall killed | 2 |
| Watchdog stall continued | 3 |
| Signal killed continued | 7 |
| Premature exit | 3 |
| Blocked | 1 |
| Local error | 1 |
| Rate limited | 0 |

Structured evidence fields added by PR #23229 are present for recent failures: `launch_failure_cause`, `kill_reason`, and `next_action`. That makes this sampling actionable without rereading whole transcripts first.

## Representative samples

| Bucket | Representative evidence | Diagnosis | Recommended systemic action |
|---|---|---|---|
| Missing/invalid worker context | Mission feature 3.3 worker failed locally before model work because the launch tried to change into a removed recorded worktree path. Excerpt evidence: sandbox child exit `1`, OpenCode error `Failed to change directory to <removed mission worktree>`. | Brief/worktree context can go stale across mission continuations. The worker cannot recover if the dispatcher supplies an obsolete worktree and no valid fallback. | Pre-dispatch validator should verify the worktree path exists immediately before launch; if absent, recreate/refresh the linked worktree or rewrite the brief with the replacement path before starting the runtime. |
| Premature exit after doing work | A worker on issue #23324 edited and verified a doc change, then ended with a final status saying the file was modified but not committed. Runtime classified `premature_exit`, `launch_failure_cause=model_stopped_before_completion`, `next_action=resume_session_with_completion_contract`. | The model stopped at local implementation status instead of full-loop completion. This is not missing technical context; it is lifecycle non-compliance after successful edits. | Keep the V9 headless continuation contract in launch prompts and add a deterministic post-run validator that treats “modified/not committed” final answers as resumable completion-contract failures. |
| Tool-use mistake / duplicate active worktree | Issue #23303 worker ran `pre-edit-check` inside a worktree already owned by the same worker process, received an ownership conflict, and then created extra verification/resume worktrees while related work had already merged in PR #23307. | Worker over-explored recovery and spawned extra worktrees instead of recognizing superseded merged work. This is both a tool-use mistake and dedupe gap. | Before redispatch/resume on repeated failures, dedupe against recently merged PRs and verify issue state. If fixed, close/supersede instead of launching another implementation worker. |
| Tool-use mistake / public privacy risk | External-repo worker correctly generalized a private repo-specific troubleshooting row, but commit failed because signing required an unavailable passphrase. The blocker comment included precise evidence and avoided unsigned bypass. | The implementation was right; failure was commit-signing environment, not model/account routing. It also demonstrates why PR/comment bodies need public-path/private-name scrubbing. | Add a preflight commit-signing availability check for headless workers and continue enforcing privacy scrubbing for public comments/artifacts. |
| Wrong model/account routing | No recent 24h rate-limit failures were observed; all sampled aidevops mission failures used OpenAI `gpt-5.5`, with one external worker using `gpt-5.4-mini`. The current failure set is dominated by lifecycle/tooling, not account exhaustion. | Model/account routing was not the active root cause in this window. The mission baseline’s earlier rate-limit spike appears improved or shifted after provider-pressure work. | Keep provider/model pressure telemetry, but prioritize lifecycle recovery, stale worktree validation, and dedupe gates for the current failure mix. |

## Conclusions

1. The highest-value durable fix is not more always-loaded guidance; it is deterministic launch and completion validation around worktree freshness, commit/PR completion, and superseded-issue dedupe.
2. PR #23229’s structured diagnostic fields materially improve triage: recent summaries already identify `model_stopped_before_completion`, `local_runtime_error`, `mid_session_interruption`, and recommended next actions.
3. Current evidence does not justify increasing model tier or account capacity for these failures. `gpt-5.5` had enough capability; the failures were stale context, lifecycle exits, signing environment, or duplicated work.
4. Privacy-safe artifacts should avoid local paths and private repo basenames; raw excerpts remain local evidence, while public reports should use placeholders.

## Verification

- `bash .agents/scripts/tests/test-worker-diagnostic-evidence.sh` passed.
- `bash .agents/scripts/tests/test-worker-activity-helper.sh` passed.
- `shellcheck .agents/scripts/headless-runtime-helper.sh .agents/scripts/headless-runtime-lib.sh .agents/scripts/worker-activity-helper.sh .agents/scripts/tests/test-worker-diagnostic-evidence.sh` passed.
- `git status --short --branch` was used from the linked worktree to verify branch state.
- `git diff --stat origin/main...HEAD` was used from the linked worktree to verify changed-file scope.
