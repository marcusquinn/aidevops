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

### Clean or completed release with an open draft (GH#33850)

The same `blocked-attention` entrypoint also handles a latest trusted
`CLAIM_RELEASED reason=clean` or `reason=worker_complete` when no newer owner
exists. These are runtime exit classifications, not evidence that the draft is
complete or that its work landed elsewhere: `worker_complete` includes a
fail-open PR-presence result. Releases from another trusted runner are accepted
when the release runner matches its poster. The released attempt's own closing
terminal lease is ignored using the shared ownership predicate (GH#33839);
unrelated terminal leases and successor claims still suppress the record.

Pulse posts one `BLOCKED_CHECKPOINT_ATTENTION` per PR head, even across later
clean/completed releases. It grants no approval, launches no worker, changes no
assignment, and never closes a draft based only on an exit reason. The brief owner
must inspect the exact head against the default branch and any replacement PR:
recover unique work through the guarded exact-head workflow, mark complete work
ready for normal review, or close already-landed work with a verified merged
replacement pointer. Automatic stall retries and blocked revision approvals are
unchanged. A new draft head re-arms attention.

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
