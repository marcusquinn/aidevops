<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Target C bounded integration evidence

## Scope

Target C is an overlay repository. Exact repository identity, paths, source,
commands, and raw logs remain private. This report records only aggregate
validation evidence from a disposable current downstream worktree.

## Baseline

The target had no executable overlay-to-downstream lint boundary, so there was
no valid before-runtime or before-memory profile. Adding another broad lint
pipeline would have duplicated the downstream project's authoritative engine.
The accepted outcome is therefore a reliability and coverage improvement, not
a before/after speed claim.

## Retained validation

- A clean disposable downstream received the overlay and exposed 196 changed
  source files.
- The sorted changed-source coverage digest was
  `5bf51485c50adef6a26bec261299bbeb1751f5996316966dbe4a355c7e8fed13`.
- Canonical downstream lint ran with one thread and exited 0 in 9 seconds.
- Aggregate peak RSS was 2,722,096 KiB with normal thermal state and zero
  starting swap.
- A deliberately invalid syntax fixture exited 1 with a useful file and line
  diagnostic in 6 seconds.
- A stalled-process fixture terminated its process group with status 124 in
  under 0.2 seconds.
- Three focused validator tests passed.

Dependency materialization reached its three-minute bound twice. Downloaded
state was preserved, and recovery narrowed the route to lint prerequisites and
workspace links. The original objective then completed without an unbounded
installation or broad monorepo lint run.

## Decision

Accept the bounded changed-source integration. It closes the missing validation
boundary while reusing the canonical downstream lint engine and adding no
independent broad lint pipeline. The target-local change merged only after its
terminal review, quality, and security checks passed.

## Rollback

Revert the target-local validation change. This removes the overlay validator
and its three focused fixtures without changing the downstream project's
authoritative lint pipeline.

## Confidence

Confidence is high for the changed-source boundary, fail-closed invalid case,
and process timeout. Performance comparison confidence is not applicable
because the baseline had no executable validator.
