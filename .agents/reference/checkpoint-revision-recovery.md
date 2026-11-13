<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Corrected blocked checkpoint recovery

An authorised brief owner may approve continuation of a released worker draft after correcting its brief.
This never permits taking over a live interactive session, clearing a sensitive-scope hold, or replacing the existing PR.

## Approval and continuation

When a draft blocks ordinary redispatch (`WORKER_DRAFT_CHECKPOINT`), Pulse runs
`pr-checkpoint-continuation-helper.sh blocked-attention OWNER/REPO ISSUE PR`. If the newest trusted release
is the PR author's `blocked` release with no later coordination event, it posts one `BLOCKED_CHECKPOINT_ATTENTION`
comment per head and release. The comment names the release ID, attempt and both exits: approve after correcting
the brief, or close the draft to restart dispatch (GH#33132). It grants nothing, starts no line with an event prefix
and never dispatches.

### Unknown-blocker triage (GH#36525)

Before publishing an unclassified blocked release, the runner performs one bounded (45-second, simple-tier)
inference over the protected final report and logs its sanitized outcome. Tool output and public PR prose are not
evidence. Explicit classes win; inferred external triggers require a named event, owner or date quoted from the report.
Known dependencies, access, input, scope and runner prerequisites use the normal class/owner path, never this feature's automatic approval.

Continue in-scope work where possible. If execution must stop with a pushed draft and only in-scope work remaining,
report it without `BLOCKED:` for the runtime's `worker_draft_checkpoint` continuation path; remaining work alone is
not a blocker. Only a complete report positively establishing unfinished authorised work without a prerequisite emits
`CHECKPOINT_UNKNOWN_TRIAGE pending_work brief=... head=...`. Missing tooling, timeout, invalid JSON, conflicting
declarations, truncation or uncertainty retain the unknown hold; draft prose is not evidence.

Automatic approval is **off by default**. An operator with current repository
write/maintain/admin permission can configure the registered `repos.json` entry:

```json
{
  "slug": "OWNER/REPO",
  "checkpoint_policy": {
    "auto_continue_unknown_pending_work": true,
    "configured_by": "WRITE_AUTHORISED_LOGIN"
  }
}
```

Both `configured_by`, the releasing runner and the publishing account must have
current write authority. The policy is local operator configuration, not an
issue/PR-body directive. `blocked-attention` checks the runner's head/brief binding,
fresh unassigned/unheld issue and eligible worker draft, then generates the line
through `approval-template` and publishes it through `gh-write-helper.sh`. It
does not launch directly, remove labels or transfer ownership. `dispatch-approved`
still enforces the exact head/ref, complete brief SHA, 24-hour expiry, current
permissions, coordination history and fenced claim. An already-valid approval
owns scheduling; approval-looking text from an untrusted commenter does not.

Without the policy, eligible drafts go into one `UNKNOWN_CHECKPOINT_DIGEST` comment
per repository/UTC day. Native creation of the unassigned repository label
`checkpoint-digest:YYYY-MM-DD` reserves publication atomically across runners; it
never attaches a label or alters holds. Only the reservation's creator posts the
digest; the label description identifies the anchor issue. Reservations are kept
as an audit trail, including when an ambiguous failed publication cannot safely
be retried that day.

The winner collects a bounded snapshot (100 blocked auto-dispatch issues, 100
worker drafts, 40-second enrichment budget). Each entry holds a fresh validated
`approval-template` command, not an approval. Snapshots are immutable, so
simultaneous writers cannot lose entries. Candidates arriving later, beyond the
bounds, or unreadable are reconsidered in the next UTC day's snapshot. No
protected report text is posted. The digest stays informational if the head/brief
changes; running a command revalidates it.

Pulse check reports the unknown triage backlog, oldest release age in minutes, and unreadable/unscanned count. Age is
measured from the trusted release, never from `updatedAt`, attention comments or lease renewals. These bounded
observations of unassigned blocked auto-dispatch issues are not a fleet inventory or authority to clear holds.

### Non-blocked releases with an open draft (GH#33850, GH#36019)

An open worker draft is preserved work, and an exit classification is not
evidence that it is complete or that its work landed elsewhere. When the newest
trusted coordination event is a release (the released attempt's own closing
terminal lease is ignored, GH#33839), Pulse routes the draft by release reason:

- **Continuation-eligible** (`dispatch-stalled`): stall/timeout, `stale_assignment_reset`,
  `worker_ownership_lost`, the worker's own `worker_draft_checkpoint` handoff,
  `worker_noop_zero_output`, `worker_incomplete_exit`, `clean` and `worker_complete`.
  Zero-output and incomplete exits with an unchanged head are runtime stalls, not worker
  decisions (GH#36597). Pulse launches one exact-head continuation per head. It finishes
  the missing in-scope work and marks the draft ready, or records a concrete blocker with
  `mark-blocked`; already-landed work is `decision already_landed`. It never closes the
  draft. If it also releases at the same head, Pulse posts one
  `STALLED_CHECKPOINT_ATTENTION`. That record is a pause, not a permanent stop: once it is
  older than `AIDEVOPS_PCC_ATTENTION_REARM_SECONDS` (default 43200 = 12h; `0` disables),
  a runner with no claim, lease, launch or release after the head commit logs
  `STALLED_CHECKPOINT_REARMED` and makes one exact-head continuation. Once every runner
  has tried the head, a fleet re-arm (GH#37514, `mode=fleet window=<seconds>s`) grants one
  continuation per window, anchored on the newer of the attention record and the latest
  stall release, doubled per further stall of the head (at most 2^6); the winner's fenced
  claim stops other runners in that window. A new head re-arms one continuation until a
  per-PR fuse (`AIDEVOPS_PCC_MAX_PR_RELEASES`, default 6 eligible releases since PR
  creation) posts one attention record per PR instead; later heads and aged records never
  re-arm continuation or repeat that record (see the terminal action below). To resume sooner
  or after the fuse, a maintainer publishes the line printed by the record's `approval-template` command.
  Stall-class releases and a continuation's `clean`/`worker_complete` exit are approvable;
  the released attempt is the single ready lease before the release, so Pulse may release
  another runner's stale attempt. `worker_draft_checkpoint`, `capability_limit` and
  push/network policy timeouts are not approvable.
- **Runner capability** (`blocked` with `runner_capability_unmet`, GH#34758): a capable runner continues the head.
- **Every other reason except `blocked`** (for example `capability_limit`): `blocked-attention`
  posts one `BLOCKED_CHECKPOINT_ATTENTION` per PR head. It grants no approval, launches no
  worker and changes no assignment. Releases from another trusted runner are accepted when
  the release runner matches its poster.

A head carries at most one attention record: an existing blocked-checkpoint record for the
head also deduplicates the stall record. The release projection leaves an open draft's issue
`status:available`, so the continuation target fence accepts it, except for the
terminal-blocker classes (`blocked`, `push_policy_timeout`, `network_policy_timeout`), which
project `status:blocked` unless the blocker is `runner_capability_unmet`. Existing
`status:blocked`, brief holds and protected labels are preserved, and
`WORKER_DRAFT_CHECKPOINT` keeps blocking ordinary redispatch.

While a trusted `CHECKPOINT_CONTINUATION_APPROVED` record is younger than its 24-hour
expiry, the revision-approval route owns scheduling, even for an older head; neither a push
nor an aged attention record reopens the legacy route. If revision target validation fails,
retry unavailable metadata/permission checks first, or publish a fresh `approval-template`
approval as a new issue comment (below); an exact-head approval still needs full revision
validation and a fenced claim. An expired approval with no newer one stops owning scheduling
(GH#37779): it can never launch and `worker_draft_checkpoint` releases cannot be re-approved,
so the re-arm windows and fuse apply again. A paused head that does not re-arm logs
`STALLED_CHECKPOINT_REARM_BLOCKED` and signals `stale_draft_checkpoint: rearm_blocked=<reason>`
(`per_pr_fuse`, `rearm_disabled`, `rearm_window_pending`, `fleet_window_pending:<window>s`).

**Bounded terminal action (GH#37779).** A draft held by the fuse, or whose exact-head target is
confirmed ineligible after its attention record, would otherwise hold redispatch forever. After
`AIDEVOPS_PCC_TERMINAL_ACTION_SECONDS` (default 43200; `0` disables) from the newer of that record
and the stall release, `dispatch-stalled` acts once per PR head: an additive, `MERGEABLE`,
all-checks-green, non-closing `For #N` draft is marked ready so the guarded Pulse merge pass lands
it as a partial checkpoint (the issue stays open); any other draft is closed with its branch kept
and a salvage pointer on the issue. Fresh-evidence gates (labels, assignment, ownership, dedupe
marker) are listed in the `pr-checkpoint-terminal-action.sh` header; pending or unreadable state
defers. Terminal writes compete in continuation's distributed claim consensus, revalidate ownership under the winning lease, and remove the claim on exit.
Closing first persists the branch/head salvage pointer on the issue; a failed pointer post leaves the draft open for retry. A failed final audit post reports `STALLED_CHECKPOINT_TERMINAL_RECORD_FAILED`, not success; the pointer is already durable.
Signals: `terminal_action=<ready_for_merge|closed>`, `terminal_deferred=<reason>`.
`dispatch` re-verifies a `STALE_PR_CONTINUATION` whose issue was already released unassigned
through `dispatch-stalled`.

### Drafts blocked by pre-v3.39.89 release projections (GH#36028)

Runners before v3.39.89 projected `status:blocked` after a continuable release, which the dispatch
candidate filter skips, so those drafts were never continued. On the stale-blocked cadence (own
stamp `draft-checkpoint-unblock-complete`), `pulse-draft-checkpoint-unblock.sh` restores
`status:available` only when all of these hold; any unreadable or ambiguous read leaves the issue unchanged:

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

This is evidence of an old release projection, not authority to clear a deliberate hold. One audit
comment names the PR, head and release; the Pulse log records one `draft-checkpoint-unblock:` line
per decision. Dispatch then routes the draft through `dispatch-stalled` as above, never closing it.
Listings are fully paginated and evidence is piped to jq, so busy issues (timelines over Linux's
128 KiB argument limit) are still evaluated.

### Approving a corrected released checkpoint

1. Read fresh issue/PR metadata and coordination comments. Verify the exact
   attempt has released as `blocked`, `clean` or `worker_complete`, no successor
   owns the objective, and the proposed scope correction preserves the authorised
   outcome. A blocked release must belong to the PR author; a clean/completed
   release may belong to another trusted runner only when its poster and unique
   prior ready lease authenticate that same runner and attempt. Check overlapping
   work. Revise the issue body first, using the managed wrapper.
2. Generate the exact approval line using that ready lease's attempt ID and the
   supported release comment's numeric ID:

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

The approval binds repository, issue, PR, exact head/ref, the original PR author (`runner`),
released attempt, release comment and SHA-256 of the complete corrected issue body. It expires
after 24 hours; changed body/head/actor permissions invalidate it. A legacy release without a lease
token is accepted only when its approved attempt has a unique prior authenticated ready lease with
no intervening attempt. Raw launcher attempt IDs and their `attempt:`-prefixed form identify the
same attempt; no other identity normalization is permitted, and approval records retain the
prefixed form. Before claim transfer, the issue must be unassigned or assigned to the authenticated
releasing runner, not an unrelated owner; the exact PR-author binding stays when they differ.

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
compensation as well as takeover. A consumed unchanged approval is not retried;
reassess and issue a fresh bounded approval when authorised. Never forge
`worker_draft_checkpoint` releases or remove the generic assignment guard. A
dispatch message proves launch initiation, not model startup or delivery.

## Aged objectives

Pulse check tracks creation age separately from time since linked PR creation, commits or completed checks. Comments,
lease renewals, labels and `updatedAt` do not refresh durable progress. Bounded/failed evidence reads remain unknown;
persistent dashboards and explicit authority/dependency waits are excluded.

After one hour, the owning AI assesses one recovery action against fresh target evidence: preserve live owners,
continue the exact approved checkpoint, or send one evidence-backed scope-revision request to its authorised brief
owner. Retain the action in existing recovery state; do not repeat age comments or redispatch an unchanged brief.
The broader delegated scope-decision and AI-owned handoff contract is tracked in #31305; this mechanism does not grant
workers permission to approve their own authority expansion.
