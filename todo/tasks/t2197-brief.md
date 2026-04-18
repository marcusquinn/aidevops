<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# t2197 Brief — Shell test-harness template with set-e + local-outside-function pitfalls encoded

**Issue:** GH#19684 (marcusquinn/aidevops) — the issue body is the canonical spec for this task; this brief links the audit trail and records session origin.

## Session origin

Filed 2026-04-18 from the t2189 interactive session (PR #19682) as a framework refinement. During t2189 test-harness authoring I hit two silent-failure bash gotchas (`set -euo pipefail` killing the script before `$?` could be read; `local var=value` outside a function silently dropping the assignment under bash 5.x) that cost ~20 min each of `bash -x` debugging. A template encoding the correct patterns prevents future rediscovery.

## What / Why / How

See issue body at https://github.com/marcusquinn/aidevops/issues/19684 for:
- Target path `.agents/scripts/tests/templates/test-harness-template.sh`
- Required sections (set -uo pipefail comment, MOCK CLI STUB comment block, LOCAL KEYWORD comment block, skeleton test function with rc-capture pattern)
- Accompanying README
- Reference files (model on PR #19682's `test-pulse-merge-interactive-handover.sh` + `fixtures/mock-gh-interactive-handover.sh`)

## Acceptance criteria

Listed in the issue body; gated on shellcheck-clean + spot-check against one existing test file.

## Tier

`tier:simple` — template file creation, 2 new files, no cross-package changes, <1h estimate feasible but budget 2h for doc polish.
