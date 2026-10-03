<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2026 Marcus Quinn -->

The permitted offline alternative is delivered by merged PR #32457,
`ac0bd52d58ad1394c914570402bb5f99944ae133`. It has a non-closing reference:
issue #32446 stays open and blocked because its positive live criterion is not met.

Existing route fixtures, real helper help/status, ShellCheck, scoped lint,
independent production review and exact-head required/review gates pass for the
offline scope. Live dispatch is unconditionally disabled; synthetic usage,
prices and null timing fields are not a real extraction benchmark.

**Manual safety prerequisite:** the operator must authorize a new bounded
public-page/provider experiment and supply billing/data scope via the supported
secure configuration path. Historical consent is not recurring consent.
Independently, the transport must prove a pre-inference hard USD ceiling that
accounts for current pricing, retries and overhead; timeouts and post-call
receipts do not provide that ceiling. Do not unlock live execution merely
because offline tests pass or a credential is present.

**When ready:** verify installed Stagehand 4.1.0/OpenCode SDK exports, implement
the bounded callback in `.agents/tools/browser/stagehand-v4-nanogpt-probe.mjs.txt`
through the existing helper route, exercise a fresh isolated public page, and
verify actual deterministic/model timings, provider usage and browser/server
cleanup. Keep existing OpenAI examples, deterministic Playwright defaults and
authenticated-profile boundaries unchanged. No secrets belong in chat or GitHub.
