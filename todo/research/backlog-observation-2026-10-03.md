<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2026 Marcus Quinn -->

# Backlog observation evidence — 2026-10-03

## Compaction and usage: #32829 / #32820

- Read-only current OC1 aggregate query in `backlog-session-review.sql` returns
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

Remaining review criteria: inspect at least one real summary/resumed-action pair
semantically; report model-matched session/request cost and compaction-frequency
comparison with limitations; verify real V2 compaction cache read/write. Current
V2 2.0.3 provenance identifies ordinary usage but contains no qualifying
compaction/cache observation. These remain executable work, not presumed external
blockers, and both manual review issues stay open pending disposition.

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
