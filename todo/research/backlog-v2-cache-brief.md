<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2026 Marcus Quinn -->

# OpenCode V2 compaction cache boundary

## Summary

The manual #32829 review completed a real automatic compaction on OpenCode V2
2.0.3 with the framework adapter loaded. The compaction request reported zero
cache reads and 135,903 cache writes; the resumed request returned the expected
public marker. A regular request immediately preceding compaction wrote 185,490
cache tokens. Earlier warm requests in the same diagnostic session successfully
read 70,358 and 125,407 cache tokens. The exact cause of the compaction miss is
not yet established; do not claim that source inspection alone proves causality.

## Scope and ownership

- Modify `.agents/plugins/opencode-aidevops/v2.mjs` and its existing
  `tests/test-opencode-v2-adapter.mjs` only.
- Reference the context hook around lines 410-425 and compaction hook around
  lines 426-430. Context applies system/message transformations; compaction
  currently appends operational guidance as another system part without those
  transformations.
- Keep `.agents/plugins/opencode-aidevops/compaction.mjs` unchanged; a separate
  follow-up owns summary-rule guidance there.
- Preserve the native descriptor remediation in PR #33469, merged as
  `84ce13e94dfb43f8757f14b088897c8693937bfd`.
- Parent owns integration, independent review, live provider verification,
  merge and release. Deliver a draft PR; do not merge or publish.

## How

Verify the released native callback/event contract before changing placement.
If the framework context/compaction divergence causes the miss, share the same
transform path and deliver compaction-only guidance after the stable cached
prefix, without replacing the host template, losing historical messages or
promoting operational data to trusted instructions. Prefer an existing trailing
message seam rather than guessing undocumented cache-control fields. Preserve
the context path, message/image guards, remote-conversation scope and teardown.
If the miss is imposed upstream, prove that boundary rather than claiming a fix.

## Verification

- Use the existing V2 adapter/TUI/setup suites and changed-file lint.
- Add focused assertions only where needed to prove shared-prefix behavior and
  intact message/guidance placement using the existing harness.
- Parent will repeat an isolated warm V2 session through actual automatic
  compaction, comparing provider cache read/write values and prefix invariants
  and checking marker/aim preservation. Offline counts alone are not delivery.
- A verified upstream blocker is an acceptable investigation disposition, with
  primary contract evidence and an exact wake condition; it is not a cache fix.

## Safety

No new SDK dependency, guessed override, public credentials/paths, global config
change, permission broadening, new test infrastructure or paid Stagehand call.
Do not run provider experiments from the worker; parent controls that normal
runtime acceptance path. No savings claim without paired evidence. Ref #32829.
