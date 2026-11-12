## Origin

- Created: 2026-11-10, interactive session (OpenCode, Build+), author: ai-interactive
- Trigger: maintainer asked why token burn rose over the last 24–48h; ledger analysis found bounded-operation polling as one avoidable driver.

## What

Let `aidevops_bounded_operation` return a terminal operation's stored output in the same tool result, so a short command costs one model turn instead of three (start → status → output).

1. `start` accepts optional `wait_seconds` (0–60). When set, the tool waits for a terminal state up to that deadline, looping over status transitions (`running` → `finalizing` → terminal).
2. Any `start` or `status` receipt that is terminal and has a stored output ID includes an `output` object with the first output window (`output_offset` default 1, `output_limit` default 120, max 500), the same fields as `action:"output"`.
3. Non-terminal receipts are unchanged. `action:"output"` stays for paging.

## Why

Request ledger (`~/.aidevops/.agent-workspace/observability/llm-requests.db`, `tool_calls`), 2026-11-06..10: `aidevops_bounded_operation` calls went from 2,000–2,600/day to 5,640 on 2026-11-09 (about 20%: 5,640 of 28,574 recorded tool calls that day). Session traces show a fixed start (~2 s) → status → output cycle per command, even for commands that finish in under 3 s. Each extra call is a full Opus turn at ~160k cached prompt (~$0.06 API-equivalent), so about 2 of every 3 bounded-operation turns are overhead (an estimated ~$200/day at the 2026-11-09 rate, not measured).

## How

- `.agents/plugins/opencode-aidevops/bounded-operation-access.mjs`: add `operationSettle(manager, id, context, { waitMs })` that loops `operationStatus` waits until the state leaves `ACTIVE_STATES` or the deadline passes (≤ 60 000 ms). Add `inlineOperationOutput(manager, receipt, id, context, { offset, limit })` that, for terminal receipts with an output ID, calls `operationOutput` and returns the window; read failures become `output_error` and never fail the receipt.
- `.agents/plugins/opencode-aidevops/bounded-operation-tool.mjs`: `start` with `wait_seconds > 0` settles after start; `start`/`status` attach inline output when terminal. Update the tool description.
- `.agents/reference/context-efficient-output.md`: document `start` + `wait_seconds` as the default for commands expected to finish within 60 s.

## Acceptance

- `start` with `wait_seconds: 30` on a sub-second command returns `state` terminal and `output.output` containing the command's stdout in one call.
- `status` on a terminal operation includes `output`; on a running operation it does not.
- Existing bounded-operation tests pass: `node .agents/plugins/opencode-aidevops/tests/test-bounded-interactive-operation.mjs`.
- Live check after deploy: ledger `tool_calls` shows fewer `aidevops_bounded_operation` calls per started operation.

## Context

- Ruled out: removing `action:"output"` (still needed for paging) and inlining into non-terminal receipts (output is only stored after finalisation).
- The total wait stays capped at 60 s, the same as the existing status wait, so the session stays responsive.

### Files Scope

- .agents/plugins/opencode-aidevops/bounded-operation-access.mjs
- .agents/plugins/opencode-aidevops/bounded-operation-tool.mjs
- .agents/plugins/opencode-aidevops/tests/test-bounded-interactive-operation.mjs
- .agents/reference/context-efficient-output.md
- TODO.md
- todo/tasks/t18953-brief.md
