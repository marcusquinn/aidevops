<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# t2742 — Fix string-literal ratchet regex false positive on adjacent quoted shell arguments

**Canonical brief lives in the GitHub issue body (worker-ready per t2417 heuristic):**

- Issue: [marcusquinn/aidevops#20478](https://github.com/marcusquinn/aidevops/issues/20478)

This stub exists because the issue body meets the t2417 worker-ready threshold (7+ heading signals: Session Origin, What, Why, How, Acceptance, Context, Tier checklist, Routing). Duplicating content here would create the collision surface described in GH#20015. Read the issue body, not this file.

## Quick reference (for grep / backfill)

- **Task ID**: t2742
- **Issue**: GH#20478
- **Tier**: `tier:standard`
- **Origin**: `origin:interactive` (filed by maintainer during t2738 interactive session)
- **Files**: `.agents/scripts/pre-commit-hook.sh`, `.agents/scripts/tests/test-string-literal-ratchet.sh`
- **Precedent**: Follow-up to #19739 (t2230, closed) which converted validators to ratchet-style but did not fix the underlying regex logic
- **Cross-platform**: Must work on macOS (BSD sed/grep, bash 3.2) + Linux (GNU sed/grep, bash 4+) + Alpine/BusyBox — POSIX ERE only
