## What

A `permission_required` terminal blocker that a named person can resolve by answering in the issue must publish that ask. When the worker's final report carries exactly one valid `TERMINAL_BLOCKER_INPUT_OWNER` and one `TERMINAL_BLOCKER_QUESTION` alongside `TERMINAL_BLOCKER_REASON=permission_required`, the capture classifies the exit as `input_required:<owner>`. The release comment then shows the question as `Input requested:`, and the existing input hold, re-arm path and `/decisions` queue apply. The worker contract and dispatch prompt tell workers to name the ask for approval, authorization and sign-off holds.

## Why

`permission_required` releases publish only "Resolve the evidenced permission prerequisite through the human-owned approval flow". Unless the worker also ran `worker-permission-helper.sh request`, nothing names what to approve, and the evidence stays in the releasing runner's protected telemetry. The companion label is `needs-maintainer-input`, which tells the maintainer the ask is "named in the brief or the latest blocker comment". It is not, so nobody can act and the hold never moves.

Live evidence (2026-11-18, `maintainer-decisions-helper.sh list`): in one managed private organisation, 31 of 73 maintainer holds were "no-question" AI-side gaps. 13 of those were `permission_required` releases, including 7 consolidation tasks released within 2-3 minutes of dispatch. Other consolidation tasks on the same runner and model completed. The cause cannot be read from any other runner.

The local blocker log on this runner shows the same pattern: workers declared `permission_required` for maintainer approvals ("needs maintainer approval to supersede live rows", "authorize new sign-ins after a rate-limit window"). Those are owner decisions that one public question can resolve. The contract already routes spend and credential-route decisions to `input_required` (`.agents/scripts/headless-runtime-contract.sh:217-218`), but `TERMINAL_BLOCKER_QUESTION` is only captured for `input_required` (`.agents/scripts/terminal-blocker-circuit.sh:274`).

## How

- `EDIT: .agents/scripts/terminal-blocker-circuit.sh`: in `_terminal_blocker_capture_json`, parse the input owner once. When the reason is `permission_required` and the report has exactly one valid owner and one bounded question line, emit `input_required:<owner>`. The question then goes through the existing `_terminal_blocker_public_line` sanitizer and the canonical release envelope. A bare `permission_required` with no ask keeps its class. No envelope or validator change, so older runners accept the release.
- `EDIT: .agents/scripts/headless-runtime-contract.sh`: in the `permission_required` paragraph, require the owner and question lines when a named person can grant or approve the blocker by answering in the issue.
- `EDIT: .agents/scripts/pulse-dispatch-worker-prompt.sh`: in rule 8, extend the question requirement to `permission_required` exits that a named person can answer.
- `EDIT: .agents/reference/worker-diagnostics.md`: one line documenting the reclassification.

### Files Scope

- .agents/scripts/terminal-blocker-circuit.sh
- .agents/scripts/headless-runtime-contract.sh
- .agents/scripts/pulse-dispatch-worker-prompt.sh
- .agents/reference/worker-diagnostics.md

## Acceptance Criteria

- [ ] A final report with `TERMINAL_BLOCKER_REASON=permission_required`, one valid `TERMINAL_BLOCKER_INPUT_OWNER` and one `TERMINAL_BLOCKER_QUESTION` captures as `input_required:<owner>` with the question.
- [ ] A bare `permission_required` report, or one with an invalid or duplicated owner or question, still captures as `permission_required` with no question.
- [ ] `input_required` capture behaviour is unchanged.
- [ ] Existing terminal-blocker and worker-output classification tests pass; ShellCheck is clean.

## Verification

- `bash .agents/scripts/tests/test-worker-output-classification.sh`
- `bash .agents/scripts/tests/test-terminal-blocker-circuit.sh` (or the matching terminal-blocker capture tests in `.agents/scripts/tests/`)
- `shellcheck .agents/scripts/terminal-blocker-circuit.sh .agents/scripts/headless-runtime-contract.sh .agents/scripts/pulse-dispatch-worker-prompt.sh`
- Ad hoc: run `_terminal_blocker_capture_json` on sample OpenCode JSONL outputs for each case.
