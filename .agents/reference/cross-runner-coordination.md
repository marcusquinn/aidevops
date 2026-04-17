<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Cross-Runner Coordination

> **Audience:** Maintainers operating multiple pulse runners across machines;
> engineers debugging race conditions in multi-operator environments.

<!-- AI-CONTEXT-START -->

**TL;DR:** Runners do not communicate directly. GitHub is the shared coordination
layer. Every dispatch decision must read GitHub state (assignees, labels, dispatch
comments) before posting a claim. Skipping any step breaks multi-runner safety.

**Core rule (t1996):** The dedup signal is `(active status label) AND (non-self
assignee)` — both required, neither sufficient alone. Every dispatch path must
consult `dispatch-dedup-helper.sh is-assigned` before launching a worker.

<!-- AI-CONTEXT-END -->

## 1. The Runner Model

A **runner** is a machine (physical or virtual) running a `pulse-wrapper.sh`
launchd/cron job that dispatches headless worker sessions to solve GitHub issues.

- **Stateless relative to each other.** No runner-to-runner RPC, no shared
  message bus. All coordination happens through GitHub issue state.
- **GitHub is the source of truth.** A runner that disagrees with GitHub state
  has no authority to override it.
- **Any number may be active.** The 7-layer dedup chain (§3) ensures at most one
  worker per issue regardless of runner count.
- **Identity:** Each runner passes `self_login` to `dispatch-dedup-helper.sh` —
  the GitHub login of the machine's authenticated user (e.g., `marcusquinn`,
  `alex-solovyev`).

**What runners do NOT know about each other:** which issues another runner is
currently evaluating (no pre-claim lock); which aidevops version another runner
is on (version skew is a real failure mode — §4.4); whether another runner's
worker is alive or stalled (determined by stale-assignment threshold — §2.6).

---

## 2. Coordination Signals

GitHub state fields runners read and write to coordinate. Each signal has a
canonical owner and a failure mode if it drifts out of sync.

### 2.1 Assignees

A non-self assignee on an issue signals another runner claimed it. Set by
`pulse-dispatch-core.sh` immediately before launching a worker
(`gh issue edit --add-assignee`); removed on worker completion/failure. Read by
`dispatch-dedup-helper.sh is-assigned` (Layer 6), which combines assignee with
active status label to decide whether to block dispatch.

**Failure modes:**

- **Phantom assignee:** Worker died without releasing. Resolution: stale-recovery
  threshold fires after `STALE_ASSIGNMENT_THRESHOLD_SECONDS` (`shared-constants.sh`).
  Recovery unassigns, relabels `status:available`, and posts a `WORKER_SUPERSEDED`
  comment (t1955).
- **Owner/maintainer passive assignment:** A maintainer self-assigns for
  bookkeeping. Was a starvation source (GH#10521) — fixed by the combined signal
  rule: an owner/maintainer assignee only blocks dispatch when an active status
  label is also present (§2.2, §3).

### 2.2 Status Labels

Active lifecycle labels — any one means "a worker is live or claimed":

| Label | Set by | Meaning |
|---|---|---|
| `status:claimed` | `claim-task-id.sh` | Interactive session claimed the task |
| `status:queued` | Pulse dispatcher | Worker about to launch |
| `status:in-progress` | Worker (self-report) | Worker actively running |
| `status:in-review` | Worker on PR open | Worker opened a PR, awaiting review |
| `status:available` | Stale recovery / completion | No active claim |

**Combined signal rule (t1996):** dedup fires only when `(active status label)
AND (non-self assignee)`. See `dispatch-dedup-helper.sh _has_active_claim()`.
Degraded states and their handling:

- **Status label, no assignee** — worker died mid-claim. Safe to reclaim after
  `normalize_active_issue_assignments` / stale recovery.
- **Non-owner assignee, no status label** — active contributor claim. Blocks
  dispatch regardless of labels.
- **Owner assignee + active status label** — active pulse claim. Blocks
  dispatch (GH#18352).
- **Owner assignee, no status label** — passive bookkeeping. Allows dispatch
  (GH#10521).

### 2.3 Origin Labels

**`origin:interactive`** — set by `claim-task-id.sh` / `issue-sync-helper.sh`
when the claiming session is interactive (human present):

- Pulse treats any assignee on an `origin:interactive` issue as blocking, even
  if it's the repo owner/maintainer. Closes the race where the user starts work
  and the pulse dispatches a duplicate before the PR opens (GH#18352, t1961).
- PRs with `origin:interactive` pass the maintainer gate automatically when the
  PR author is OWNER or MEMBER — human was present and directing the work.
- Pulse's deterministic merge pass never auto-closes `origin:interactive` PRs
  (GH#18352, extra fix t1970).

**`origin:worker`** — set by the pulse when it dispatches a headless worker.
Used by the maintainer gate and audit trail; not a dedup signal on its own.

### 2.4 Dispatch Comments

Runners post `DISPATCH_CLAIM nonce=<UUID>` comments before launching a worker
(Layer 7). After posting, the runner sleeps `DISPATCH_CLAIM_WINDOW` seconds
(default 8s), re-reads comments, and yields if another runner's claim is older.
**Oldest claim wins.** This is the final cross-machine safety net — two runners
simultaneously passing Layers 1–6 both post claims; only one proceeds.

The claim comment survives beyond the claim window, letting Layer 5
(`has-dispatch-comment`) block re-dispatch in future pulse cycles while the
issue stays open and the PR is unmerged.

**Failure mode (GH#11086):** Before Layer 7 was code-enforced, the claim step
was an LLM-instructed step in `pulse.md` that runners could skip. Two runners
(marcusquinn and johnwaldo) dispatched on the same issue 45 seconds apart.
Fixed by encoding the claim as a mandatory Layer 7 in `pulse-dispatch-core.sh`.

### 2.5 Issue Locks

Not used by the dispatch flow. The optimistic claim comment (§2.4) serves as
the cross-machine mutex. GitHub issue locking is reserved for human-visible
moderation, not machine coordination.

### 2.6 Stale-Assignment Recovery

Implemented in `dispatch-dedup-helper.sh recover_stale_assignment()`. Fires
when the issue has an assignee + active status labels, no matching local worker
process, and the assignment is older than `STALE_ASSIGNMENT_THRESHOLD_SECONDS`.

**Actions:** removes all assignees; removes `status:queued`/`status:in-progress`,
adds `status:available`; posts `WORKER_SUPERSEDED` comment with HTML marker
`<!-- WORKER_SUPERSEDED runners=<login> ts=<ISO8601> -->` (workers can detect
this marker and abort if their runner login matches); returns
`STALE_RECOVERED: issue #N in slug — unassigned <login> (reason)` on stdout.

The `STALE_RECOVERED` token causes `pulse-dispatch-core.sh` to record the
recovery as a failed dispatch cycle (Layer 6), preventing the stale-recovery
→ immediate-redispatch loop observed in the GH#18356 incident.

### 2.7 Parent-Task Label (t1986)

Issues tagged `parent-task` or `meta` are planning-only and must never receive
a dispatched worker. The label is an unconditional dispatch block:
`dispatch-dedup-helper.sh is-assigned` short-circuits with
`PARENT_TASK_BLOCKED (label=parent-task)` before evaluating assignees or status.

In TODO.md: use `#parent` (aliases: `#parent-task`, `#meta`). The tag maps to
the `parent-task` label via `issue-sync-lib.sh map_tags_to_labels`. The label
is protected in `issue-sync-helper.sh _is_protected_label` to survive
reconciliation.

---

## 3. The Seven-Layer Dedup Chain

Implemented in `pulse-dispatch-core.sh check_dispatch_dedup()` (lines 130–290).
Layers execute in order; the first match blocks dispatch.

| # | Guard | Script | Cost | Prevents |
|---|---|---|---|---|
| 1 | In-flight dispatch ledger | `dispatch-ledger-helper.sh check-issue` | Fast (local file) | Workers dispatched but not yet visible in process lists or PRs (10–15 min gap) |
| 2 | Exact repo+issue process match | `has_worker_for_repo_issue()` | Medium (ps scan) | Duplicate dispatch when a worker is already running locally |
| 3 | Normalized title-key match | `dispatch-dedup-helper.sh is-duplicate` | Medium (gh API) | Different issues whose titles normalise to the same key |
| 4 | Open or merged PR evidence | `dispatch-dedup-helper.sh has-open-pr` | Medium (gh API) | Re-dispatch when a PR already exists (was only checking merged before GH#11141) |
| 5 | Cross-machine dispatch comment | `dispatch-dedup-helper.sh has-dispatch-comment` | Medium (gh API) | Runners that lost their local ledger entry (e.g., after restart) |
| 6 | Cross-machine assignee guard | `dispatch-dedup-helper.sh is-assigned` | Medium (gh API) | Runner-to-runner races; also fires the parent-task block and stale recovery |
| 7 | Optimistic claim comment lock | `dispatch-dedup-helper.sh claim` | Slow (gh comment + sleep + re-read) | Final simultaneous-arrival safety net for runners that pass Layers 1–6 together |

**Design rationale:** Layers 1–2 are local (no API calls) to catch the common
case. Layers 3–6 use read-only GitHub API calls, adding latency only when local
checks pass. Layer 7 is write-heavy (posts a comment, waits for consensus
window) and is last.

**Layer 6 combined-signal rule** prevents starvation: a repo owner/maintainer
passively assigned to an issue for bookkeeping does not block dispatch unless
an active status label is also present. Implements the `is-assigned` combined
check from t1996.

---

## 4. Race Scenarios and Resolutions

### 4.1 Parent-Task Dispatch Loop (GH#18356, fixed t1986)

**Timeline:** `t1962` parent task filed with subtasks → reconciliation stripped
`parent-task` label (not in `_is_protected_label`) → alex-solovyev pulse runner
dispatched opus-4-6 worker on the unprotected parent → worker burned ~20K
tokens exploring the codebase with no useful output (parent tasks have no
direct implementation). Same race reproduced on GH#18399 and GH#18400 while
filing the fix itself.

**Root cause:** Four independent holes — `parent-task` label stripped by
reconciliation; no `#parent` tag alias in `map_tags_to_labels`; `is-assigned`
didn't check for parent-task label; no test coverage.

**Resolution (PR#18419):** All four holes patched in one PR. `parent-task` and
`meta` added to `_is_protected_label`; `#parent` alias added; `is-assigned`
short-circuits on label presence; 20-assertion test suite added in
`tests/test-parent-task-guard.sh`.

### 4.2 Interactive-Claim Race (GH#18367 / GH#18371, fixed t1970)

**Timeline:** Interactive session runs `claim-task-id.sh` → sets
`status:claimed` + owner assignment. Pulse cycle fires 2 minutes later.
GH#18352 had extended the active-claim definition to include `status:claimed`,
but the `issue-sync-helper.sh push` path did not auto-assign. Issue had no
assignee yet (push path bug) → pulse saw `status:claimed` with no assignee
→ degraded-state rule → safe to dispatch. Worker and interactive session raced.

**Root cause:** `issue-sync-helper.sh push` path did not call
`_auto_assign_issue` for `origin:interactive` issues. Only the direct
`claim-task-id.sh` create path auto-assigned.

**Resolution (PR#18374):** Auto-assign call added in `_gh_create_issue` for
`origin_label == origin:interactive`. Also: `_check_duplicate_title` changed
from `--state all` to `--state open` to prevent claiming refs against closed
issues.

### 4.3 Stale-Recovery Loop

**Pattern:** Worker times out or dies → stale recovery unassigns → next pulse
cycle re-dispatches → new worker times out. Cycle repeats indefinitely.

**Cost:** Each worker burns tokens on setup (reading issue, checking codebase)
before producing zero output. 8+ dispatches in 6 hours observed on GH#17503
(marcusquinn + alex-solovyev runners).

**Signals:** multiple `STALE_RECOVERED` comments; multiple `DISPATCH_CLAIM`
followed by `CLAIM_RELEASED`; issue never reaches `status:in-review`.

**Resolution:** t2008 introduced backoff on repeated stale recovery — after N
consecutive recoveries within a window, the pulse labels the issue
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

**Pattern:** A worker session is dispatched at a model tier (`tier:thinking` /
opus) that the issue does not warrant. The worker exhausts its context
exploring the codebase without producing output, is watchdog-killed, and is
re-dispatched (possibly at the same tier).

**Why multi-runner makes it worse:** If two runners are on different aidevops
versions and the older lacks a token-budget or tier guard added in a newer
version, the older runner can dispatch runaway-prone workers.

**Evidence (GH#17503):** Six dispatches from the `marcusquinn` runner + one
from `alex-solovyev`. The `alex-solovyev` runner's pulse predated the GH#18352
fix, so it dispatched on issues the `marcusquinn` runner would have blocked.

**Resolution:** t2007 added per-tier token budget caps (enforced in
`headless-runtime-helper.sh`) and a `max-dispatch-budget` guard in
`pulse-dispatch-core.sh` that blocks re-dispatch when cumulative tokens across
failed attempts exceed the threshold.

**Version skew is the root cause.** Keep all runners on the same aidevops
version. The version guard (`headless-runtime-helper.sh`) checks
`OPENCODE_PINNED_VERSION` before each dispatch but does not check the aidevops
framework version itself. Run `aidevops update` on all machines before bringing
up a new session.

---

## 5. New Runner Setup

Every step below is mandatory for multi-runner safety.

### 5.1 Prerequisites

```bash
curl -fsSL https://aidevops.sh/install | bash   # Install
gh auth login                                   # Authenticate
gh auth status                                  # Verify
```

### 5.2 Repo Registration

Register all repos that will receive workers. Runners sharing `repos.json` via
a synced config dir do not need per-machine re-registration; a fresh machine
does.

```bash
aidevops repos add marcusquinn/aidevops
aidevops repos list
```

### 5.3 Version Parity (Critical)

All active runners **must** run the same aidevops version. Version skew causes
race conditions because the dedup chain changes between versions.

```bash
aidevops --version
aidevops update
bash ~/.aidevops/agents/scripts/aidevops-update-check.sh   # Verify no pending update
```

### 5.4 Runner Identity

`self_login` is auto-detected from `gh auth status`. Each machine should
authenticate with a distinct GitHub login if you want per-runner attribution.
**If both runners authenticate as the same login, Layer 6 (`is-assigned`) will
treat the other runner's workers as self-assignments and allow double-dispatch.**

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

Overlapping windows are safe — the 7-layer chain ensures correctness — but
non-overlapping windows reduce noise in issue comments.

### 5.7 Launch the Pulse

```bash
aidevops pulse install                                    # Install launchd plist (macOS)
~/.aidevops/agents/scripts/pulse-wrapper.sh --dry-run     # Or start manually for testing
tail -f ~/.aidevops/logs/pulse.log                        # Verify first cycle
```

---

## 6. Diagnosing a Suspected Race

Decision tree for when an issue receives multiple workers or a worker
dispatches on something it should not.

### Symptom: Issue dispatched twice in quick succession

```bash
# 1. Which runners posted dispatch claims?
gh api repos/<slug>/issues/<num>/comments \
  --jq '.[] | select(.body | test("DISPATCH_CLAIM")) | "\(.created_at) \(.user.login): \(.body[0:80])"'

# 2. Identify the failing layer:
#    - Claims from different logins          → Layer 6 (is-assigned) failed
#    - Claims from same login within 8s      → Layer 7 (claim window race)
#    - One claim old + one new               → Layer 5 (has-dispatch-comment) failed

# 3. Check aidevops version on each runner
grep "aidevops_version\|AIDEVOPS_VERSION" ~/.aidevops/logs/pulse.log | head -5
```

### Symptom: Parent-task issue received a worker

```bash
gh issue view <num> --json labels --jq '.labels[].name'
# If parent-task label missing but issue IS a parent task, add it manually:
gh issue edit <num> --add-label parent-task
# Check if label was stripped by reconciliation:
git log --oneline -5 --all -- TODO.md
```

### Symptom: Interactive session raced by the pulse

```bash
# Check origin label
gh issue view <num> --json labels --jq '.labels[] | select(.name | startswith("origin")) | .name'

# Check assignees at time of race (look at comment timeline)
gh issue view <num> --comments --jq '.comments[] | select(.body | test("DISPATCH_CLAIM|claimed")) | "\(.createdAt): \(.body[0:120])"'

# If origin:interactive is present but pulse still dispatched, check aidevops version
# — GH#18352 fix required for this guard
aidevops --version
```

### Symptom: Stale-recovery loop (issue never makes progress)

```bash
# Count recovery cycles
gh api repos/<slug>/issues/<num>/comments \
  --jq '[.[] | select(.body | test("STALE_RECOVERED|WORKER_SUPERSEDED"))] | length'

# If count >= 3: manually investigate why workers time out
ls -t /tmp/pulse-*-<num>.log | head -1 | xargs tail -50

# Escalate: stop pulse dispatch until human review
gh issue edit <num> --add-label needs-investigation
```

### Symptom: Dedup not firing despite obvious duplicate

Test each layer manually:

```bash
SCRIPT=~/.aidevops/agents/scripts/dispatch-dedup-helper.sh
"$SCRIPT" has-dispatch-comment <num> <owner/repo>              # Layer 5
"$SCRIPT" is-assigned <num> <owner/repo> <self_login>          # Layer 6
"$SCRIPT" is-duplicate <num> <owner/repo> "Issue #<num>: <title>"  # Layer 3
"$SCRIPT" has-open-pr <num> <owner/repo>                       # Layer 4
```

---

## 7. See Also

- `reference/worker-diagnostics.md` — single-runner worker lifecycle, DB
  isolation, watchdog, canary, recovery checklist
- `workflows/pulse.md` — full pulse workflow and dispatch comment templates
- `AGENTS.md` "Session origin labels" — `origin:interactive` implications
- `AGENTS.md` "General dedup rule — combined signal (t1996)"
- `AGENTS.md` "Parent / meta tasks (#parent tag, t1986)"
- `scripts/dispatch-dedup-helper.sh` — implementation of Layers 3–7
- `scripts/pulse-dispatch-core.sh` — `check_dispatch_dedup()` orchestration
- `scripts/tests/test-parent-task-guard.sh` — regression coverage for t1986
- `scripts/tests/test-dispatch-dedup-multi-operator.sh` — multi-operator dedup
  assertions

### Related Issues and PRs

| Reference | What it fixed |
|---|---|
| GH#6696 | Layer 1 dispatch ledger — catches workers in 10–15 min pre-PR gap |
| GH#6891 | Layer 6 cross-machine assignee guard (original) |
| GH#10521 | Maintainer passive assignment starvation — combined-signal rule origin |
| GH#11086 | Layer 7 claim comment as mandatory code path (not LLM-instructed) |
| GH#11141 | Layer 5 cross-machine dispatch comment |
| GH#17503 | Token cost runaway with multiple runners (stale-recovery loop evidence) |
| GH#18352 (t1961) | `origin:interactive` blocks pulse dispatch on owner-assigned issues |
| GH#18356 | Parent-task dispatch loop incident — t1962 parent dispatched with opus-4-6 |
| GH#18367 | Interactive-claim race incident — pulse dispatched while interactive session active |
| GH#18371 (PR#18374, t1970) | Interactive-claim race via push path missing auto-assign |
| GH#18399 (PR#18419, t1986) | Parent-task 4-hole fix + test harness |
| GH#18458 | Fail-open dedup bug — jq null-handling allowed dispatch to parent-task issues |
