<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Cross-Runner Coordination

> **Audience:** Maintainers operating multiple pulse runners across machines; engineers
> debugging race conditions in multi-operator environments.

<!-- AI-CONTEXT-START -->

**TL;DR:** Runners do not communicate directly. GitHub is the shared coordination layer.
Every dispatch decision must read GitHub state (assignees, labels, dispatch comments)
before posting a claim. Skipping any step breaks multi-runner safety.

<!-- AI-CONTEXT-END -->

## 1. The Runner Model

A **runner** is a machine (physical or virtual) running a `pulse-wrapper.sh` launchd/cron
job that dispatches headless worker sessions to solve GitHub issues.

**Key properties:**

- Runners are stateless relative to each other. No runner-to-runner RPC, no shared message
  bus. All coordination happens through GitHub issue state.
- GitHub is the **source of truth**. A runner that disagrees with GitHub state has no
  authority to override it.
- Any number of runners may be active simultaneously on the same repos. The dedup chain
  (§3) ensures at most one worker runs per issue at a time, regardless of runner count.
- Runners identify themselves by the `self_login` passed to `dispatch-dedup-helper.sh` —
  typically the GitHub login of the machine's authenticated user (e.g., `marcusquinn`,
  `alex-solovyev`).

**What runners do NOT know about each other:**

- Which issues another runner is currently evaluating (no lock before the claim window).
- Which version of aidevops another runner is on. Version skew is a real failure mode
  (see §4.4).
- Whether another runner's worker is alive or stalled. That determination uses the
  stale-assignment threshold (§2.6).

---

## 2. Coordination Signals

These are the GitHub state fields that runners read and write to coordinate. Each signal
has a canonical owner and a failure mode if it drifts out of sync.

### 2.1 Assignees

**What it signals:** A non-self assignee on an issue means another runner claimed it.

**Set by:** `pulse-dispatch-core.sh` immediately before launching a worker, via
`gh issue edit --add-assignee "$self_login"`. Removed on worker completion/failure.

**Read by:** `dispatch-dedup-helper.sh is-assigned` (Layer 6). The function combines
assignee + active status label to decide whether to block dispatch.

**Failure modes:**
- **Phantom assignee:** Worker died without releasing the assignment. Resolution:
  stale-recovery threshold kicks in after `STALE_ASSIGNMENT_THRESHOLD_SECONDS` (default
  configured in `shared-constants.sh`). The recovery unassigns, relabels `status:available`,
  and posts a `WORKER_SUPERSEDED` comment (t1955).
- **Owner/maintainer passive assignment:** A maintainer self-assigns for bookkeeping. This
  was a starvation source (GH#10521) — fixed by the combined signal rule: an owner/maintainer
  assignee only blocks dispatch when an active status label is also present (see §2.2).

### 2.2 Status Labels

**Active lifecycle labels** (any one of these means "a worker is live or claimed"):

| Label | Set by | Meaning |
|---|---|---|
| `status:claimed` | `claim-task-id.sh` | Interactive session claimed the task |
| `status:queued` | Pulse dispatcher | Worker about to launch |
| `status:in-progress` | Worker (self-report) | Worker actively running |
| `status:in-review` | Worker on PR open | Worker opened a PR, awaiting review |
| `status:available` | Stale recovery / completion | No active claim |

**Rule (t1996):** The dedup signal is `(active status label) AND (non-self assignee)` —
both required, neither sufficient alone. See `dispatch-dedup-helper.sh _has_active_claim()`.

### 2.3 Origin Labels

**`origin:interactive`** — set by `claim-task-id.sh` / `issue-sync-helper.sh` when
the claiming session is interactive (human present). Implications:

- The pulse treats any assignee on an `origin:interactive` issue as blocking, even if
  that assignee is the repo owner or maintainer. This closes the race where the user
  starts work in an interactive session and the pulse dispatches a duplicate worker
  before the user's PR is open (GH#18352, t1961).
- PRs with `origin:interactive` pass the maintainer gate automatically when the PR author
  is OWNER or MEMBER — the human was present and directing the work.
- The pulse's deterministic merge pass never auto-closes `origin:interactive` PRs
  (GH#18352, additional fix in t1970).

**`origin:worker`** — set by the pulse when it dispatches a headless worker. Used by
the maintainer gate and audit trail; not a dedup signal on its own.

### 2.4 Dispatch Comments

Runners post a plain-text `DISPATCH_CLAIM nonce=<UUID>` comment before launching a
worker (Layer 7). After posting, the runner sleeps `DISPATCH_CLAIM_WINDOW` seconds
(default 8s), then re-reads the comment list. If another runner's claim comment is older,
this runner yields. Oldest claim wins.

This is the **final cross-machine safety net** — two runners that simultaneously pass
Layers 1-6 both post claims, but only one proceeds.

**Persistent signal:** The `DISPATCH_CLAIM` comment survives beyond the claim window.
It allows Layer 5 (`has-dispatch-comment`) to block re-dispatch in future pulse cycles
if the issue stays open but the PR is not yet merged.

**Failure mode (GH#11086):** When the claim step was an LLM-instructed step in `pulse.md`
rather than a mandatory code path, runners could skip it. Two runners (marcusquinn and
johnwaldo) dispatched on the same issue 45 seconds apart. Fixed by encoding the claim
in `pulse-dispatch-core.sh` as a mandatory Layer 7.

### 2.5 Issue Locks

Not currently used by the dispatch flow for locking. The optimistic claim comment
(§2.4) serves as the cross-machine mutex. GitHub issue locking is used for
human-visible moderation, not machine coordination.

### 2.6 Stale-Assignment Recovery

Implemented in `dispatch-dedup-helper.sh recover_stale_assignment()`. Fires when:
- The issue has an assignee and active status labels.
- No worker process matching the issue can be found on the local machine.
- The assignment is older than `STALE_ASSIGNMENT_THRESHOLD_SECONDS`.

**Actions taken:**
1. Removes all assignees from the issue.
2. Removes `status:queued` / `status:in-progress`; adds `status:available`.
3. Posts a `WORKER_SUPERSEDED` comment with a structured HTML marker:
   `<!-- WORKER_SUPERSEDED runners=<login> ts=<ISO8601> -->`
   Workers can detect this marker and abort if their runner login matches.
4. Returns `STALE_RECOVERED: issue #N in slug — unassigned <login> (reason)` on stdout.

The `STALE_RECOVERED` token causes `pulse-dispatch-core.sh` to record the recovery as
a failed dispatch cycle (Layer 6), preventing the stale-recovery → immediate-redispatch
loop observed in the GH#18356 incident.

### 2.7 Parent-Task Label (t1986)

Issues tagged `parent-task` or `meta` are planning-only and must never receive a
dispatched worker. The label is an unconditional dispatch block: `dispatch-dedup-helper.sh
is-assigned` short-circuits with `PARENT_TASK_BLOCKED (label=parent-task)` before
evaluating any assignee or status label.

In TODO.md: use `#parent` (aliases: `#parent-task`, `#meta`). The tag maps to the
`parent-task` label via `issue-sync-lib.sh map_tags_to_labels`. The label is protected
in `issue-sync-helper.sh _is_protected_label` to survive reconciliation.

---

## 3. The Seven-Layer Dedup Chain

Implemented in `pulse-dispatch-core.sh check_dispatch_dedup()`, Lines 130-290.
Layers execute in order; the first match blocks dispatch.

| Layer | Guard | Script | Cost | What it prevents |
|---|---|---|---|---|
| 1 | In-flight dispatch ledger | `dispatch-ledger-helper.sh check-issue` | Fast (local file) | Workers dispatched but not yet visible in process lists or PRs (10-15 min gap) |
| 2 | Exact repo+issue process match | `has_worker_for_repo_issue()` | Medium (ps scan) | Duplicate dispatch when worker is already running locally |
| 3 | Normalized title key match | `dispatch-dedup-helper.sh is-duplicate` | Medium (gh API) | Different issues whose titles normalise to the same key |
| 4 | Open or merged PR evidence | `dispatch-dedup-helper.sh has-open-pr` | Medium (gh API) | Re-dispatch when a PR already exists (was only checking merged before GH#11141) |
| 5 | Cross-machine dispatch comment | `dispatch-dedup-helper.sh has-dispatch-comment` | Medium (gh API) | Runners that lost their local ledger entry (e.g., after restart) |
| 6 | Cross-machine assignee guard | `dispatch-dedup-helper.sh is-assigned` | Medium (gh API) | Runner-to-runner races; also fires the parent-task block and stale recovery |
| 7 | Optimistic claim comment lock | `dispatch-dedup-helper.sh claim` | Slow (gh comment + sleep + re-read) | Final simultaneous-arrival safety net for runners that pass Layers 1-6 together |

**Design rationale:** Layers 1-2 are local (fast, no API calls) to catch the common case.
Layers 3-6 use read-only GitHub API calls, adding latency only when local checks pass.
Layer 7 is write-heavy (posts a comment, waits for consensus window) and is last.

**Layer 6 combined-signal rule** prevents starvation: a repo owner or maintainer passively
assigned to an issue (for bookkeeping) does not block dispatch unless an active status
label is also present. This implements the `is-assigned` combined check from t1996.

---

## 4. Race Scenarios and Resolutions

### 4.1 Parent-Task Dispatch Loop (GH#18356, fixed t1986)

**Timeline:**
1. `t1962` parent task filed with subtasks. `#parent-task` label not yet protected.
2. Reconciliation runs, strips `parent-task` label (not in `_is_protected_label`).
3. Alex-solovyev pulse runner dispatches opus-4-6 worker on the (now unprotected) parent.
4. Worker burns ~20K tokens exploring the codebase. No useful output — parent tasks have
   no direct implementation; only their children do.
5. Same race reproduced on GH#18399 and GH#18400 while filing the fix itself.

**Root cause:** Four independent holes:
- `parent-task` label stripped by reconciliation.
- No `#parent` tag alias in `map_tags_to_labels`.
- `is-assigned` didn't check for parent-task label.
- No test coverage.

**Resolution (PR#18419):** All four holes patched in one PR. `parent-task` and `meta` added
to `_is_protected_label`; `#parent` alias added; `is-assigned` short-circuits on label
presence; 20-assertion test suite added in `tests/test-parent-task-guard.sh`.

### 4.2 Interactive-Claim Race (GH#18367 / GH#18371, fixed t1970)

**Timeline:**
1. Interactive session runs `claim-task-id.sh` for a new task. Sets `status:claimed` +
   owner assignment.
2. Pulse cycle fires 2 minutes later. GH#18352 had extended the active-claim definition
   to include `status:claimed`, but the `issue-sync-helper.sh push` path did not auto-assign.
3. Issue had no assignee yet (push path bug). Pulse saw `status:claimed` with no assignee
   → degraded-state rule → safe to dispatch. Worker launched.
4. Worker and interactive session racing on the same issue.

**Root cause:** `issue-sync-helper.sh push` path did not call `_auto_assign_issue` for
`origin:interactive` issues. Only the direct `claim-task-id.sh` create path auto-assigned.

**Resolution (PR#18374):** Auto-assign call added in `_gh_create_issue` for
`origin_label == origin:interactive`. Also: `_check_duplicate_title` changed from
`--state all` to `--state open` to prevent claiming refs against closed issues.

### 4.3 Stale-Recovery Loop

**Pattern:** Worker times out or dies. Stale recovery fires, unassigns the issue. Next
pulse cycle re-dispatches. New worker times out or dies. Cycle repeats indefinitely.

**Why it's costly:** Each worker burns tokens on setup (reading issue, checking codebase)
before producing zero productive output. 8+ dispatches in 6 hours was observed on
GH#17503 (marcusquinn + alex-solovyev runners).

**Signals:**
- Multiple `STALE_RECOVERED` comments on the issue.
- Multiple `DISPATCH_CLAIM` comments followed by `CLAIM_RELEASED`.
- Issue never reaches `status:in-review`.

**Resolution:** t2008 introduced backoff on repeated stale recovery: after N consecutive
stale recoveries on the same issue within a window, the pulse labels the issue
`status:needs-investigation` and skips dispatch until a human reviews.

**Diagnosis:**

```bash
# Count stale-recovery cycles on an issue
gh api repos/<slug>/issues/<num>/comments \
  --jq '[.[] | select(.body | test("STALE_RECOVERED|DISPATCH_CLAIM|CLAIM_RELEASED"))] | length'

# Check pulse log for repeated stale-recovery signals
grep "STALE_RECOVERED.*#<num>" ~/.aidevops/logs/pulse.log | tail -20
```

### 4.4 Token Cost Runaway (fixed t2007)

**Pattern:** A worker session is dispatched with a model tier (`tier:reasoning` / opus)
for an issue that does not warrant it. The worker exhausts its context exploring the
codebase without producing output, is watchdog-killed, and the issue is re-dispatched
(possibly at the same tier).

**Why it happens with multiple runners:** If two runners are on different aidevops versions,
and the older version does not enforce token budget caps or tier guards added in a newer
version, the older runner can dispatch runaway-prone workers.

**Key evidence from GH#17503:** Six dispatches from `marcusquinn` runner + one from
`alex-solovyev`. The `alex-solovyev` runner's pulse predated the GH#18352 fix, so it
dispatched on issues the marcusquinn runner would have blocked.

**Resolution:** t2007 added per-tier token budget caps (enforced in
`headless-runtime-helper.sh`) and a `max-dispatch-budget` guard in `pulse-dispatch-core.sh`
that blocks re-dispatch when cumulative tokens across failed attempts exceed the threshold.

**Version skew is the root cause:** Keep all runners on the same aidevops version. The
version guard (`headless-runtime-helper.sh`) checks `OPENCODE_PINNED_VERSION` before each
dispatch, but does not check the aidevops framework version itself. Run `aidevops update`
on all machines before bringing up a new session.

---

## 5. New Runner Setup

Steps for bringing up an additional pulse runner on a new machine. Every step is mandatory
for multi-runner safety.

### 5.1 Prerequisites

```bash
# 1. Install aidevops
curl -fsSL https://aidevops.sh/install | bash

# 2. Authenticate GitHub
gh auth login

# 3. Verify auth
gh auth status
```

### 5.2 Repo Registration

Register all repos that will receive workers. Runners that share `repos.json` via a
synced config dir do not need per-machine re-registration, but a fresh machine does.

```bash
# Add a repo to pulse
aidevops repos add marcusquinn/aidevops

# Verify
aidevops repos list
```

### 5.3 Version Parity (Critical for Multi-Runner Safety)

All active runners **must** run the same aidevops version. Version skew causes race
conditions because the dedup chain changes between versions.

```bash
# Check current version
aidevops --version

# Update to latest
aidevops update

# Verify no pending update
bash ~/.aidevops/agents/scripts/aidevops-update-check.sh
```

### 5.4 Configure Runner Identity

The runner's GitHub login (`self_login`) is auto-detected from `gh auth status`. Ensure
each machine authenticates with a distinct GitHub login if you want per-runner attribution.
If both runners authenticate as the same login, Layer 6 (`is-assigned`) will treat the
other runner's workers as self-assignments and allow double-dispatch.

### 5.5 Scope Control

Prevent one runner from dispatching on all repos when only a subset is intended:

```bash
# In ~/.config/aidevops/pulse.env or shared-constants.sh:
export PULSE_SCOPE_REPOS="marcusquinn/aidevops marcusquinn/some-other-repo"
```

Empty or unset means all `pulse: true` repos are in scope.

### 5.6 Pulse Window

To avoid overnight cross-runner collisions, configure `pulse_hours` per repo in
`~/.config/aidevops/repos.json`:

```json
{
  "slug": "marcusquinn/aidevops",
  "pulse": true,
  "pulse_hours": {"start": 8, "end": 22}
}
```

If two runners have overlapping windows on the same repos, the 7-layer dedup chain
ensures safety — but non-overlapping windows reduce noise in issue comments.

### 5.7 Launch the Pulse

```bash
# Install launchd plist (macOS)
aidevops pulse install

# Or start manually for testing
~/.aidevops/agents/scripts/pulse-wrapper.sh --dry-run

# Verify first cycle
tail -f ~/.aidevops/logs/pulse.log
```

---

## 6. Diagnosing a Suspected Race

Use this decision tree when an issue receives multiple workers or a worker dispatches
on something it should not.

### Symptom: Issue dispatched twice in quick succession

```bash
# 1. Check which runners posted dispatch claims
gh api repos/<slug>/issues/<num>/comments \
  --jq '.[] | select(.body | test("DISPATCH_CLAIM")) | "\(.created_at) \(.user.login): \(.body[0:80])"'

# 2. Check layer that failed to block
# - If claims are from different logins: Layer 6 (is-assigned) failed
# - If claims are from same login within 8s: Layer 7 (claim window race)
# - If one claim is very old and the other is new: Layer 5 (has-dispatch-comment) failed

# 3. Check the aidevops version on each runner
grep "aidevops_version\|AIDEVOPS_VERSION" ~/.aidevops/logs/pulse.log | head -5
```

### Symptom: Parent-task issue received a worker

```bash
# Check for parent-task label
gh issue view <num> --json labels --jq '.labels[].name'

# If parent-task label is missing but issue IS a parent task:
# Add it manually
gh issue edit <num> --add-label parent-task

# Check if label was stripped by reconciliation
git log --oneline -5 --all -- TODO.md
```

### Symptom: Interactive session raced by the pulse

```bash
# Check origin label
gh issue view <num> --json labels --jq '.labels[] | select(.name | startswith("origin")) | .name'

# Check assignees at time of race (look at comment timeline)
gh issue view <num> --comments --jq '.comments[] | select(.body | test("DISPATCH_CLAIM|claimed")) | "\(.createdAt): \(.body[0:120])"'

# If origin:interactive is present but pulse still dispatched:
# Check aidevops version — GH#18352 fix required for this guard
aidevops --version
```

### Symptom: Stale-recovery loop (issue never makes progress)

```bash
# Count recovery cycles
gh api repos/<slug>/issues/<num>/comments \
  --jq '[.[] | select(.body | test("STALE_RECOVERED|WORKER_SUPERSEDED"))] | length'

# If count >= 3: manually investigate why workers time out
# Check last worker log
ls -t /tmp/pulse-*-<num>.log | head -1 | xargs tail -50

# Escalate: add needs-investigation label to stop pulse dispatch
gh issue edit <num> --add-label needs-investigation
```

### Symptom: Dedup not firing despite obvious duplicate

```bash
# Test each layer manually
SCRIPT=~/.aidevops/agents/scripts/dispatch-dedup-helper.sh

# Layer 5: does a dispatch comment exist?
"$SCRIPT" has-dispatch-comment <num> <owner/repo>

# Layer 6: is the issue assigned to another runner?
"$SCRIPT" is-assigned <num> <owner/repo> <self_login>

# Layer 3: is this a title duplicate?
"$SCRIPT" is-duplicate <num> <owner/repo> "Issue #<num>: <title>"

# Layer 4: is there an open/merged PR?
"$SCRIPT" has-open-pr <num> <owner/repo>
```

---

## 7. See Also

- `reference/worker-diagnostics.md` — single-runner worker lifecycle, DB isolation,
  watchdog, canary, recovery checklist
- `workflows/pulse.md` — full pulse workflow and dispatch comment templates
- `AGENTS.md` "Session origin labels" — `origin:interactive` implications
- `AGENTS.md` "General dedup rule — combined signal (t1996)" — combined label+assignee rule
- `AGENTS.md` "Parent / meta tasks (#parent tag, t1986)" — parent-task block semantics
- `scripts/dispatch-dedup-helper.sh` — implementation of Layers 3-7
- `scripts/pulse-dispatch-core.sh:130` — 7-layer chain orchestration
- `scripts/tests/test-parent-task-guard.sh` — regression coverage for t1986 fix
- `scripts/tests/test-dispatch-dedup-multi-operator.sh` — multi-operator dedup assertions

### Related Issues and PRs

| Reference | What it fixed |
|---|---|
| GH#11086 (PR embedded) | Layer 7 claim comment as mandatory code path (not LLM-instructed step) |
| GH#11141 | Layer 5 cross-machine dispatch comment |
| GH#6891 | Layer 6 cross-machine assignee guard (original) |
| GH#18352 (t1961) | `origin:interactive` blocks pulse dispatch on owner-assigned issues |
| GH#18371 (PR#18374, t1970) | Interactive-claim race via push path missing auto-assign |
| GH#18399 (PR#18419, t1986) | Parent-task 4-hole fix + test harness |
| GH#17503 | Token cost runaway with multiple runners (stale-recovery loop evidence) |
