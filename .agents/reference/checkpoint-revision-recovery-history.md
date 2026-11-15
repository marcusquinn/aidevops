<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Checkpoint recovery: diagnostics and history edge cases

Split from `checkpoint-revision-recovery.md` (parent index). Covers read-only diagnostics, released-successor history rules and lease reconciliation for corrected blocked checkpoint recovery.

### Read-only diagnostics requiring newer tooling

Preserve the draft when observations require newer immutable tooling. Issue prose cannot
grant auxiliary-worktree access; the brief owner must opt into a diagnostic-only contract:

```bash
pr-checkpoint-continuation-helper.sh approval-template OWNER/REPO PR ISSUE RELEASE_COMMENT_ID attempt:ORIGINAL_ID --diagnostic-tooling-commit=FULL_COMMIT_ID
```

The trusted, unedited approval's `diagnostic_tooling_commit` accepts only a full lowercase
40- or 64-character commit ID; ordinary approvals remain checkpoint-only. Pulse and
`dispatch-approved` carry it through fresh revision validation. Before claim/launch the
dispatcher requires that exact local commit object in the target repository; missing
source stops without fetching/substitution. All brief, head, permission, ownership and
history fences remain. No hosted access, authentication or terminal-lease repair is granted.

The contract admits exactly one fresh, separately owned linked tooling worktree in the same
repository through the supported helper with that immutable base; never take over or reuse
another session's checkout. Verify linked-repository identity, clean tracked source, exact
HEAD and worker session/task ownership before execution and again immediately before any
authorized credential-bearing invocation. Capacity, provisioning, ownership and source refusals stop.

Run only the separately authorized read-only observation: no source edits, commit/push/ready/merge
or business writes. Keep the brief's locks, authentication budget, evidence privacy and cleanup
requirements. Report sanitized results and unknowns, then `mark-blocked` for remaining acceptance
or safety blockers; diagnostic success is not enrichment completion. This prompt replaces generic
full-loop augmentation, not runtime security/ownership/lease enforcement. Runner release/teardown
owns coordination; this option starts no browser or historical repair.

### Intervening attempts that have fully released

Later attempts do not silently invalidate a preserved checkpoint forever, but their release
messages alone never authorize continuation. When the entire intervening history is sequential and
fully closed, `approval-template` includes an explicit `released_successors` list in the new
approval. Each entry binds the runner, attempt and claim/ready/release/terminal comment IDs. The
source comments must remain trusted and unedited, with matching token/session/attempt identity; the
new continuation must acquire a fresh token through the existing fenced claim path. Tokens are not
copied into the approval.

Publish a new generated approval rather than editing an old one. Approvals
without the historical list do not authorize skipping intervening attempts.
Open or overlapping attempts, an unmatched release or terminal lease (except an
explicitly acknowledged release with no open episode, below), interactive
ownership, edited evidence and new unrelated coordination after approval still
reject continuation. A fully released attempt after approval requires a fresh
assessment and approval; expiry alone is never closure evidence. The template
refuses incomplete histories instead of printing an unusable line: its `intervening coordination
is not fully released; no approval generated` error appends one sanitized `rejected comment=...
event=... runner=... episode_claim=... reason=...` diagnostic. `comment` is the first rejected
coordination record (for `open_at_end`, the last scanned event); `event` is the recognized event
name with spaces replaced by underscores; `runner` is the comment author's login (or `unknown`);
`episode_claim` is the open episode's claim (or `none`). Reasons are `edited`, `untrusted`,
`transition_rejected`, or `open_at_end`. No lease token, nonce, session, or comment body is
printed, and these diagnostics do not change history acceptance. All current assignment, hold,
permission, brief-revision and exact-head checks remain in force.

Hidden-but-unedited coordination is valid evidence (GH#36529). Dispatch comment hygiene minimizes a
runner's old `DISPATCH_CLAIM`/`DISPATCH_LEASE` comments, which bumps REST `updated_at` without
changing the body. The helper therefore reads GraphQL `lastEditedAt` for each comment whose
`updated_at` differs from `created_at` and treats it as unedited only when that is `null`. A non-null
value, a missing node or an unreadable GraphQL response keeps the comment edited (fail closed), so
an edited body never counts as recovery evidence.

A stale-assignment release after prelaunch is not a completed history when the
ready/terminal evidence is absent. Do not synthesize missing events, reinterpret
that release as `claim_only_no_worker`, or change published records to recover it.
The exact claim-only closure below has its own guards and refuses an existing
release; unsupported histories remain blocked pending supported reconciliation.

### Expired claims that never reached ready (GH#35331)

An approval-bound `claim-pr-checkpoint` can expire before the executor renews its prelaunch lease
(`transition prelaunch` reports `lease_unmatched`); renew before the output's `prelaunch_expires_at`.
If it still expires, the owner's pulse revisits open worker drafts in bounded,
rotating batches and releases its own expired revision claims on the same device.
It rechecks the exact session and live timeline and skips a running executor.
For an issue outside that sweep, the claim owner may still run
`dispatch-claim-helper.sh abort-pr-checkpoint-claim ISSUE OWNER/REPO LEASE SESSION`. Both refuse a
live or ready lease, a worker launch, an existing release, edited or other-actor events and
mismatched identity, then posts `CLAIM_RELEASED reason=claim_only_no_worker claim_id=… nonce=…`.
That grants nothing: the consumed approval stays rejected; recovery needs a new approval whose
`released_successors` entry (`outcome: claim_only_no_worker`) binds the claim and release IDs.
History accepts it only when every claim and renewal expiry is known and elapsed before the
release; later renewal or token reuse rejects it.

One older same-runner `worker_ownership_lost` diagnostic (`exit=1
session_count=0`, no claim, nonce, lease, session or attempt identity) may
precede the abort. It neither closes the claim nor proves inactivity; its ID is
kept in `unbound_release_ids`, which the new approval must acknowledge. Edited
or foreign diagnostics, identity-bearing releases, a second diagnostic, and
later ready/launch/renewal events still reject. No evidence is removed.

### Approved attempts whose runtime never launched (GH#37669)

A `worker_not_launched` release leaves the approved head unchanged, so the
approval stays reusable: the validator skips a sequential, unedited episode by
one trusted runner (claim naming this `checkpoint_approval`, own leases or launch
notice, own same-lease `worker_not_launched` release and terminal lease). Other
reasons and foreign, edited or interleaved events still fence. Past three such
episodes, the 24-hour window, or a head or brief change, a new approval is needed.

### Releases with no open episode (GH#36593)

A trusted, unedited `CLAIM_RELEASED` can follow fully closed attempts with no
claim of its own (for example a runtime release posted before releases were
fenced to owned claims). Its writer provenance is usually unrecoverable from
coordination records. By default `approval-template` refuses it and names the
comment IDs. After inspecting them, the maintainer accepts them explicitly:

```bash
pr-checkpoint-continuation-helper.sh approval-template REPO PR ISSUE RELEASE_ID attempt:ID --acknowledge-unattributed=COMMENT_ID[,COMMENT_ID]
```

The list must match the orphan releases exactly; missing, extra or other IDs refuse. Each becomes a
`released_successors` entry with `outcome: unattributed_release` and `provenance: unrecovered`,
which the published approval must list exactly. The entry opens and closes no episode. It is not
evidence of a claim, lease, completion or absence of side effects, and any token it names stays
fenced from reuse. Releases inside an open episode, edited or untrusted comments, and malformed
reasons still reject. Automatic approval paths never pass the acknowledgement. Releases are no
longer published without an owned claim (`headless-runtime-release-claim.sh`).

### Terminal lease with a missing release

A historical checkpoint attempt may have a claim, ready lease and terminal lease
but no preceding `CLAIM_RELEASED`. It is **not** a fully released attempt. The
default history validator still rejects it; neither a terminal record, lease
expiry, an assignment reset nor absence of a process establishes takeover authority.

After separately verifying executor shutdown/fencing and current ownership, an
authorized maintainer may explicitly accept this exact audit gap when generating
a new revision-bound approval:

```bash
pr-checkpoint-continuation-helper.sh approval-template REPO PR ISSUE RELEASE_ID attempt:ID --acknowledge-terminal-without-release=TERMINAL_COMMENT_ID[,TERMINAL_COMMENT_ID]
```

This is a manual recovery decision, not an automatic retry or proof of safe
execution. The command requires trusted, unedited, sequential claim/ready/terminal
records with matching actor, device, session, token and attempt. Every recorded
claim/renewal expiry must be known, positive and elapsed before approval; the
terminal must have `expires_at=0`. Missing ready evidence, overlapping claims,
foreign/edited evidence and extra/mismatched acknowledgement IDs reject.

The generated `released_successors` entry has `outcome: terminal_without_release`,
`release_provenance: missing` and `execution_status: unrecovered`, plus the exact
claim, ready and terminal IDs and an `evidence_sha256` binding all episode records
(including intermediate renewals). Only the digest is emitted, not lease secrets.
It contains no synthetic `release_id`; no original comment is edited or created
by template generation. Revalidation reconstructs that exact entry at the approval
timestamp and fences its historical token from reuse.

This flag can be combined with `--acknowledge-unattributed` for separately reviewed
later orphan releases. It does **not** acknowledge later interactive claims or
other live/open ownership: those still reject and need their own supported
handoff. Automatic approval paths pass neither flag. Approval publication still
requires current write authority, exact head/ref/brief binding and 24-hour expiry;
continuation still requires the existing fresh fenced claim. Execution/write
effects remain unknown until separately reconciled; never replay consumed work.

### Ready leases that expired without a release (GH#36544)

A continuation attempt can post its ready lease and then exit without a
`CLAIM_RELEASED` or terminal lease. `approval-template` then reports
`reason=open_at_end` at that ready lease, and `transition terminal` refuses the
expired lease (`lease_unmatched`). The claim owner, on the same authenticated
account, device and session, closes it explicitly once the executor has stopped:

```bash
dispatch-claim-helper.sh close-expired-pr-checkpoint-lease ISSUE OWNER/REPO CLAIM_COMMENT_ID SESSION
```

The command takes the claim comment ID, so the operator never handles the lease
token. It refuses a live local process with that `--session-key`, a non-checkpoint
claim, another actor's or an edited event, mismatched token, device or session, a
claim with no ready lease (use `abort-pr-checkpoint-claim`), an existing release
or terminal lease, unknown or unelapsed expiry, and any later coordination event
from another attempt. It appends `CLAIM_RELEASED
reason=expired_ready_lease_reconciled claim_id=… attempt_id=…` and then the
attempt's `DISPATCH_LEASE phase=terminal … expires_at=0`. A rerun after an
interrupted terminal post appends only the missing terminal lease.

History then records an ordinary closed episode (claim, ready, release,
terminal). The closure grants nothing: a new generated approval must list it in
`released_successors`. A lost device cannot use this path; that history stays
blocked pending a reviewed decision.

### Released ready attempts with a missing terminal lease

A ready attempt can post its own `CLAIM_RELEASED` and lose the terminal-lease
post. Its release alone does not close the historical episode: approval generation
still rejects it with `reason=open_at_end`. The default expired-ready closer and
automatic outbox drain deliberately continue rejecting ordinary releases.

After verifying that the executor has stopped, the claim owner may explicitly
complete this exact gap on the same authenticated account, device and session:

```bash
dispatch-claim-helper.sh close-expired-pr-checkpoint-lease ISSUE OWNER/REPO CLAIM_COMMENT_ID SESSION --complete-released
```

This mode requires one trusted, unedited, fully bound `blocked`, `clean` or
`worker_complete` release after the ready lease. The release must name the same
claim ID, nonce, token, device, session and runner; an explicit attempt ID must
match. All observed lease/launch attempts must match the ready attempt. Missing
identity, unknown or unelapsed expiry, another attempt, intervening renewal,
duplicate release, an existing terminal lease or a live local executor refuses.
Shutdown and the complete history are checked again immediately before posting.

Only a new current `DISPATCH_LEASE phase=terminal ... expires_at=0` is appended.
The original release is not duplicated, relabelled or edited, and no historical
record is fabricated. The operator supplies a claim comment ID, never a token.
An interrupted post can be retried after rereading the timeline; a terminal event
already present refuses without another write. This closes coordination only,
not execution effects: publication status remains unknown until reconciled.
Generate and publish a fresh revision-bound approval preserving the entire
closed episode before any continuation. Existing head/brief, permission, expiry
and fresh fenced-claim requirements remain unchanged.

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
