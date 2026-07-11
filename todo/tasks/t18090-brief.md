<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->
# t18090: Enforce portable whole-process worker network egress

## Pre-flight

- [x] Memory recall: `Codex harness reassessment` → command-level policy is not equivalent to process containment
- [x] Discovery pass: issue #27030 implements recognized direct-client policy; no portable whole-process backend exists
- [x] File refs verified: worker launch, sandbox, network tier, and runtime adapter paths exist at current HEAD
- [x] Tier: `tier:thinking` — cross-platform security architecture and compatibility design required
- [x] Seeded draft PR decision recorded: skipped — backend choice requires measured design and threat-model validation

## Origin

- **Created:** 2026-07-11
- **Session:** OpenCode interactive, issue #27030
- **Created by:** ai-interactive
- **Parent task:** none
- **Blocked by:** none; builds on #27030 command-policy contracts
- **Conversation context:** Final security audit proved that arbitrary interpreter scripts and custom binaries can bypass command-level domain classification.

## What

Add a portable, enforcing worker-egress boundary that applies to the whole worker process tree, including interpreters, scripts, custom binaries, MCP subprocesses, and direct sockets. Reuse `network-tiers.conf` as policy input and expose one runtime-neutral backend contract; do not add another domain authority.

## Why

Command parsing can safely classify recognized clients but cannot prove the behavior of arbitrary programs. Treating command checks as containment creates false confidence. A lower-layer proxy, container/network namespace, firewall, or equivalent backend is required to enforce the intended worker security boundary independently of model behavior.

## Tier

**Selected tier:** `tier:thinking`

**Tier rationale:** Requires cross-platform threat modelling, backend selection, process-tree integration, fallback semantics, and runtime verification.

## Seeded Draft PR

- **Decision:** Skipped
- **Rationale:** No single backend is yet proven portable across supported macOS/Linux/Windows worker modes.
- **Status:** not-created
- **Freshness evidence:** #27030 adversarial security audit and current worker/sandbox source inspection
- **Verification run:** command-level bypass probes only; whole-process backend unimplemented
- **Stale-assumption warning:** re-check runtime-native sandbox/proxy capabilities before building an aidevops-owned daemon.

## How (Approach)

### Files to Modify

- `EDIT: .agents/scripts/sandbox-exec-helper.sh` — select and verify an enforcing backend rather than silently degrading.
- `EDIT: .agents/scripts/headless-runtime-helper.sh` and worker launch paths — bind the complete runtime process tree to the selected egress policy.
- `EDIT: .agents/scripts/network-tier-helper.sh` — remain the sole domain policy authority and provide backend-ready normalized policy output.
- `NEW/EDIT: focused backend and adversarial tests` — prove interpreters/custom binaries cannot bypass Tier 5 restrictions.

### Implementation Steps

1. Evaluate runtime-native proxy/container/firewall support and choose the smallest backend abstraction that works across supported platforms or fails closed when required.
2. Translate existing network tiers into backend policy without duplicating domain lists.
3. Bind the worker and all descendants before model/tool execution starts; reserve cleanup capacity and remove policy state on exit.
4. Preserve provider/GitHub connectivity through explicit allow rules while denying private/local and Tier 5 destinations according to configured posture.
5. Keep recognized-client command checks as defence-in-depth telemetry, not the containment authority.

### Verification

```bash
bash .agents/scripts/tests/test-worker-network-egress.sh
bash .agents/scripts/tests/test-sandbox-command-policy.sh
shellcheck <changed-shell-files>
.agents/scripts/linters-local.sh
```

## Acceptance

- [ ] A worker interpreter or custom binary cannot connect directly to a Tier 5 destination outside the enforcing backend.
- [ ] Worker descendants and MCP subprocesses inherit the same egress boundary.
- [ ] Missing required backend support fails closed with actionable evidence; it never silently reports containment.
- [ ] Existing `network-tiers.conf` and user overrides remain the only domain-policy authority.
- [ ] Provider, GitHub, and explicitly allowed project connectivity continue to work in runtime tests.
- [ ] Tests and lint pass on supported platform fixtures.

## Context and Constraints

- Prefer host/runtime capabilities over an aidevops-owned proxy when they provide equivalent enforcement and observability.
- Do not use Codex-specific APIs, terminology, or workflow assumptions.
- Avoid TLS interception unless the threat model and certificate lifecycle justify it; destination enforcement is the minimum requirement.
- Interactive sessions remain a distinct posture unless explicitly placed into worker containment.
