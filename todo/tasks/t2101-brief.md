<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->
# t2101: Widen ratchet-down dedup to match PRs merged within last 24h

## Origin

- **Created:** 2026-04-15
- **Session:** opencode:interactive
- **Created by:** marcusquinn (ai-interactive)
- **Parent task:** t2100 / #19035
- **Conversation context:** Fix 1 of the #19024 post-mortem. The t2089 keyword-search fix resolved one half of the ratchet-down dedup bug; this resolves the other half (window scoped to `--state open` only).

## What

In `.agents/scripts/pulse-simplification.sh` `_complexity_scan_ratchet_check` (around line 1693-1698), extend the existing `ratchet_pr_exists` check to also match PRs merged within the last 24h, not just open PRs. A PR that merges fast enough within one pulse cycle (like #19017 which merged within an hour) currently falls through the open-only check and the pulse re-files the same proposal.

The full target code block, edge cases, and macOS/GNU date compatibility notes are in the GitHub issue body at **#19036**.

## Why

Fastest-ROI fix for the #19024 incident. ~5 line surgical change that eliminates the primary duplicate-filing path.

## Tier

**tier:simple** — single file, ~5-10 lines, verbatim target code in the issue body, exact line references, no architecture decisions, <1h estimate.

### Tier checklist

- [x] Single file only (`pulse-simplification.sh`)
- [x] Exact line range known
- [x] Verbatim target code provided
- [x] No error/fallback logic to design (shellcheck-clean + existing error handling)
- [x] ≤4 acceptance criteria
- [x] No judgment keywords

## Reference

- Parent: #19035
- Incident: #19024
- Prior related fix: t2089 / PR #18959
- Full worker guidance: issue body of #19036

## Acceptance

- `--state all` + `merged:>=<24h ago>` check added alongside existing open check
- macOS BSD `date` and GNU `date` both supported
- Shellcheck clean
- Comment block updated to reference #19024 and #19035
