<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# t15047: simplification: tighten agent doc Bot Management Gotchas

## Summary
Tighten and restructure the agent doc `.agents/services/hosting/cloudflare-platform-skill/bot-management-gotchas.md` to improve readability and importance-based ordering while preserving all institutional knowledge.

## Acceptance Criteria
- [ ] Content preservation: all code blocks, URLs, task ID references, and command examples are present.
- [ ] Importance-based ordering: most critical instructions first.
- [ ] Prose tightened: redundant words removed, concise language used.
- [ ] No broken internal links or references.
- [ ] Verified with `markdownlint-cli2`.

## Context
- Issue: GH#15047
- File: `.agents/services/hosting/cloudflare-platform-skill/bot-management-gotchas.md`
- Guidance: `tools/build-agent/build-agent.md`

## How
1. Read the existing doc.
2. Reorder sections by importance (e.g., False Positives/Negatives and Bot Score = 0 are likely more important than Plan Restrictions).
3. Tighten prose in each section.
4. Verify content preservation.
5. Run linting.
