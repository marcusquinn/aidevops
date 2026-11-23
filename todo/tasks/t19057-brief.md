# t19057: fix(headless-runtime): accept labelled POST_PR_HANDOFF lines so verified handoffs do not loop as premature exits

**Task ID:** `t19057` | **Issue:** GH#38596

## Origin

Interactive session (productivity mission), from tracing the 24h `premature_exit` worker family (24 runs, all exit 77, 11 session keys; 407 of 640 worker-minutes on those keys went to premature exits). One key, `issue-25152` in a managed app repo, used all 10 continuation retries in a single run, replying each time with an unchanged handoff report.

Read-only analysis of the shared OpenCode DB (last 72h) found 22 premature-exit continuation prompts across 12 worker sessions. The assistant reply that triggered each continuation:

| Trigger | Count |
|---|---|
| `POST_PR_HANDOFF` written in a form other than an exact standalone line | 9 |
| no terminal marker (invented states such as `FULL_LOOP: PARTIAL, not complete`, or real incomplete work) | 9 |
| BLOCKED prose in checkpoint-continuation sessions (separate GH#37926 receipt path, out of scope) | 3 |
| other | 1 |

The missed handoff forms were `FULL_LOOP: POST_PR_HANDOFF`, `POST_PR_HANDOFF: <summary>`, `` `POST_PR_HANDOFF`: <summary> `` and `Outcome: POST_PR_HANDOFF. <summary>`.

## What

1. `output_has_post_pr_handoff_signal` and the `has_post_pr_handoff` check inside `output_has_completion_signal` (`.agents/scripts/headless-runtime-model.sh`) accept only a line exactly equal to `POST_PR_HANDOFF`. `_HEADLESS_BLOCKED_LINE_PATTERN` in the same file already tolerates a leading `Outcome:`/`Status:`/`Result:` label, bold/backtick wrapping and trailing prose. Add `_HEADLESS_POST_PR_HANDOFF_LINE_PATTERN` with the same shape: the marker must lead a model-text line, optionally after `>` quote markup and an `Outcome|Status|Result|State|FULL_LOOP` label, optionally wrapped in `**`, `__` or backticks, and followed only by end of line or a `:`, `.`, `;`, space-hyphen, `—` or `–` separator. Reject negated forms (`POST_PR_HANDOFF: not yet`, `: none`, `: no`) and mid-sentence mentions (`I will mention POST_PR_HANDOFF later`, `POST_PR_HANDOFF is not valid here`). `TASK_COMPLETE` stays exact.
2. The premature-exit continuation prompt in `_handle_cmd_run_continuation_attempt` (`.agents/scripts/headless-runtime-run.sh`) always says "implement the required code changes … create a PR", even after the worker's PR has merged. Add one sentence: when the task's PR already exists (open or merged) and only CI, review, merge or work outside this attempt remains, end with `POST_PR_HANDOFF` alone on its own line, and always put the terminal marker alone on its own line.

## Why

A missed handoff marker turns a finished worker into a continuation loop. The model reports the same state each turn, then the run exhausts its continuation budget and is recorded as `premature_exit`, which feeds fast-fail and escalation and can redispatch a task that is already handed off. The marker only routes into `_hrw_gate_post_pr_handoff`, which independently verifies the exact-head PR, summary and linkage. A false positive therefore lands on the verified-handoff failure path, never on unverified success.

## How (files)

- EDIT `.agents/scripts/headless-runtime-model.sh`: define `_HEADLESS_POST_PR_HANDOFF_LINE_PATTERN` next to `_HEADLESS_BLOCKED_LINE_PATTERN` (about line 685). Use it in `output_has_post_pr_handoff_signal` (about line 835) and in `has_post_pr_handoff` inside `output_has_completion_signal` (about line 761, passed as an extra argv like the BLOCKED pattern). Keep synthetic-part and tool-output exclusions unchanged.
- EDIT `.agents/scripts/headless-runtime-run.sh`: continuation prompt in `_handle_cmd_run_continuation_attempt` (about line 423).
- EDIT `.agents/scripts/tests/test-headless-runtime-provider-tests-replay.sh`: add `test_post_pr_handoff_accepts_labelled_line_forms` with the observed accepted forms and the negated/mid-sentence rejected forms; register it in `.agents/scripts/tests/test-headless-runtime-helper.sh`.

### Files Scope

- `.agents/scripts/headless-runtime-model.sh`
- `.agents/scripts/headless-runtime-run.sh`
- `.agents/scripts/tests/test-headless-runtime-provider-tests-replay.sh`
- `.agents/scripts/tests/test-headless-runtime-helper.sh`
- `todo/tasks/t19057-brief.md`
- `TODO.md`

## Acceptance

- The four observed forms are detected by `output_has_post_pr_handoff_signal` and `output_has_completion_signal`.
- `I will mention POST_PR_HANDOFF after more work.`, `POST_PR_HANDOFF is not valid here`, `POST_PR_HANDOFF: not yet` and `Outcome: not POST_PR_HANDOFF` are rejected.
- Existing replay, checkpoint, completion and integration-recovery suites still pass.
- ShellCheck is clean on changed shell files.

## Verification

```bash
bash .agents/scripts/tests/test-headless-runtime-provider-tests-replay.sh
bash .agents/scripts/tests/test-headless-runtime-checkpoint-tests.sh
bash .agents/scripts/tests/test-headless-runtime-completion-tests.sh
bash .agents/scripts/tests/test-integration-recovery.sh
shellcheck .agents/scripts/headless-runtime-model.sh .agents/scripts/headless-runtime-run.sh .agents/scripts/tests/test-headless-runtime-provider-tests-replay.sh
```
