<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# t2227 Brief — gh_create_pr and gh_create_issue auto-append signature footer

**Issue:** GH#19748 (marcusquinn/aidevops — filed alongside this brief).

## Session origin

Discovered 2026-04-18 during PR #19712 session and reinforced across multiple sessions. Every `gh` body composer must call `gh-signature-helper.sh footer` manually. Forgetting produces unsigned issues/PRs — a recurring incident class (several memory-hit lessons on "hallucinated footer" / "forgot signature"). The wrappers in `shared-constants.sh` are the natural choke point: they already know the PR/issue boundary.

## What / Why / How

See issue body for:

- Exact oldString/newString for `gh_create_pr` and `gh_create_issue` functions in `shared-constants.sh`
- Marker-based detection: presence of `<!-- aidevops:sig -->` in body → no-op; absence → append footer
- Handling of `--body-file` (read, append, pass as temp) vs `--body` (direct concat)

## Acceptance criteria

Listed in issue body. Core assertions:

1. `gh_create_pr` without existing footer auto-appends.
2. `gh_create_pr` with existing footer passes through unchanged (no double-footer).
3. `gh_create_issue` symmetric behaviour.
4. Existing callers that manually call the footer helper continue to work (marker detection).
5. Unit test added under `.agents/scripts/tests/`.

## Tier

`tier:simple` — two wrapper functions, verbatim oldString/newString provided, marker-based conditional is straightforward. Test harness pattern exists.
