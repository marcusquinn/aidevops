<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# t3589 Brief — worker-origin propagation through sandboxed headless launch

**Issue:** GH#23520

## Session origin

Reviewed and approved on 2026-05-14 after a pulse-dispatched worker PR was misclassified as interactive. The approved issue is cryptographically signed and locked; keep this scope to worker-origin propagation and regression coverage. Split PID accounting into a separate task if it reappears.

## What

Fix the handoff gap where pulse establishes worker identity with legacy variables, but sandboxed OpenCode execution starts with `env -i` and drops those markers before the GitHub signature and PR wrapper layers run.

Implement the canonical contract:

- `AIDEVOPS_SESSION_ORIGIN=worker`
- `AIDEVOPS_HEADLESS=true`

Do not broaden sandbox passthrough with generic `HEADLESS`/`FULL_LOOP_HEADLESS` unless a compatibility test proves it is still required.

## Why

- Worker PR footers must say the work was done as a headless worker, not with the user in an interactive session.
- Worker PR creation must not inherit the interactive default-draft policy just because sandbox filtering lost identity.
- Origin labels and merge/reconcile automation depend on a stable worker-origin signal.
- `AIDEVOPS_*` already fits the sandbox passthrough contract, so it is safer than adding broad generic env names.

## Files to inspect and likely edit

- `.agents/scripts/pulse-dispatch-worker-launch.sh` — set canonical worker-origin variables alongside existing worker launch markers.
- `.agents/scripts/headless-runtime-lib.sh` / `.agents/scripts/headless-runtime-helper.sh` — ensure sandboxed OpenCode receives canonical `AIDEVOPS_*` worker markers.
- `.agents/scripts/gh-signature-helper-session.sh` — make session detection trust `AIDEVOPS_SESSION_ORIGIN=worker` consistently.
- `.agents/scripts/shared-gh-wrappers-session.sh` and `.agents/scripts/shared-gh-wrappers-create.sh` — verify existing origin and draft-policy behavior under canonical worker env.
- `.agents/scripts/sandbox-exec-helper.sh` — verify `AIDEVOPS_*` passthrough remains narrow and sufficient.
- `.agents/scripts/tests/` — add or extend focused shell tests.

## Reference pattern

Use the existing canonical-origin pattern in `shared-gh-wrappers-session.sh` as the source of truth. Prefer one canonical detector over divergent one-off checks.

## Acceptance criteria

1. A pulse/headless worker launch exports `AIDEVOPS_SESSION_ORIGIN=worker` and `AIDEVOPS_HEADLESS=true` before sandbox execution.
2. Sandbox passthrough retains those canonical variables without adding broad generic passthrough.
3. Signature session detection classifies `AIDEVOPS_SESSION_ORIGIN=worker` as worker even when legacy `HEADLESS`/`FULL_LOOP_HEADLESS` markers are absent.
4. PR wrapper draft policy continues to default interactive PRs to draft, while worker-origin PRs do not become draft solely because identity was lost.
5. Regression tests cover sandbox passthrough, signature footer/session detection, and PR wrapper readiness/default-draft behavior.
6. PID accounting concerns from GH#23520 are not included unless a test directly exposes the same root cause.

## Verification

Run focused tests first:

```bash
.agents/scripts/tests/test-sandbox-passthrough-otel.sh
.agents/scripts/tests/test-gh-signature-session-origin.sh
.agents/scripts/tests/test-origin-label-mutex-create.sh
```

Then run `shellcheck` on edited shell files. If broad local lint is affordable, finish with:

```bash
.agents/scripts/linters-local.sh
```

## Tier

`tier:standard` — cross-file shell behavior with sandbox/runtime/signature coordination, but the desired contract is approved and constrained.

## Related

- GH#23520 approved root-cause review comment: worker markers are stripped by sandbox `env -i`; canonical `AIDEVOPS_*` propagation is the preferred fix.
- Keep private repo names, private issue numbers, PR numbers, local usernames, and local paths out of public comments and PR bodies.
