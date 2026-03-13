# t1459: Prevent duplicate quality-debt recreation across users

## Origin

- **Created:** 2026-03-12
- **Session:** OpenCode interactive request
- **Created by:** OpenCode gpt-5.3-codex
- **Parent task:** none
- **Conversation context:** During TODO reconciliation the user asked whether quality-debt issue count growth was caused by duplicate creation. Analysis showed duplicate historical titles and cross-user creation patterns, then user asked to implement the fix.

## What

Harden the merged PR review scanner so quality-debt issues are not recreated when different users/runners rescan historical PRs, while preserving existing file-level batching behavior.

## Why

- The scanner keeps local state in `$HOME`, so multi-user runs can reprocess the same merged PRs.
- Existing dedup only checks open quality-debt issues, so previously closed titles can be recreated.
- Recreated debt inflates backlog and makes quality trend signals unreliable.

## How (Approach)

1. Add a shared PR-level marker label (`review-feedback-scanned`) and skip PRs that already carry it.
2. Mark each scanned PR with this label after processing.
3. Expand exact-title dedup to include both open and closed quality-debt issues.
4. Keep cross-PR file append behavior for open issues only.
5. Fix scanner metrics so appending comments does not increment `issues_created`.

## Acceptance Criteria

- [ ] `scan-merged` skips merged PRs already marked `review-feedback-scanned`.
- [ ] `scan-merged` labels newly scanned PRs with `review-feedback-scanned`.
- [ ] `_create_quality_debt_issues` does not recreate an issue title that exists in closed quality-debt history.
- [ ] Cross-PR file-level append behavior still uses open issues only.
- [ ] `issues_created` reports only newly created issues (not appended comments).

## Context & Decisions

- Use GitHub labels as shared, repo-visible state to avoid per-home state divergence.
- Keep local JSON state for performance and resumability, but treat label as the source of truth for cross-user dedup.
- Skip recreation of closed quality-debt entries by default; avoid reopening without explicit operator decision.

## Relevant Files

- `.agents/scripts/quality-feedback-helper.sh`
- `TODO.md`
- `todo/tasks/t1459-brief.md`

## Dependencies

- **Blocked by:** none
- **Blocks:** none
- **External:** GitHub issue [GH#4299](https://github.com/marcusquinn/aidevops/issues/4299)

## Estimate Breakdown

| Phase | Time | Notes |
|-------|------|-------|
| Research/read | 20m | inspect duplicate patterns and creation paths |
| Implementation | 45m | scanner + dedup hardening updates |
| Testing | 25m | live scan smoke check + syntax/lint |
| **Total** | **~1.5h** | |
