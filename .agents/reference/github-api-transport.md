<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2026 Marcus Quinn -->

# GitHub API transport and freshness

These controls maximise useful work within GitHub's available capacity while
preserving fresh action-boundary checks. Fewer calls are not an end in themselves.
They do not establish a production savings percentage; use the matched
windows and completeness gates in [the efficiency benchmark](github-api-efficiency.md).

## Correct queries before more caching

- CLI `--state closed` means **closed but unmerged**. REST `/pulls?state=closed`
  contains merged and unmerged PRs. The REST adapter filters before satisfying
  `--limit`, so a closed-only request can scan a large merged history. Merged-PR
  reconciliation requests `--state merged` and still validates `mergedAt`.
- Healthy closed-only list reads prefer native server-side filtering rather
  than unconditional REST-first. Explicit/low-GraphQL REST fallback retains
  equivalent semantics. This is a query-shape decision, not an assumed quota
  balance or a relaxation of JSON-field equivalence.
- Peer monitoring reuses per-repository observations instead of three requests
  per peer. Preserve the upstream dispatch-ownership, device-freshness and
  unknown-observation contract: creation origin is not current ownership.
  Invalid time configuration or failed collection cannot become a zero-work
  observation or overwrite the previous state and dispatch overrides.
- Dirty-worktree checks request comments updated within the active hold window,
  with a boundary margin, and paginate all relevant pages. They do not inspect
  only the first hundred old comments. Failed/malformed evidence is a hold, not
  a clear result. A later resolution is determined by timestamps, not response
  order; ambiguous timestamps do not grant resume or clearance.

No additional persistent comment or historical-PR body cache is required by
these changes. Existing TTLs are not lengthened, future-dated discovery cache
entries miss, and discovery data never replaces final lock/trust/head/check
verification.

## Common native boundary

The PATH shim applies the shared cooldown before ordinary native requests,
including raw agent commands. Wrapper-admitted boot/recovery reads are not
charged twice, but cooldown is rechecked immediately before dispatch. Local-only
commands remain usable without fabricated HTTP attempts. `gh search` is a REST
search operation, not a GraphQL query.

Unambiguous primary exhaustion (successful response or HTTP 403/429,
`remaining=0`, a known resource, valid reset, no Retry-After or secondary/abuse
message) holds only that resource: `core`, `search`, `code_search`, or `graphql`.
The `.primary-<resource>` cooldown uses the server reset and is checked before
direct API requests at the raw shim and REST-wrapper boundaries. Quota-status
reads and unrelated pools remain usable; high-level opaque CLI commands retain
native execution. Expired primary headers cannot create a new global delay.
Existing global cooldowns are never cleared by this path; Retry-After,
secondary/abuse and ambiguous evidence retain global protection. Primary and
secondary holds are labelled separately in diagnostics.

Healthy system boots no longer start a 60-reads/minute ramp by default.
The bounded recovery ramp after actual global throttling remains; explicit
`AIDEVOPS_GH_READ_RAMP_BOOT_SECS` overrides still opt into a boot ramp.

Native execution errors without a usable HTTP response stop alternate
transports. A successful HTTP response which cannot reproduce a requested local
projection retains the existing semantically equivalent read fallback. Native
exit `125` is not an unsupported-shape signal after execution: an explicit
handled receipt prevents replaying the request.

## Bounded authenticated REST reads

`gh-transport-governor.py` and `gh_transport_budget.py` admit supported
non-interactive authenticated `GET` shapes using private local SQLite state.
They inspect included final-response headers without enabling `GH_DEBUG` and
never cache a response body. Explicit REST pagination uses the same boundary
per page. The credential fingerprint and native request use the same pinned
child environment; credentials are never exported to a long-lived parent.

- Resource-owned response headers establish remaining quota. `/rate_limit`
  JSON is not treated as an admission balance.
- In-flight reservations are atomic. All available primary points, including
  the final point, are usable; there is no 100-point core or one-point search
  reserve and no four-request concurrency cap.
- `gh_transport_capacity.py` measures recent admitted demand. Once at least ten
  seconds of observations predict exhaustion before reset, requests are paced
  using remaining capacity and time to reset, not an arbitrary fixed allowance.
  Healthy demand and initial bursts remain unhindered by that pacing rule.
  The local supported-GET envelope also respects GitHub's 100-concurrent and
  900-REST-points/minute secondary ceilings across resource pools. This is not
  complete secondary-limit accounting: opaque native commands, endpoint-specific
  costs, CPU limits and other machines still require server-directed backoff.
- Brief local contention waits without sending HTTP. Longer waits return 75
  with `attempted=false`, a local admission reason and `retry_at`; callers can
  reschedule without treating a local deferral as a GitHub rejection. No alternate
  transport retry or cached application response is substituted.
  The shim retries at most once, only for proven unattempted local admission and
  only when the supplied deadline fits a five-second wait. Longer or invalid
  deadlines return rescheduling evidence immediately. Required-context readers
  and the merge gate retain the reason and deadline, including cached failures;
  unknown required checks never become a passing result. A successful retry does
  not leak the superseded error into JSON output.
- Missing/stale observations permit one serialized observation, not an assumed
  new allowance. Unknown execution remains debt until a later response from
  the same credential covers it. Out-of-order responses cannot restore spent
  quota inside a live reset window.
- A stale positive balance can revalidate through one accounted GET every 60
  seconds, independently of ordinary response freshness. Once due, new admissions
  yield until active work drains; admissions also wait for the probe to finish.
  Continuous healthy traffic therefore cannot indefinitely postpone recovery.
  The existing revalidation table stores the cadence anchor; no schema migration
  is needed. Older callers stay conservative, but only updated callers provide
  the drain/serialization guarantee during a mixed-version rollout.
  No active request, real cooldown,
  exhaustion or uncertain spend may be bypassed. The exact probe reservation
  can repair a stale balance only with causally newer resource-owned headers and
  a single bound credential or an explicitly configured canonical owner;
  unresolved shared scopes stay conservative. This is
  bounded recovery, not an alternative transport or a status-endpoint grant.
- Set `AIDEVOPS_GH_BUDGET_DIAGNOSTICS=1` for numeric response and scope-binding
  transition evidence in `budget-transitions.jsonl` beside `admission.sqlite3`.
  The mode-600 log records previous/incoming/accepted balances and reset times,
  ordering, probe recovery and the conservative decision after commit. It never
  contaminates CLI JSON or logs credentials, owners, endpoints or response bodies.
  Disable it after capturing evidence; logging errors never alter admission.
  This diagnoses future transitions, not the unproven origin of an existing balance.
- `python3 gh_transport_budget.py status` reads local admission evidence without
  HTTP, credential values or database mutation. Pulse Check reports this separately
  from GraphQL. Label-eligible queue counts are not proof of launch admission.
- PID birth identity protects recovery. A credential changing owner
  configuration cannot obtain an independent second budget: live scope state
  and reservations are merged conservatively.
- `AIDEVOPS_GH_QUOTA_OWNER` may identify a trusted user/installation owner.
  Multiple PATs for that owner share an allowance. Unresolved callers share a
  conservative host scope. This is local coordination, **not distributed fleet
  admission**. Permission-scoped cache identity remains a separate concern.
- Status reports the number of bound credentials and an anonymous ambiguity
  reason. It never exposes credential fingerprints or owner values. When a
  previously unresolved scope retains stale evidence, stop all local GitHub
  requests, set one trusted owner consistently for every caller using that state,
  then run `python3 .agents/scripts/gh_transport_budget.py reconcile`. Reconciliation refuses
  active or uncertain requests, preserves live server cooldowns, reverses the
  unresolved alias into the configured owner, and makes the next normal GET the
  single serialized source of fresh quota. It is idempotent and cannot be used
  repeatedly or with a different owner to discard attributed pacing evidence.
  Do not use it to combine credentials belonging to different GitHub users or installations.

Mutations, streamed inputs, inherited file descriptors, anonymous requests,
GraphQL, interactive terminals and unsupported CLI shapes retain native
execution plus common cooldown. The adapter must not break an unlinked signed
body's inherited descriptor or turn injected headers into application data.

Normal observations describe a native invocation and its final response; do not
claim complete wire-level accounting for hidden native redirects/retries.
Explicit `AIDEVOPS_GH_EXACT_QUOTA_CAPTURE=1` retains the existing multi-response
recorder and serialization instead of this read adapter. Consequently, an
exact-capture query-efficiency window is not alone proof of the new admission
controller's normal-mode latency. Retain unknowns and require profile-appropriate
evidence before tuning defaults or claiming an integrated benchmark pass.

Rollback: `AIDEVOPS_GH_TRANSPORT_GOVERNOR_DISABLE=1` disables the read adapter,
not shared cooldown. It does not authorize bypassing signatures or safety gates.

## Exact required-check observations

The long-running required-check waiter preserves structured transport outcomes
from exact identity and paginated status-rollup reads. A proven unattempted local
admission uses its `retry_at`; an active secondary cooldown uses `expires_at`.
When the deadline fits inside the waiter's overall timeout, the waiter sleeps to
that deadline with bounded jitter and performs no intermediate GitHub request.
Deadlines beyond the timeout return an explicit indeterminate result. Attempted
API failures and malformed evidence remain separate diagnostics, and deferral
plus recovery messages are transition-only.

`gh_pr_checks_observed_json` coalesces only short-lived observational reads for
the waiter. Its request identity includes repository, PR, full head SHA,
required/all mode, projection version, API pool, and a hashed auth scope. The
mode-600 payload is validated before reuse and expires after five seconds by
default (maximum 30). Lease ownership and auth-independent invalidation
generation are rechecked immediately before publication; a PR-head mismatch
cannot publish under the old key. Scope or coordination failure falls back to a
fresh exact read rather than sharing across an uncertain boundary.

This cache grants no merge authority. `gh_pr_checks_exact_json` remains the
uncached action-boundary API used by merge and other consequential gates. The
waiter also performs fresh PR-head reads around terminal observation. Use
`gh_pr_checks_observation_invalidate` when a verified event invalidates one exact
repository/PR/head/mode identity. Rollback can disable shared coordination with
`AIDEVOPS_GH_SINGLEFLIGHT_DISABLE=1`; direct exact reads remain available.

## Pulse scheduling versus request admission

Pulse scheduling hints do not reserve quota a second time. REST progress work
may use all remaining capacity by default: the hard floor and guessed in-flight
allowance are both zero. Explicit nonzero operator overrides remain supported
and intentionally withhold capacity. Optional REST work still yields under
pressure using the soft cap, which decays to zero as reset approaches.

GraphQL optional-stage and dispatch thresholds now use the same reset-aware
window rule rather than permanently withholding 1,250 or 250 points. Missing
reset evidence retains the configured cap; crossing a reset is not a new quota
grant. Actual exhaustion remains blocked and supported REST fallback can keep
work moving when GraphQL is depleted.

Evaluate changes by completed work, latency, terminal throttles, and useful work
deferred while quota expires unused. Do not claim throughput improvement from
unit tests or fewer requests alone. Existing freshness/trust checks and optional
benchmark comparability rules remain unchanged.

Pulse idle backoff evaluates its local interval before optional available-work
discovery. A normal cycle therefore spends no pre-backoff discovery request.
The wake hint uses one REST repository-issues page, server-filtered by open state,
both dispatch labels and no assignee, instead of Search. Client filtering excludes
PRs, unpublished work, maintainer/permission holds and infrastructure advisories.
It also mirrors the dispatcher's hard management/status exclusions: persistent
audit/supervisor tickets, parents, held, consolidated and completed work cannot
continually reset idle backoff just because stale availability labels remain.
The hint still grants no launch authority; fresh dispatch gates remain canonical.
A full page with no eligible issue is incomplete evidence, not an empty queue;
normal cycle discovery handles it without unbounded optional pagination. This
removes the recurring availability Search producer, not GitHub's secondary limit.
When local state already calls for a skipped cycle,
an active shared secondary cooldown or its recovery ramp suppresses that
optional probe so interactive authority checks receive the recovery window.
Timeouts, other request errors, and malformed/incomplete pages remain unknown rather than
becoming an empty queue, so the watchdog-protected cycle fails open. A proven
unattempted local transport deferral (exit 75) instead retains the prior local
skip decision and reschedules without a backend request. Successful eligible-work
evidence still resets idle backoff. Cooldown diagnostics retain only sanitized
method, endpoint/query shape, operation, wrapper, and Pulse-stage attribution.
Remaining-quota headers retain their value in event and state metadata regardless
of header casing; a missing value stays unknown. Positive primary quota never
overrides a genuine secondary response. Rollback may revert the query change,
but must preserve the local-first idle ordering and shared cooldown.

Fresh PR-readiness reads preserve transport cooldown, recovery-ramp and local
admission diagnostics across command substitution. Those outcomes defer merge
without generating a false CI failure; timeouts, malformed responses and other
failed reads remain indeterminate. No additional retry, cached authorization or
alternate transport is introduced. Continuous interactive development and useful
worker delivery within finite GitHub/AI allowances remain the objective, rather
than either maximum request volume or minimum request count in isolation.

## Durable PR wake hints

`pulse-merge-dirty-queue.py` stores repo/PR identifiers, generation, wake and
lease metadata under a private state directory. It stores no PR/check/review
contents and grants no merge authority.

- Signed receiver events invalidate first. A failed invalidation remains
  latched for the whole delivery; a later successful invalidation cannot erase
  that failure.
- Repeated wakes coalesce, with a short debounce. Event and ordinary Pulse
  processing share per-PR logical leases. No lock descriptor is inherited by
  Git hooks. A live owner is not displaced merely because time elapsed.
- Acknowledgement is generation-fenced. An event arriving during processing
  survives the older completion. Unhandled hints remain available to polling.
- Dirty poll candidates refresh initial PR metadata. The targeted event path
  fetches once and lends its owned context to the existing pipeline; it does
  not fetch the same initial object twice. All final safety gates still run.
- Hints only break ties inside existing readiness categories. They do not move
  a blocked PR ahead of merge-ready work, skip repositories, or replace polling.
- Capacity is bounded at 4096 rows; unleased hints expire after seven days.
  Expiry removes scheduling hints, not GitHub work. Queue failure disables the
  event fast path while the authoritative polling path remains available.

Runtime entrypoints enable `AIDEVOPS_PULSE_MERGE_DIRTY_QUEUE_ENABLED` by default;
explicit `0` is the rollback switch. Sourcing merge helpers alone does not opt
in. Before the queue is present, ordinary polling creates no queue state.
Dry-run processing does not claim or acknowledge hints. The private directory
can be isolated with `AIDEVOPS_PULSE_MERGE_DIRTY_QUEUE_DIR`.

**Webhooks are optional; outbound-only polling is the default.** Follow
[optional webhook onboarding](github-webhook-onboarding.md) for Cloudflare Tunnel,
NetBird, or a public gateway with Cloudron-hosted mesh management. Missing webhook
secrets/configuration do not make the core installation incomplete. Keep polling
and its cadence unchanged during and after onboarding. A configured listener is
not proof of GitHub delivery, event coverage, or API savings; further tuning needs
separate verified evidence and scope. Configure secrets with
`aidevops secret set GITHUB_WEBHOOK_SECRET`, never in chat.

## Focused verification

```bash
python3 .agents/scripts/tests/test-gh-transport-budget.py
bash .agents/scripts/tests/test-gh-shim.sh
bash .agents/scripts/tests/test-gh-api-instrument.sh
bash .agents/scripts/tests/test-gh-wrapper-rest-fallback.sh
bash .agents/scripts/tests/test-gh-pr-checks-exact-json.sh
bash .agents/scripts/tests/test-gh-checks-wait-helper.sh
bash .agents/scripts/tests/test-gh-request-singleflight.sh
bash .agents/scripts/tests/test-pulse-issue-reconcile.sh
bash tests/test-peer-productivity-monitor.sh
bash .agents/scripts/tests/test-pulse-dispatch-dirty-worktree-marker.sh
python3 .agents/scripts/tests/test-pulse-merge-dirty-queue.py
python3 .agents/scripts/tests/test-pulse-merge-webhook-invalidation.py
bash .agents/scripts/tests/test-pulse-merge-pr-backlog-priority.sh
bash .agents/scripts/tests/test-pulse-merge-pr-json-fields.sh
bash .agents/scripts/tests/test-pulse-merge-preflight-snapshot.sh
```
