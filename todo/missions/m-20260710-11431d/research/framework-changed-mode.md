<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Framework Changed-Mode Result

**Collected:** 2026-07-10
**Task:** t18072 / issue #26919
**Decision:** accepted

## Coverage

The normalized inventory now includes four sources exactly once: branch changes, unstaged changes, staged changes, and untracked non-ignored files. Ignored/generated content and `_archive/` paths remain excluded.

Focused fixtures confirmed:

- tracked, staged, and untracked shell files are present;
- ignored and archived files are absent;
- duplicate inventory entries are zero;
- untracked content changes alter the gate cache fingerprint;
- full local shell discovery returns each setup module once.

This closes the confirmed gap where a new non-ignored file was absent from changed-mode quality and secret checks before staging.

## Traversal Decision

Before this change, every eligible cached gate independently repeated up to three Git changed-file traversals. Changed mode now performs one initial four-source inventory build, adding the required untracked-file query, and every later gate-key lookup performs zero Git discovery calls.

The focused counter fixture observed zero repeat Git scans after inventory preparation. This is a 100% reduction in repeated per-gate changed-file traversal, exceeding the mission's 25% duplicate-traversal threshold. Full shell discovery also removes a redundant nested `setup/modules` traversal already covered by the parent `.agents/scripts` scan.

## Timeout Decision

A broad gate timeout now returns status 124 in both normal and strict modes, is never cached, and emits an explicit incomplete-result diagnostic. The previous advisory path converted status 124 to success, allowing an all-passed summary despite incomplete work.

## Bounded Post-Change Profile

| Metric | Result |
|--------|--------|
| Outcome | success |
| Wall time | 19s |
| Approx. CPU | 2.002s |
| Peak RSS | 115.3 MiB |
| Average RSS | 39.4 MiB |
| Peak processes | 11 |
| Thermal state | normal |
| Swap at start | 0 MiB |
| Safety stop | none |
| Coverage digest | `6c1a52953e197b93ef63d91e2e980a88e70042723816e29a26cbb86eaad06c2d` |

Wall time is not compared directly with F1 because the changed-file sets differ. The accepted criterion is the measured 100% reduction in repeated discovery with expanded coverage; peak RSS remained within the mission's 10% non-target regression tolerance.

## Verification

- Cache, fingerprint, and timeout tests: 5 passed.
- Untracked coverage and deduplication tests: 3 passed.
- Changed-mode orchestration tests: 8 passed.
- Ratchet timeout tests: 2 passed.
- ShellCheck, shfmt, Secretlint, portability, complexity, and the bounded changed-mode suite passed.
