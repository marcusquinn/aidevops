<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Corrected blocked checkpoint recovery

An authorised brief owner may approve continuation of a released worker draft after correcting its brief. This never permits taking over a live interactive session, clearing a sensitive-scope hold, or replacing the existing PR.

## Approval and continuation

When a draft blocks ordinary redispatch (`WORKER_DRAFT_CHECKPOINT`), Pulse runs `pr-checkpoint-continuation-helper.sh blocked-attention OWNER/REPO ISSUE PR`. If the newest trusted release is the PR author's `blocked` release with no later coordination event, it posts one `BLOCKED_CHECKPOINT_ATTENTION` comment per head and release.
The comment names the release ID, attempt and both exits: approve after correcting the brief, or close the draft to restart dispatch (GH#33132). It grants nothing, starts no line with an event prefix and never dispatches.

### AI brief-owner decisions (GH#38155)

Enable decision and unknown-pending-work recovery together with `aidevops repos checkpoint-policy on OWNER/REPO` (omit the selector inside a registered repo, or use its path). Use `off` to disable both. `aidevops repos list` shows each policy separately; their stored keys remain independently readable.
The default is off, preserving attention-only behaviour. No issue body, model output or comment can enable the policy.

- **Eligibility:** after existing blocked-release checks, use the newest unedited current-head decision finding (excluding `already_landed`), or an explicitly decision-class blocked release bound to that head. Require an open, unassigned, auto-dispatchable issue without unknown-policy hold labels; validate the exact worker draft, release and attempt through `approval-template` before inference.
- **Authority:** policy owner, publisher, releasing runner, issue author and finding poster all need current repository write permission. Revalidate the policy and finding after inference; copied markers from outsiders never suppress resolution.
- **Decision:** one thinking-tier inference, bounded to 180 seconds, receives the brief, full finding, PR title, diff stat and bounded named-file excerpts as untrusted evidence. Only high-confidence `decide` can append a dated **Decision record (AI brief owner)**. Check the original brief before editing and verify the resulting body equals the original plus that section before generating approval bound to the new complete brief SHA. Reuse the unknown-policy signed publication/permission tail; all `dispatch-approved` gates remain.
- **Escalation:** an allowlisted escalation, malformed response, non-high confidence, timeout or missing inference prerequisite produces one `DECISION_ESCALATION` audit record with class, reason and options, never an approval or label change. Existing decision records and authenticated, unedited escalation records suppress repeat processing.
- **Bounds:** native atomic audit refs under `refs/aidevops/checkpoint-decisions/ISSUE/` reserve each PR/head/finding and at most two attempt slots per issue across runners. These are not branches, tags, labels or dispatch authority. Reservations persist after crashes or ambiguous publication failures; a consumed reservation proves neither a successful decision nor continuation authority.

### Re-armed blocked checkpoints (t19115)

A terminal-blocker re-arm answers the blocker that the checkpoint's release recorded. `blocked-attention` checks for one before it uses unknown triage and publishes the approval itself. This is on by default; set `"auto_continue_rearmed": false` under a repository's `checkpoint_policy` to keep attention-only behaviour.

- **Evidence:** the newest unedited `terminal-blocker-rearmed` receipt posted after the blocked release must carry `reason=trusted_retry` or `reason=revision_changed`. Permission-window and lifecycle re-arms never qualify. A `trusted_retry` also needs an unedited OWNER/MEMBER `terminal-blocker-circuit:retry` directive between the release and the receipt.
- **Authority:** the publisher, checkpoint runner and receipt poster need current write permission. So does the retry author or, for a revision, the issue author: only the author or a write collaborator can edit an issue body.
- **Gates:** the issue must be open, unassigned, auto-dispatchable and without holds. The worker draft must be eligible, and the `approval-template` line must bind the current head and complete brief SHA. `dispatch-approved` keeps every continuation gate.
- **Bounds:** a native ref `refs/aidevops/checkpoint-rearm/ISSUE/RECEIPT` makes publication at-most-once per receipt across runners. A failed publication after the reservation leaves the attention record. A continuation that blocks again creates a newer release, so only a newer re-arm can approve it again.
- **Runner's own draft hold (t19293):** a worker that needed input sometimes labels its own draft `hold-for-review`. Dispatch dedup then reports `WORKER_DRAFT_SELF_HELD:` for a linked same-repository worker draft whose only protection is that hold. It stays a plain duplicate-dispatch block, and the pulse runs `pr-checkpoint-continuation-helper.sh rearm-held REPO ISSUE PR` for the current blocked release. The re-arm route treats the receipt as the answer to that hold under the GH#36138 rule: every `hold-for-review` label event must be by the draft's runner and older than the receipt. A hold by anyone else, a hold reapplied after the receipt, `release-approval-required`, a PR-only completion contract, a feedback-route automation hold or unreadable label history still blocks. After publishing, the pulse retries `dispatch-approved` in the same cycle, and that path lifts the superseded hold.

### Unknown-blocker triage (GH#36525)

Before publishing an unclassified blocked release, the runner performs one bounded (45-second, simple-tier) inference over the protected final report and logs its sanitized outcome. Tool output and public PR prose are not evidence. Explicit classes win; inferred external triggers require a named event, owner or date quoted from the report.
Known dependencies, access, input, scope and runner prerequisites use the normal class/owner path, never this feature's automatic approval.

Continue in-scope work where possible. If execution must stop with a pushed draft and only in-scope work remaining, report it without `BLOCKED:` for the runtime's `worker_draft_checkpoint` continuation path; remaining work alone is not a blocker.
Only a complete report positively establishing unfinished authorised work without a prerequisite emits `CHECKPOINT_UNKNOWN_TRIAGE pending_work brief=... head=...`. Missing tooling, timeout, invalid JSON, conflicting declarations, truncation or uncertainty retain the unknown hold; draft prose is not evidence.

Automatic approval is **off by default**. An operator with current repository
write/maintain/admin permission can run `aidevops repos checkpoint-policy on OWNER/REPO`.
For all Pulse-enabled repositories owned by an account, use `aidevops repos checkpoint-policy on --owner OWNER`.
The command verifies current push permission for each enabled repo, records the current `gh` login as `configured_by`, and preserves unrelated registry and policy keys. Bulk output reports changed/skipped counts; a skipped repo returns a nonzero status. The registry remains mode 600. The stored shape is:

```json
{
  "slug": "OWNER/REPO",
  "checkpoint_policy": {
    "auto_resolve_decisions": true,
    "auto_continue_unknown_pending_work": true,
    "configured_by": "WRITE_AUTHORISED_LOGIN"
  }
}
```

`configured_by`, the releasing runner and the publishing account must have current write authority.
The policy is local operator configuration, not an issue/PR-body directive. `blocked-attention` checks the runner's head/brief binding,
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
  `worker_noop_zero_output`, `worker_incomplete_exit`, `worker_not_launched`, `clean` and
  `worker_complete`. Zero-output, incomplete and never-launched exits with an unchanged head
  are runtime stalls, not worker decisions (GH#36597, GH#38358); a never-launched episode of
  the PR's own session is transparent (GH#38103). Such failures count once per runner, so only
  a second failing runner pauses the head; a runner whose own launches failed twice since the
  release skips it for the re-arm window and a healthy runner continues it (GH#39913).
  Pulse launches one exact-head continuation per head. It first
  merges an advanced PR base locally, so guidance and decisions recorded on the base after the
  checkpoint forked apply (GH#39907). A conflict needing out-of-scope changes aborts that merge;
  the continuation then works from the checkpoint head and says so in the PR body. It finishes
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
  per-PR fuse (`AIDEVOPS_PCC_MAX_PR_RELEASES`, default 6 **non-progress** releases since PR
  creation) or hard total-release ceiling (`AIDEVOPS_PCC_MAX_PR_PROGRESS_RELEASES`, default 30)
  posts one attention record per PR instead; later heads and aged records never
  re-arm continuation or repeat that record (see the terminal action below). To resume sooner
  or after the fuse, a maintainer publishes the line printed by the record's `approval-template` command.
  Stall-class releases and a continuation's `clean`/`worker_complete` exit are approvable;
  the released attempt is the single ready lease before the release, so Pulse may release
  another runner's stale attempt. `worker_draft_checkpoint`, `capability_limit` and
  push/network policy timeouts are not approvable.
  Progress requires a non-merge PR commit authored and committed during the attempt; base merges alone do not qualify.
  Trusted, unedited claims/ready leases bound the attempt; renewals do not reset its start.
  REST PR commit metadata supplies parent counts absent from `gh pr view`; missing evidence counts as non-progress.
  Capability releases retain single-stall grouping. `STALLED_CHECKPOINT_REARM_BLOCKED` reports
  `progress_releases`, `nonprogress_releases` and `pr_releases`.
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

While the newest trusted `CHECKPOINT_CONTINUATION_APPROVED` record is unconsumed and younger than its 24-hour
expiry, the revision-approval route owns scheduling, even for an older head; neither a push
nor an aged attention record reopens the legacy route. If revision target validation fails,
retry unavailable metadata/permission checks first, or publish a fresh `approval-template`
approval as a new issue comment (below); an exact-head approval still needs full revision
validation and a fenced claim. An expired approval with no newer one stops owning scheduling
(GH#37779): it can never launch and `worker_draft_checkpoint` releases cannot be re-approved,
so the re-arm windows and fuse apply again. A trusted unedited approval-bound claim and its trusted unedited matching release also consume the approval; existing re-arm rules and fuses then apply. A paused head that does not re-arm logs
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

**Landable paused heads land at once (GH#38651).** Where `dispatch-stalled` would pause a head
(two stalls with no higher tier, or the fuse), a draft that is already landable (the land
criteria above) is marked ready immediately with cause `paused_landable`, without waiting for
re-arm, fuse or brief-owner windows, as an interactive full-loop would merge verified partial
work and continue from the default branch. The pre-check uses only the PR snapshot already read,
the terminal action re-reads every gate fresh, and this mode never closes: non-landable heads keep
the pause, re-arm, fuse and close rules above. `AIDEVOPS_PCC_LAND_PAUSED_CHECKPOINTS=0` restores waiting.

`dispatch` re-verifies a `STALE_PR_CONTINUATION` whose issue was already released unassigned
through `dispatch-stalled`.

### Prerequisite routing for code and tooling blockers (t19039)

A continuation worker that stops on a concrete, reproducible defect in the
repository's own code or tooling, outside the draft's scope, runs
`pr-review-thread-response-scanner.sh route-prerequisite <repo> <pr> <code|infrastructure> <reason> <details_file>`
before `mark-blocked`. Before t19039, such a finding waited for a person to
read it and file the fix, and same-head continuations kept rediscovering it.

- The scanner files one worker-ready `auto-dispatch,tier:standard,bug` issue
  in the same repository through `gh-write-helper.sh`. It deduplicates on the
  body marker `aidevops:checkpoint-prerequisite:<repo>#<issue>:<reason>` and
  reuses an open match.
- It labels the linked issue `blocked-by:#N`. The dispatch dependency gate
  runs before the dedup layers that host `dispatch-stalled`,
  `dispatch-approved` and `blocked-attention`, so the draft is not relaunched
  while the prerequisite is open. `pulse-dep-graph.sh` removes the label when
  it closes, and the re-arm windows above then apply.
- The `CONTINUATION_BLOCKER_FINDING` then names the prerequisite and states
  that the brief owner need not act.
- The command refuses ordinary review-thread workers, `decision` and
  `maintainer` blockers, capacity reasons, and upstream-ownership reasons.
  It also refuses when a matching prerequisite is already closed. A closed
  match means the fix did not clear the blocker, so the worker records the
  plain finding instead of opening a loop.
- Runner-local or transient blockers (quota, rate limit, a missing secret or
  login) keep the plain `mark-blocked` path.

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

### Diagnostics and history edge cases

Read-only diagnostics requiring newer tooling, intervening released attempts, expired claims (GH#35331), unlaunched approved attempts (GH#37669), releases with no open episode (GH#36593), terminal lease with a missing release, expired ready leases (GH#36544), released ready attempts with a missing terminal lease, blocked-before-ready claims (GH#35683), and stale resets/attempt rebinds (GH#36005) are detailed in `checkpoint-revision-recovery-history.md`. Approval generation, `approval-template` rejection diagnostics and all fences described above still apply.

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
