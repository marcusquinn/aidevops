<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Corrected blocked checkpoint recovery

An authorised brief owner may approve continuing a released worker draft after
correcting its brief. This is not permission to take over a live interactive
session, clear a sensitive-scope hold, or replace the existing PR.

## Approval and continuation

When the draft blocks ordinary redispatch (`WORKER_DRAFT_CHECKPOINT`), Pulse
runs `pr-checkpoint-continuation-helper.sh blocked-attention OWNER/REPO ISSUE PR`.
If the newest trusted release is the PR author's `blocked` release with no later
coordination event, it posts one `BLOCKED_CHECKPOINT_ATTENTION` comment per head
and release. That comment names the release ID, attempt and both exits: approve
after correcting the brief, or close the draft to restart dispatch (GH#33132).
It grants nothing, starts no line with an event prefix and never dispatches.

### Non-blocked releases with an open draft (GH#33850, GH#36019)

An open worker draft is preserved work, and an exit classification is not
evidence that it is complete or that its work landed elsewhere. When the newest
trusted coordination event is a release (the released attempt's own closing
terminal lease is ignored, GH#33839), Pulse routes the draft by release reason:

- **Continuation-eligible** (`dispatch-stalled`): stall/timeout,
  `stale_assignment_reset`, `worker_ownership_lost`, the worker's own
  `worker_draft_checkpoint` handoff, `clean` and `worker_complete`. Pulse
  launches one exact-head continuation per head. The continuation finishes the
  missing in-scope work and marks the draft ready, or it records a concrete
  blocker with `mark-blocked`; already-landed work is `decision already_landed`.
  It never closes the draft. If that continuation also releases at the same
  head, Pulse posts one `STALLED_CHECKPOINT_ATTENTION` instead. A new head
  re-arms one continuation, until a per-PR fuse
  (`AIDEVOPS_PCC_MAX_PR_RELEASES`, default 6 eligible releases since PR
  creation) posts one attention record per PR instead; later heads do not
  re-arm continuation or repeat that record.
- **Runner capability** (`blocked` with `runner_capability_unmet`): see GH#34758.
  A capable runner continues the head.
- **Every other reason except `blocked`** (for example `capability_limit`):
  `blocked-attention` posts one `BLOCKED_CHECKPOINT_ATTENTION` per PR head.
  It grants no approval, launches no worker and changes no assignment. Releases
  from another trusted runner are accepted when the release runner matches its
  poster.

A head carries at most one attention record: an existing blocked-checkpoint
record for the head also deduplicates the stall record. The release projection
leaves an open draft's issue `status:available`, so the continuation target
fence accepts it, except for the terminal-blocker classes (`blocked`,
`push_policy_timeout`, `network_policy_timeout`), which project
`status:blocked` unless the blocker is `runner_capability_unmet`. Existing
`status:blocked`, brief holds and protected labels are preserved, and
`WORKER_DRAFT_CHECKPOINT` keeps blocking ordinary redispatch.

### Drafts blocked by pre-v3.39.89 release projections (GH#36028)

Runners before v3.39.89 projected `status:blocked` after a continuable release,
which the dispatch candidate filter skips, so those drafts were never continued.
On the stale-blocked cadence (own stamp `draft-checkpoint-unblock-complete`),
`pulse-draft-checkpoint-unblock.sh` restores `status:available` only when all of
these hold; any unreadable or ambiguous read leaves the issue unchanged:

- The open issue's only status label is `status:blocked`, it has
  `auto-dispatch`, and it has no protective label (`hold-for-review`,
  `no-auto-dispatch`, `needs-maintainer-*`, `persistent`, `parent-task`).
- Exactly one open `origin:worker` draft closes it.
- The newest trusted `CLAIM_RELEASED` is unedited, posted by the runner it
  names, and its reason is continuable (`clean`, `worker_complete`,
  `worker_draft_checkpoint`, stall/timeout, `stale_assignment_reset`), not a
  terminal blocker or `worker_ownership_lost`. No claim, dispatch or
  non-terminal lease follows it; the attempt's own terminal lease is ignored.
- The newest `labeled status:blocked` event is that runner's, within
  `PULSE_DRAFT_UNBLOCK_WINDOW_BEFORE_SECONDS`/`_AFTER_SECONDS` (60/600) of the
  release; a later maintainer re-block wins.
- Assignees are only that runner (released with the transition).
- No `kind=draft-checkpoint-unblock` marker exists for that release, and fewer
  than `PULSE_DRAFT_UNBLOCK_MAX_PER_PR` (3) exist for the PR.

This is evidence of an old release projection, not authority to clear a
deliberate hold. The single audit comment names the PR, head and release, and
the Pulse log records one `draft-checkpoint-unblock:` line per decision.
Dispatch then routes the draft through `dispatch-stalled` as above; the draft is
never closed. Listings are fully paginated and evidence is piped to jq, so busy
issues (timelines over Linux's 128 KiB argument limit) are still evaluated.

### Approving a corrected blocked checkpoint

1. Read fresh issue/PR metadata and coordination comments. Verify the exact
   original worker attempt has released as `blocked`, no successor owns the
   objective, and the proposed scope correction preserves the authorised outcome.
   Check overlapping work. Revise the issue body first, using the managed wrapper.
2. Generate the exact approval line using the original ready lease's attempt ID
   and the blocked release comment's numeric ID:

   ```bash
   pr-checkpoint-continuation-helper.sh approval-template OWNER/REPO PR ISSUE RELEASE_COMMENT_ID attempt:ORIGINAL_ID
   ```

3. Publish that line as a new issue comment through `gh-write-helper.sh issue
   comment`, using the normal body-file discipline. The approving actor must
   currently have write, maintain or admin permission. Generating the template
   does not grant authority. Do not edit a published approval comment.
4. Pulse discovers it before generic draft/interactive dedup protection consumes
   the candidate. Explicit invocation uses:

   ```bash
   pr-checkpoint-continuation-helper.sh dispatch-approved OWNER/REPO REPO_PATH ISSUE AUTHENTICATED_RUNNER
   ```

The approval binds repository, issue, PR, exact head/ref, original runner and
attempt, release comment and SHA-256 of the complete corrected issue body. It
expires after 24 hours; changed body/head/actor permissions invalidate it. A
legacy release without a lease token is accepted only when its approved attempt
has a unique prior authenticated ready lease with no intervening attempt.

### Intervening attempts that have fully released

Later attempts do not silently invalidate a preserved checkpoint forever, but
their release messages alone never authorize continuation. When the entire
intervening history is sequential and fully closed, `approval-template` includes
an explicit `released_successors` list in the new approval. Each entry binds the
runner, attempt and claim/ready/release/terminal comment IDs. The source comments
must remain trusted and unedited, with matching token/session/attempt identity;
the new continuation must acquire a fresh token through the existing fenced
claim path. Tokens are not copied into the approval.

Publish a new generated approval rather than editing an old one. Approvals
without the historical list do not authorize skipping intervening attempts.
Open or overlapping attempts, an unmatched release or terminal lease, interactive
ownership, edited evidence and any new unrelated coordination after approval
still reject continuation. A fully released attempt that occurs after approval
requires a fresh assessment and approval; expiry alone is never closure evidence.
The template refuses incomplete histories instead of printing an unusable line.
All current assignment, hold, permission, brief-revision and exact-head checks
remain in force.

### Expired claims that never reached ready (GH#35331)

An approval-bound `claim-pr-checkpoint` can expire before the executor renews
its prelaunch lease (`transition prelaunch` then reports `lease_unmatched`). The
output's `prelaunch_expires_at` is the renewal deadline; an interactive executor
should renew right after the claim. If it still expires, the claim owner, on the
same authenticated account, device and session, closes it explicitly:

```bash
dispatch-claim-helper.sh abort-pr-checkpoint-claim ISSUE OWNER/REPO LEASE SESSION
```

The command refuses a live lease, a ready lease or worker launch, an existing
release, edited or other-actor events, and mismatched identity. It posts the
existing `CLAIM_RELEASED reason=claim_only_no_worker claim_id=… nonce=…` marker,
which already retires the claim generation. That release grants nothing: the
consumed approval stays rejected, and recovery needs a new generated approval
whose `released_successors` entry (`outcome: claim_only_no_worker`) binds the
claim and release comment IDs. History accepts that closure only when every
claim and renewal expiry is known and elapsed before the release comment, so the
automatic orphan release cannot close a live or unknown lease. Any later renewal
or reuse of the closed token rejects the history.

One older same-runner `worker_ownership_lost` diagnostic may precede the exact
abort when it reports `exit=1 session_count=0` and contains no claim, nonce,
lease, session or attempt identity. It does not close the claim or prove that
another executor is inactive. Historical reconstruction retains its comment ID
in `unbound_release_ids`, which the new approval must explicitly acknowledge.
The exact expired owner abort is still required; edited or foreign diagnostics,
identity-bearing releases, a second diagnostic, and ready/launch/renewal events
after the diagnostic remain rejecting cases. No published evidence is removed.

### Claims released as blocked before ready (GH#35683)

A later claim can end at prelaunch with the runner's own
`CLAIM_RELEASED reason=blocked` (for example a `permission_required` terminal
blocker) without a renewal, ready lease or launch. That release never closes the
checkpoint attempt, so approve the checkpoint's own blocked release and attempt.
History closes the never-ready claim as a `released_successors` entry with
`outcome: blocked_before_ready` binding the claim and release comment IDs. The
release must be trusted, unedited, posted after the claim by the claim's runner,
with no ready lease, launch, other release or other claim in between, and every
claim/renewal expiry known and elapsed before it. Any `nonce`, `lease_token`,
`claim_id`, `session` or `attempt_id` on the line must match that claim; a legacy
line without them binds only by runner and ordering. A release racing a live or
unknown expiry, an edit, a foreign actor or a later event still rejects history.

`blocked-attention` pairs a ready lease only with a release from the same claim
episode (after the newest `DISPATCH_CLAIM` before it). When the newest blocked
release closes a never-ready claim, the record names the earlier blocked
checkpoint release and attempt it follows; if none exists it offers no approval
template and says why, instead of a line `approval-template` would refuse.

### Claims reset as stale before ready, and ready-lease attempt rebinds (GH#36005)

The claim owner's own stale recovery can release a never-ready claim with
`CLAIM_RELEASED reason=stale_assignment_reset … device=…`. History closes it as
`outcome: stale_reset_before_ready` under every `blocked_before_ready` guard. The
line must also carry the claim's device, and the claim must record one.

Manual dispatch through a managed unit could not pass the dispatcher's attempt
ID to the worker, so the worker's ready lease names a fresh `attempt:` ID.
History accepts exactly one such rebind, at the first ready lease. It must come
before any `Dispatching worker` announcement or release, on the claim's lease
token, session and device. The episode is reported under the rebound attempt, and
every later lease, launch and release must match it. A second rebind, a rebind
after launch, a foreign device or a terminal lease naming the prelaunch attempt
still rejects history. `dispatch-single-issue-helper.sh` now allocates one attempt
per dispatch and passes it in the worker argv, so new manual dispatches do not
rotate.

## Ownership guarantees

The revised path acquires the existing distributed claim/consensus lease before
assignment restoration, including an unassigned preserved checkpoint. Its claim
session matches the exact-PR worker session. Worker startup renews prelaunch and
then transitions ready; the producer must not prematurely transition ready.
Worker preparation and pre-push verification re-read the full approval, owner,
lease, brief and head envelope. A `For #N.` partial checkpoint is accepted only
for the approved pair with no conflicting structural closing links.

Failed launches compensate assignment/status only while that same live envelope
still owns the target, then terminate the lease. Newer human/worker evidence stops
compensation as well as takeover. An unchanged consumed approval is not retried;
reassess the new evidence and issue a fresh bounded approval when authorised.
Never forge `worker_draft_checkpoint` releases or remove the generic assignment
guard. A dispatch message proves launch initiation, not model startup or delivery.

## Aged objectives

Pulse check tracks creation age separately from time since linked PR creation,
commits or completed checks. Comments, lease renewals, labels and `updatedAt` do
not refresh durable progress. Bounded/failed evidence reads remain unknown;
persistent dashboards and explicit authority/dependency waits are excluded.

After one hour, the owning AI assesses one recovery action against fresh target
evidence. Preserve live owners, continue the exact approved checkpoint, or send
one evidence-backed scope-revision request to its authorised brief owner. Retain
the action in existing recovery state; do not repeat age comments or redispatch
an unchanged brief. The broader delegated scope-decision and AI-owned handoff
contract is tracked in #31305; this mechanism does not itself grant workers
permission to approve their own authority expansion.
