<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Lint Resource Baseline

**Collected:** 2026-07-10
**Task:** t18071 / issue #26914
**Scope:** aggregate local evidence and one bounded framework changed-mode baseline
**Privacy:** raw session records, diagnostic reports, commands, paths, and private target identities remained local and are not reproduced here.

## Executive Finding

The reported reboot is confirmed as a kernel panic caused by kernel zone-map exhaustion with a likely leak in `data.kalloc.1024` at approximately 20 GiB. Lint causation is **unproven**: the panic snapshot contained one low-resource `turbo` process, no named ShellCheck/ESLint/Secretlint/Markdownlint process, and no OpenCode session event or linter tool invocation in the bounded two-hour pre-panic window.

The evidence supports reducing aggregate concurrency and retaining hard process-tree cleanup as precautions. It does not support claiming that a linter caused the kernel leak.

## Evidence Matrix

| Evidence | Aggregate observation | Classification | Confidence |
|----------|-----------------------|----------------|------------|
| System diagnostic preceding the reboot | Kernel panic reported zone-map exhaustion while allocating from `data.kalloc.1024`, with the panic text identifying a likely kernel-zone memory leak around 20 GiB. | confirmed | high |
| Panic process snapshot | 15 OpenCode processes used 16,408 MiB aggregate RSS; the largest used 1,580 MiB. One named `turbo` process used 44 MiB RSS and about 1.3 CPU seconds. No named ShellCheck, ESLint, Secretlint, Markdownlint, shfmt, or pnpm process appeared. | confirmed context, not causation | high |
| Recent OpenCode records | No session part, linter tool event, or linter command was recorded in the bounded two-hour window before the panic. Older user-authored linter/resource discussion concerned CI heartbeat diagnostics, not a local laptop crash. | absence of corroboration | medium |
| Current system snapshot | Available memory was 90–91%, swap use was 0 MiB, thermal/performance state was normal, and the process guard reported no violations. | confirmed point-in-time health | high |
| Changed-file inventory | Unstaged changed mode previously scanned 1 tracked file; representing the same work in a temporary index scanned all 9 intended files. | confirmed coverage gap | high |
| Timeout fixture | The generic sandbox process-group timeout alone allowed a nested background group to remain alive. The profiler's retained recent tree snapshot terminated it on both timeout and safety stop. | confirmed cleanup gap and mitigation | high |

## Bounded Framework Profiles

All profiles were serialized, cache-disabled, sampled every two seconds, capped at five minutes, and used the same coverage digest: `a9ac43760de54902d9bafcb56831b53a50de011c59531c86579e5e39ad44ceb9`.

| Profile | Result | Wall | Approx. CPU | Peak RSS | Average RSS | Peak processes | Safety stop |
|---------|--------|------|-------------|----------|-------------|----------------|-------------|
| Initial baseline | quality failure: repeated literals | 45s | 5.616s | 101.8 MiB | 43.8 MiB | 11 | none |
| First verification | quality failure: function size | 44s | 6.056s | 143.7 MiB | 44.6 MiB | 11 | none |
| Post-fix verification | success | 38s | 5.446s | 106.8 MiB | 47.7 MiB | 11 | none |

The post-fix run was 15.6% faster than the initial run, but this is a single short sample across changing code and is therefore **inconclusive**, not an accepted performance improvement. Peak process count remained stable at 11. No run increased swap or encountered thermal/memory pressure.

## Guard Verification

- Resource sampler tests: 3 passed.
- Lint profiler tests: 10 passed.
- Normal completion emits only aggregate JSON.
- Coverage manifests are hashed; paths and command arguments are not emitted.
- Concurrent benchmark attempts fail before executing the second command.
- Lock initialization waits for the owner PID instead of deleting a newly created lock.
- Missing option values fail with explicit diagnostics instead of abrupt shell errors.
- Snapshot cleanup state is cleared after first use to avoid repeated PID termination.
- Timeout and simulated memory-pressure stops leave no tested descendant running.
- ShellCheck, shfmt, Secretlint, Markdown checks, portability checks, and the bounded changed-mode suite passed after refactoring.

## Decisions

1. **Retain the bounded profiler:** accepted as a safety and evidence tool, not as proof of a lint performance optimisation.
2. **Do not attribute the panic to linting:** evidence identifies a kernel-zone leak, while linter evidence at the panic boundary is absent or negligible.
3. **Keep benchmark concurrency at one:** aggregate OpenCode memory in the panic snapshot makes additional local parallelism an unnecessary risk even though it is not proven causal.
4. **Proceed to F2–F4 independently:** each target still requires its own unchanged-coverage digest and bounded before/after decision.
5. **Track generic sandbox cleanup separately:** F1 adds profiler defence-in-depth but does not change the broader sandbox contract.

## Stop Conditions for Later Features

Stop the active route when available memory falls below 15%, swap grows by more
than 1 GiB, thermal or performance pressure is reported, the profile times out,
descendants survive cleanup, or instability is observed. Record that route as
inconclusive and do not repeat it unchanged. Preserve the evidence and remaining
acceptance criteria, then resume the objective through a smaller shard, restored
prerequisite, or safer execution profile.
