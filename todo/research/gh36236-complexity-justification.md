<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2026 Marcus Quinn -->

## Summary

For #36233: move the capability/bounded-recovery and fleet/discovery test
groups into sourced modules. The orchestrator drops from 2488 to 1609 lines;
test bodies and `main()` order are unchanged.

## Files Changed

- `.agents/scripts/tests/test-terminal-blocker-circuit.sh`
- `.agents/scripts/tests/test-terminal-blocker-circuit-capability.sh`
- `.agents/scripts/tests/test-terminal-blocker-circuit-discovery.sh`
- `todo/research/gh36236-complexity-justification.md` records the CI repair
  evidence and corrected PR justification; no runtime or workflow changes.

## Complexity Bump Justification

The original inline justification was not a Markdown section and supplied
neither a file:line reference nor a numeric scanner measurement. The validator
at `.github/workflows/complexity-bump-justification-check.yml:48` requires all
three. This document supplies the corrected PR body for #36236.

CI compared base `6468167` with head `5b45576` and reported:

- Function complexity: base=0, head=0, new=0 functions over 100 lines.
- Nesting depth: base=0, head=0, new=0 files exceeding depth 8.
- Bash 3.2 compatibility: base=0, head=0, new=0 incompatible constructs.
- Markdown file size: base=0, head=0, new=0 oversized files.
- Qlty smells: base=34, head=34, new=0 smells.

Evidence is recorded in the existing CI comments on
https://github.com/marcusquinn/aidevops/pull/36236.
The AST scanner already resolves historical nesting false positives, as
documented at `.agents/reference/large-file-split.md:181`. No complexity
increase needs acceptance, and no complexity override should remain enabled.
The label may be applied to exercise the corrected justification validator,
then removed after validation; regression checks remain authoritative.

## Runtime Testing

- Risk level: low; this repair changes PR metadata and documentation only.
- Existing head CI passed complexity analysis, ShellCheck on Ubuntu and macOS,
  Bash 3.2 compatibility, and framework validation.
- Focused repair verification: apply the three validator expressions from
  `.github/workflows/complexity-bump-justification-check.yml:48` to this body,
  then verify the GitHub justification check passes with the corrected body.

Resolves #36233
