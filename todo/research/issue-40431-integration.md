<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2026 Marcus Quinn -->

# GH#40431 integration recovery

Preserve PR #40432 and diagnostic commit `d225cfd622`.

## Files Scope

- `.opencode/lib/ai-research-runtime.ts`
- `.agents/scripts/full-loop-helper-commit-validators.sh`
- `.agents/scripts/tests/test-full-loop-project-validators-shell-only.sh`
- `todo/research/issue-40431-integration.md`

The live issue remains open and assigned to this worker. Collision discovery
found no competing PR or claim for the validator. The canonical issue scope was
corrected and re-read before implementation. No explicit hard boundary exists.

The validator's nearest-manifest lookup stops at an ignored, runtime-generated
OpenCode dependency manifest without check scripts instead of reaching the root
package's typecheck. Ignore Git-ignored generated manifests during this lookup;
retain declared workspace checks, check-only nested packages, and failure gates.
Add focused coverage to the existing validator suite, not a new harness.

Verification: ShellCheck on changed shell files; the existing
`test-full-loop-project-validators-shell-only.sh` suite; existing ai-research
tests; `commit-and-pr` and guarded merge using the committed helper.
The root typecheck remains subject to its existing CI coverage when unavailable
locally. No auth behavior, permissions, trust gates, hook exceptions, or release
authority changes are included.
