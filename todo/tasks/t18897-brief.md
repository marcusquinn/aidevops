<!-- aidevops:brief-schema=v2 -->
# t18897: Session bus ask with bounded wait, so subagents and scripts get the reply in the same call

## Origin

- **Created:** 2026-11-08
- **Session:** opencode:interactive ses_e480fcfa0ffeCzemlBnZ5j1VBA (t18886 session bus, GH#37149, PR #37165, released in v3.39.136)
- **Created by:** ai-interactive
- **Conversation context:** The owner asked whether subagents can message back and forth. In the released bus a subagent's `aidevops_sessions` call acts for its root session (`session-bus-identity.mjs:4-6,62-69`; `session-bus.mjs:242-247`). Only root sessions publish presence and receive delivery (`session-bus.mjs:189-190`; `session-bus-delivery.mjs:160-163`). A subagent can therefore send and ask as its root, but the reply lands in the root's inbox and never reaches the subagent that asked. Making subagents addressable would need presence for short-lived child sessions that cannot be woken mid-run, and the parent–child Task prompt and result already connect a parent and its child. The useful gap is a round trip inside one tool call.

## What

1. **`ask` with `wait_seconds`** (tool) and `--wait <seconds>` (CLI), from 1 to 120. After sending the ask, the call waits for a reply whose `re` is that ask's ID and returns the reply, framed as usual, in its own result. On timeout it returns the ask ID and says the reply will follow normal delivery. Cancelling the tool call (the abort signal) stops the wait.
2. **Reply reservation:** while a wait is active, the root session's busy and idle delivery skips that one reply, so the waiting call claims it. After the wait ends, the reservation is released and normal delivery resumes.
3. **Subagent attribution:** when the caller is a subagent, the message's `from` gains an advisory `via: { session_id, agent }`, and the recipient's framing reads `from <root-handle> (via subagent <agent>)`. The sender identity is still the root session.
4. **Docs:** `reference/session-bus.md` explains what subagents can and cannot do, and when to use `wait_seconds`.

## Why

A worker subagent that needs one fact from another live session (for example "is PR 123 releasing?" or "which branch holds this fix?") can ask today, but it never sees the answer. The root receives the reply later, after the subagent has finished. A bounded wait closes that loop at almost no cost: no new storage, no child presence, and the existing at-most-once claim.

## Tier

**Selected tier:** `tier:standard`

**Tier rationale:** This is a contained change to the tool, CLI and delivery claim path, with one in-memory reservation set. Message formats change only by an advisory field.

## How (Approach)

- **Tool:** `sendAction` (`.agents/plugins/opencode-aidevops/session-bus-tool.mjs:69-84`) returns after `store.sendMessage`. For `ask` with `wait_seconds`, register the ask ID in a new `bus.awaitingReplies` map, then poll `store.pendingMessages(root, sender.sessionID)` every second for `type === "reply" && re === askId`. Claim it with `store.claimMessage` (rename, the existing at-most-once path), stop on timeout or `context.abort`, and always remove the reservation in `finally`. Add `wait_seconds: z.number().int().min(1).max(120).optional()` to the args (`:136-141`).
- **Reservation:** `claimPending` (`session-bus.mjs:199-202`) and the idle delivery in `session-bus-delivery.mjs` must skip entries whose `message.re` is in `bus.awaitingReplies`. The child and its root run in one OpenCode process, so an in-memory map is enough.
- **Attribution:** `bus.sender(context)` (`session-bus.mjs:242-247`) knows both `context.sessionID` and the resolved root. When they differ, add `via` to `from`. Render it in `senderLabel`/`frameMessage` (`session-bus-format.mjs:70-88`).
- **CLI:** `sendCommand` (`session-bus-cli-commands.mjs:81`) for `ask --wait N`. A shell sender has no inbox, so the reply goes to `outbox/cli` (`session-bus-messages.mjs:118-135`). Poll `store.readOutbox(root, "cli")` for `re === askId`, print it, then `ackOutbox` it. Exit 0 with the reply, or 2 on timeout, printing the ask ID.
- **Limits:** at most 2 concurrent waits per root session; extra waits are refused with a clear error. Waits send nothing extra and use no wake budget.

### Files to Modify

- EDIT: `.agents/plugins/opencode-aidevops/session-bus-tool.mjs`: `wait_seconds`, wait loop and abort handling.
- EDIT: `.agents/plugins/opencode-aidevops/session-bus.mjs`: `awaitingReplies`, skip reserved replies in `claimPending`, and `via` in `sender`/`fromFor`.
- EDIT: `.agents/plugins/opencode-aidevops/session-bus-delivery.mjs`: skip reserved replies in idle delivery.
- EDIT: `.agents/plugins/opencode-aidevops/session-bus-format.mjs`: `via` framing.
- EDIT: `.agents/plugins/opencode-aidevops/session-bus-cli-commands.mjs` and `session-bus-cli.mjs`: `--wait`.
- EDIT: `.agents/plugins/opencode-aidevops/tests/test-session-bus.mjs`: wait success, timeout, abort, reservation skip and `via` framing.
- EDIT: `.agents/reference/session-bus.md`: subagent behaviour and waits.

### Complete Write Surface

- **Callers/readers:** the `aidevops_sessions` tool (root and subagent sessions), `aidevops sessions ask`, the V1/V2 sidebars and compaction, which read `from` and must tolerate `via`.
- **Writers/mutation paths:** `sendMessage` (`session-bus-messages.mjs:104`) gains the optional `via`; the wait claims through `claimMessage`; the CLI wait acknowledges through `ackOutbox`.
- **Existing verification/tests:** `npm test --prefix .agents/plugins/opencode-aidevops`.
- **Schemas/config:** message record `v: 1` with optional `from.via`; no new files or directories.
- **Generated/deployed mirrors:** not applicable because no new module is added; existing plugin files deploy through `setup.sh` as today.
- **Migrations/backfills:** not applicable because `via` is additive and old messages have none.
- **Cleanup/rollback paths:** reservations live only in memory and are cleared in `finally`; rollback is a code revert.

### Implementation Steps

1. Add `awaitingReplies` and the reservation skip in `claimPending` and idle delivery, with unit tests.
2. Add `wait_seconds` to the tool with the poll, claim, timeout and abort logic, and the concurrency limit.
3. Add `via` attribution and framing.
4. Add `--wait` to the CLI using the `cli` outbox.
5. Run the unit tests and the live self-test, and record the output in the PR.

### Hazards and Compatibility

- **Concurrency/atomicity:** claim by rename stays the only delivery path, so the waiter and normal delivery can never both deliver the reply; the reservation only prevents the root from winning the race while a wait is active.
- **Migration/rollback:** no stored data changes beyond an optional field; rollback is a code revert.
- **Mixed-version/backward compatibility:** a recipient on an older plugin ignores `via` and replies normally; the reply still matches by `re`.
- **Idempotency/retry:** a retried wait on the same ask ID after a timeout can still collect a reply that has not been delivered yet.
- **Partial failure/recovery:** if the process exits during a wait, the reservation disappears with it and the reply is delivered to the root at its next turn as today.
- **Context cost:** the waiting tool call returns one framed reply (at most 2000 chars), the same size as normal delivery.

### Files Scope

- `.agents/plugins/opencode-aidevops/session-bus-tool.mjs`
- `.agents/plugins/opencode-aidevops/session-bus.mjs`
- `.agents/plugins/opencode-aidevops/session-bus-delivery.mjs`
- `.agents/plugins/opencode-aidevops/session-bus-format.mjs`
- `.agents/plugins/opencode-aidevops/session-bus-cli-commands.mjs`
- `.agents/plugins/opencode-aidevops/session-bus-cli.mjs`
- `.agents/plugins/opencode-aidevops/tests/test-session-bus.mjs`
- `.agents/reference/session-bus.md`

### Verification Before Dispatch

```bash
npm test --prefix .agents/plugins/opencode-aidevops
node --check .agents/plugins/opencode-aidevops/session-bus-tool.mjs
```

- **Runtime evidence (self-test, no owner needed):** with `AIDEVOPS_SESSION_BUS_DIR` set to a scratch directory and two `opencode serve` sessions A and B (t18886 "Live verification" setup), with B idle, check:
  - `aidevops sessions ask <B> "reply with the word pong" --wait 90` prints B's reply and exits 0, and `outbox cli` is empty afterwards.
  - In A, a subagent prompted to call `aidevops_sessions` `ask` to B with `wait_seconds: 90` gets B's reply in its own tool result.
  - B's framing shows "via subagent".
  - A `--wait 1` against a busy session exits 2 with the ask ID.
- **Surface mapping:** unit tests cover the reservation, wait, timeout, abort and framing. The live run covers the real wake, reply and the subagent tool path.
- **Broad verification trigger:** not required. The changes stay inside the plugin and its reference doc.

### Recoverability Checkpoint

- [ ] Focused functional verification passes: `npm test --prefix .agents/plugins/opencode-aidevops`
- [ ] WIP commit created before broad gates: `wip: t18897 ask wait for subagents`
- [ ] Evidence-triggered broad verification then run: not required

### Scope Boundaries

**Hard boundaries:** subagents stay out of presence and are never message targets; no change to wake limits, hop rules or sender identity; no change to agent tool permissions (which agent types may call `aidevops_sessions` stays as configured); chat-origin trust is t18891.

**AI brief owner:** the interactive owner session of t18886 (marcusquinn).

**Recovery:** preserve the current PR and use the structured runtime request and Pulse intake in `reference/worker-discipline.md` when local recovery is unsafe.

## Acceptance Criteria

- [ ] `aidevops_sessions` `ask` with `wait_seconds` returns the matching reply in the same tool result when it arrives in time, and the reply is not delivered a second time to the root session.
- [ ] On timeout the call returns the ask ID and the reply later reaches the root session through normal delivery.
- [ ] Aborting the tool call ends the wait and releases the reservation.
- [ ] A subagent's message is framed for the recipient as from its root handle with `(via subagent <agent>)` appended.
- [ ] `aidevops sessions ask --wait N` prints the reply and acknowledges it in `outbox/cli` (exit 0), or exits 2 on timeout.
- [ ] Regression: asks without a wait, replies, and busy and idle delivery behave as before; the session-bus tests pass.
- [ ] Negative: a third concurrent wait in one root session is refused, and a reply whose `re` does not match the awaited ask is left for normal delivery.

## Relevant Files

- `.agents/plugins/opencode-aidevops/session-bus-tool.mjs:69-84,86-95,132-149`
- `.agents/plugins/opencode-aidevops/session-bus.mjs:189-202,230-248`
- `.agents/plugins/opencode-aidevops/session-bus-identity.mjs:4-6,62-69`
- `.agents/plugins/opencode-aidevops/session-bus-delivery.mjs:150-164`
- `.agents/plugins/opencode-aidevops/session-bus-messages.mjs:104-135`
- `.agents/plugins/opencode-aidevops/session-bus-format.mjs:70-88`
