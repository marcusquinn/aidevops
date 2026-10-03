<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2026 Marcus Quinn -->

# Backlog observation evidence — 2026-10-03

## Compaction and usage: #32829 / #32820

- The earlier default-DB OC1 query in `backlog-session-review.sql` returned
  12 recent summaries, all 12 with the five host headings, 11 with explicit
  continuation, 11 with the specifically bold status spelling and all 12 with a
  next-move status. Bold spelling alone is not a semantic quality verdict.
- First resumed tools are Bash (4), TodoWrite (4), bounded operation (2), Read
  (1), and pre-edit check (1). Tools resumed; these counts alone do not prove an
  exact recorded command or semantic preservation of every earlier aim.
- Repeated the warm-break SQL specified by #32793 for Anthropic requests since
  September 26. Version 3.38.0 has 5371 requests, 25 sessions, zero warm breaks
  and 97.7% token-weighted cache hits. Version 3.37.15 has 2334 requests,
  16 sessions, 12 breaks and 96.9% hits. Request-family/task/model mix and
  sampling differ; no causal savings claim follows from these aggregates.
- Current 3.38.0 compaction sample is 54 requests, mean 1886.6 output tokens,
  mean locally estimated cost $0.0073. All use the cheaper configured summarizer;
  model mix differs from the old Opus baseline. Costs are not provider invoices.
- Correlating compaction with the immediately preceding regular request proves
  the relevant trigger is near 240K: 3.38.0 mean 242270 usable input tokens,
  range 235031–278688; 3.37.18 Opus mean 240246; 3.37.22 Opus mean 240157 and
  Sonnet mean 242398. The summarizer's own 64K mean input is not the trigger size.
- Seven-day canonical worker telemetry confirms real Anthropic and OpenAI use,
  including Haiku, Sonnet, Opus and multiple OpenAI models. It establishes live
  dispatch, not strict recent index alternation or current routing-policy effect.
- Keep the 400K/500K token advisories as opt-out/larger-target protection: the
  default 240K trigger already fires first. No observed defect justifies adding
  lower-threshold advisory noise or changing the existing tested contract.

### Current-session semantic review

The active project-isolated OC1 DB contains seven real auto-compactions in this
mission on October 3, from 03:17 to 08:45 UTC. The four newest summaries retain
both quoted aims: resolve safely solvable backlog work and publish the authorized
release; continue while safe next steps remain. Both retain `active` status.
No dropped aim was found in this four-summary spot check; this is not a verdict
on every session or an outcome-quality benchmark.

The earlier sample counted seven first resumed Bash Git revalidations. A later
session-scoped query finds nine of nine first Bash actions starting with
`git status --short --branch`, but only one complete first Bash command occurs
verbatim in its corresponding summary. This does not identify the earlier 08:45
example or prove literal first-tool compliance. All nine actual first tools are
housekeeping: TodoWrite (six), memory recall (two), bounded-operation status (one).
Next-action precedence is under investigation in #33470; later Git revalidation
must not be presented as execution of the recorded command first. The reusable
SQL bounds its samples and requires the active project DB.

The refreshed 12-summary bounded sample has all five headings in 12/12 and
explicit continuation in 12/12; 11/12 use the specifically bold status spelling.
Its first tools are TodoWrite (5), Bash (3), bounded operation (2), Memory (1)
and Read (1). Seven first Bash actions revalidate Git. These are aggregate
format/action counts, separate from the four-summary semantic spot check.

### Model-matched cost and compaction frequency

Read-only request data since September 26, with no recorded parent session, is
grouped by session/version slice and its most-used non-compaction model. Costs
and compactions include all models in that slice, including cheaper summarizers.
This avoids attributing only Opus summarizer rows to Opus-led sessions.

| Version | Dominant model | Slices | Requests | Compactions | Estimated $/slice | Estimated $/request | Compactions/100 requests |
|---|---|---:|---:|---:|---:|---:|---:|
| 3.37.15 | Opus 5.5 | 6 | 1501 | 4 | 29.0002 | 0.1159 | 0.266 |
| 3.37.18 | Opus 5.5 | 3 | 425 | 2 | 6.5634 | 0.0463 | 0.471 |
| 3.37.22 | Opus 5.5 | 7 | 2549 | 22 | 22.9833 | 0.0631 | 0.863 |
| 3.38.0 | Opus 5.5 | 20 | 5396 | 32 | 15.4646 | 0.0573 | 0.593 |

Sonnet is not adequately matched: the baseline has three Sonnet 5 slices and
77 requests, while later observed slices are Sonnet 5.5 (five/159 in 3.37.22;
two/four in 3.38.0). Do not compare those as a controlled same-model trial.
The Opus observations show lower locally estimated cost per request and more
frequent compaction, not proof of the replay's projected savings. Slice duration,
task mix, routing, summarizer model and request mix differ; a slice is not a
complete session, list-price estimates are not invoices, and unrecorded parent
metadata cannot establish a purely interactive cohort.

### Routing decision and review disposition

The round-robin observation was superseded by the maintainer's October 1 decision
in #32539: end the A/B early, use OpenAI-primary with `round_robin: false`, and
retain Anthropic as availability fallback. #33342 / #33347 delivered that policy.
Live mixed-provider dispatch is verified; continued index alternation is neither
the current requirement nor grounds for changing the user's routing again.

The observational checks for #32820 are complete with the limitations above. Retain
the advisory thresholds unchanged and make no causal saving claim. #32829 remains
open while the first-next-action and V2 cache findings are dispositioned; a marker
response or completed compaction alone is not a cache-success claim.

### V2 probe evidence

The marker-only V2 2.0.3 requests returned the marker but do not establish
compaction. Manual compaction failed with `Agent not found: Build+`; the private
API agent list returned no registered agents. A separate owned service probe
returned HTTP 401 at health and was stopped without changing authentication.
The installed V2 schema uses `agents`, `system` and permission-rule arrays,
not V1's `agent`, `prompt` and string `permission`. Both deployed and source
framework profile loaders independently return 16 primaries including Build+;
that source result alone does not establish native private-server registration.
Both the inline-config and explicit-config-file private-server probes still
return zero native agents; their registration preconditions fail before any
additional model request. They do not test compaction or prove a framework
source defect. Preserve the failed evidence and establish working native agent
registration plus retained framework hooks before any positive cache claim.

### Completed V2 automatic compaction, later evidence

A subsequently validated isolated V2 config registered a deny-all primary agent
and retained the framework plugin. A real 2.0.3 request then completed compaction
with `reason: auto`, status `completed`, and the expected public marker in the
summary. The resumed request returned only that marker. This supersedes the failed
registration probes above as compaction/resumption evidence; it is a deliberately
padded diagnostic, not a broad quality or default-trigger benchmark.

Provider usage for the compaction request: input 3, output 242, cache read 0,
cache write 135,903. The immediately preceding regular request wrote 185,490
cache tokens; resumption wrote 62,991 with zero reads. Earlier warm requests in
the same diagnostic session read 70,358 and 125,407 cache tokens. Observability
independently identifies runtime 2.0.3 and adapter `opencode-v2@3.38.0`; the native
export supplies the compaction-request usage. No cache-success or causal-fix
claim follows from these values. #33471 owns investigation/repair of the context
versus compaction transform/prefix boundary, with live acceptance retained by
the parent. Its worker-ready brief is `backlog-v2-cache-brief.md`.

## Verified external/manual prerequisites

- #33278: `opencode models anthropic` currently exposes Haiku 4.5 but no Haiku
  5.5 identifier. Resume adoption only when supported availability is verified;
  do not fabricate a model or change routing to an unavailable ID.
- #32523: upstream issue anomalyco/opencode#51430 is still open, with only bot
  comments; PR #51431 is still draft, unmerged, without reviews at head
  `4bffa9ba93bece430c3c329bf9fa3991bdf59896`. A maintainer response/merge or a
  released capability is the existing wake condition, not more polling.
- #32273: executable Firecracker acceptance needs an operator-selected,
  approved Linux KVM host and billing/security scope. The known local OrbStack
  environment lacks `/dev/kvm`; no provisioning or executable flag is authorized.
- #32446: see `backlog-stagehand-hold.md`; only offline scope is merged.

## Dependency alert 133

High GHSA-ch52-4w7c-c8xp remains open, affecting `http-cache-semantics <=4.2.0`;
GitHub lists no patched version. Advisory describes client `max-stale` retrieving
security-zeroed shared-cache entries and another user's Set-Cookie credentials.
The inspected `make-fetch-happen/lib/cache/policy.js` hard-codes `shared: false`
at both CacheSemantics constructors and refuses caching without a cache path or
with `no-store`. This inspected private npm-fetch path does not establish the
advisory's shared-server exposure; it is not proof that every consumer is safe.
Do not guess a version override, dismiss the alert, or claim the vulnerability
fixed. Reassess consumer paths and upstream patch availability before remediation.

Revalidation still lists no first patched version. The installed dependency path
is `@opencode/plugin@2.0.3 -> @opencode/util@2.0.3 -> @npmcli/arborist@9.4.0 ->
npm-registry-fetch@19.1.1 -> make-fetch-happen@15.0.6 -> http-cache-semantics@4.2.0`.
This inspected graph and its private-cache policy narrow the exposure assessment;
the high alert remains open, undismissed and unfixed.

### Dependency remediation, later verified disposition

Issue #33467 / PR #33469 removed the unnecessary V2 SDK identity import and its npm-fetch
graph while retaining the V1 SDK/schema dependency. Merged as
`84ce13e94dfb43f8757f14b088897c8693937bfd`; all 46 remaining name/version pairs
already existed in the original lockfile. Frozen installation and npm audit
report zero vulnerabilities. Twenty-seven V2 adapter/TUI tests, the V2 setup
suite, 47 atomic deployment checks, scoped lint and the isolated native V2
candidate request pass. Independent bounded defect review found no introduced
P0 at the changed boundaries. GitHub subsequently reports alert 133 as `fixed`,
and the issue is closed. The historical exposure investigation above is not a
patch or universal safety assertion; removal is the verified remediation.
