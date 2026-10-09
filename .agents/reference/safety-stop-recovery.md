<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Safety-Stop Recovery

A safety fuse protects resources, data, security, or service integrity. It stops
one unsafe execution path; it never cancels the objective that justified the
work.

## Invariant

After a safety stop, the original objective remains open until one of these
terminal conditions is evidenced:

1. the acceptance criteria are verified;
2. the user explicitly cancels or supersedes the objective; or
3. completion is demonstrated to be impossible under immutable constraints,
   the evidence is recorded, and the user is given the closest safe alternative.

None of these demonstrate impossibility: time limits, cost limits, worker
limits, rate limits, machine capacity, a killed process, or one failed
approach. Each requires a different route, smaller unit of work, different
resource, or later continuation.

## Required Response

When a fuse trips:

1. **Stop the unsafe path.** Do not repeat the identical command under unchanged
   conditions.
2. **Preserve value.** Commit and push safe work where possible. Record the
   original objective, user directions, completed work, evidence, trigger, and
   remaining acceptance criteria in the brief, mission, or issue.
3. **Keep the objective open.** Use `recovering` or `blocked`, not `done`,
   `completed`, `skipped`, or `cancelled`.
4. **Create the next safe action immediately.** Add it to the active todo list
   and to the durable task/mission record before yielding the session. If a
   human-only gate remains, name the owner, exact durable action, what it
   unblocks, and the verification that will prove recovery; otherwise identify
   the actual executor that owns the next action. A plan or expired command is
   not an executor.
5. **Change the conditions.** Select the first viable route in the recovery
   ladder below.
6. **Resume and verify.** A recovery checkpoint is not completion evidence.

## Durable Recovery Checkpoint

Record all fields; use `not yet known` rather than omitting one:

```markdown
### Safety-Stop Recovery

- **Original objective:** ...
- **Preserved user directions:** ...
- **Trigger and evidence:** ...
- **Completed and verified:** ...
- **Remaining acceptance criteria:** ...
- **Unsafe route not to repeat:** ...
- **Next safe route:** ...
- **Resume condition:** ...
- **Owner and status:** ... (`recovering` or `blocked`)
- **Handoff action and verification:** ... (required for a human-only gate)
```

Never place credentials, private paths, private repository identities, or raw
sensitive diagnostics in a public checkpoint. Store private details only in the
target-local private brief and publish aliases plus aggregate evidence.

Do not claim that work continues in the background unless a named, live executor
exists. When no executor exists, the durable record must instead say that the task
is blocked or resumable and give its next executable action.

For worker integration/scope blockers, use the final structured request and
Pulse-owned queue in `reference/worker-discipline.md` "Coordinator intake". It
preserves the exact checkpoint, one recovery budget per unchanged evidence, an
AI owner and a relevant wake condition. Neither a queue entry nor a coordinator
plan grants permission to revise explicit hard boundaries or security guarantees.

## Recovery Ladder

Choose the first route that can still satisfy the original acceptance criteria:

1. Narrow the input: one file, package, shard, fixture, or changed subset.
2. Lower concurrency and process fan-out; serialize independent phases.
3. Split discovery, generation, lint, typecheck, and tests into resumable stages
   with separate evidence.
4. Reuse a verified cache or precomputed immutable manifest when coverage stays
   equivalent.
5. Move the bounded job to an existing higher-capacity runner or CI environment;
   preserve the same stop and privacy contract.
6. Continue in a later session or worker from the pushed checkpoint. Carry the
   original objective and every remaining criterion forward verbatim.
7. If no safe route is currently available, keep the task blocked with a named
   resume condition and periodically re-evaluate it. Do not close it as skipped.

Increasing limits or retrying the same resource-intensive route is allowed only
after evidence shows the triggering condition changed and the new bound is safe.

## Security and Privacy Blockers

A security, privacy, permission, or data-residency gate is also a safety stop:
it denies one operation, not the conversation or the objective. Respond in the
same turn; silence or a generic refusal is a failure.

1. **Name the blocked operation** in plain language: what was denied, by which
   gate or restriction, and on what evidence. Separate known evidence from
   unknown cause; never attribute a block to a provider, safety filter, or
   policy decision without evidence. Do not recast an ordinary authorized
   request as suspicious or "unintended" activity.
2. **Continue permitted work.** Proceed with independent, already-authorized
   safe work, such as source-only repair, synthetic verification, or answering
   a status question. If nothing can proceed, give the exact owner action and
   resume condition in a few lines, not an essay.
3. **Never route around the gate.** Do not retry the denied action, reroute
   protected data to another model or provider, read raw transcripts, escalate
   model capability, mint or broaden permissions, resume a blocked write, or
   clear the blocker to make the session look responsive.
4. **Keep wait states distinct.** An explicit user cancellation or a pending
   approval is not a stall; never replay work automatically after either.
5. **Preserve restrictions.** Model, data-location, and side-effect restrictions
   survive compaction, reconnect, and resume. Record them under "Preserved user
   directions" and "Unsafe route not to repeat" in the checkpoint above.

When a turn produces no answer at all, a model cannot diagnose its own missing
response from prose. In interactive OpenCode sessions the plugin's
content-free turn diagnostics (`session-turn-diagnostics.mjs`) report whether a
silent turn was cancelled, failed at the provider, ended without visible text,
or is waiting on a permission or tool. They never abort, prompt, or retry.
Absent metadata stays `unknown`; it is not proof that a security filter acted.

## Mission and Worker Semantics

- A worker time budget stops that worker invocation, not the task. Before exit,
  push a checkpoint and leave a continuation action.
- A mission budget changes scheduling and resource choice. It does not erase a
  guaranteed feature or user direction.
- Optional work may be skipped because its evidence-based entry condition is
  false. It may not be skipped merely because a safety fuse fired while pursuing
  it.
- Missions cannot be marked completed while any recovery checkpoint has
  remaining acceptance criteria, unless a terminal condition from the invariant
  is recorded.

## Completion Review

Before declaring a task or mission complete, search its brief, progress log,
comments, and conversation for `safety stop`, `fuse`, `timeout`, `killed`,
`exit 124`, `exit 137`, `OOM`, and `recovering`. For every match, verify that the
objective completed or a valid terminal condition is documented.
