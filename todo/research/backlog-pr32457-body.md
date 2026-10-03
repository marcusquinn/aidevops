<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2026 Marcus Quinn -->

For #32446

## Summary

Deliver only the safe offline NanoGPT Stagehand fixture harness permitted by the
issue's fail-closed alternative. This PR does not complete the live-probe objective
and must not close the issue. Live transport remains unconditionally disabled.

## Files and reference pattern

- `.agents/scripts/stagehand-v4-helper.sh`: opt-in offline CLI dispatch; unchanged
  existing OpenAI example and isolated Stagehand v4.1.0 ownership.
- `.agents/tools/browser/stagehand-v4-nanogpt-probe.mjs.txt`: pure fixture responses,
  bounded counters and synthetic accounting; no SDK, HTTP or browser transport.
- `.agents/scripts/tests/test-stagehand-v4-route.sh`: existing route/fixture suite,
  including live refusal before and after installed-version fixtures.
- `.agents/tools/browser/browser-benchmark.md`: invocation and explicit distinction
  between fixtures, historical measurements and unverified live behavior.

## Runtime Testing

Runtime-verified for the delivered offline scope: existing route suite, helper
`help` and installed `status`, ShellCheck, bash syntax and changed-file lint pass.
No credential, paid request, authenticated browser profile or live SDK extraction
is represented as verified. Source review confirms the live failure receipt and
exit 1 are unconditional, with no paid fallback.

Independent production review at head `9702ca3a77328f8335678852801623988b55d434`,
bundle `c9916de02ac27ca574a36e36ccbb4582554a4c1c2bd6718657b1d1df03b89d90`,
found no introduced blocker. Follow-up head `6f63469108` changes only the placement
of the existing uninstalled-route assertion; the production bytes are unchanged
and the affected suite and ShellCheck pass again. Optional fuller receipt-field
assertions are a nonblocking coverage recommendation, not an observed defect.

## Remaining live acceptance and wake condition

The positive live criterion remains open in #32446. Historical spending consent
does not authorize another paid experiment. Resume only with fresh operator-owned
billing/data authority and a verified pre-inference hard bound that accounts for
current model pricing, retries and provider overhead. Then verify installed SDK
exports, implement the bounded transport, and measure fresh isolated public-page
extraction, deterministic/model timings, actual provider usage and cleanup.
Neither a timeout nor a post-call cost receipt is a hard USD ceiling. Credentials
must stay in secure storage, not in issue/PR/chat content.
