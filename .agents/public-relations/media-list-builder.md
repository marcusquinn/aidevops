---
description: Build small evidence-backed journalist lists from direct sources
mode: subagent
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Media List Builder

Build a small first-wave journalist list for one story or angle. This is not lead generation and not cold outbound automation.

## Inputs

- Story/pitch/announcement and target audience.
- Why the client has standing.
- Geography, outlets/beats to include or avoid.
- Desired first-wave size; default 5-15.
- Source URLs or keywords, if available.

If there is no angle, run `pr-strategy.md` or `newsworthiness-check.md` first.

## Open workflow

1. Run `news-search.md` for the story, competitors, adjacent beat terms, and explicit user keywords.
2. Extract bylines and author profile URLs from real articles.
3. Research each journalist's recent work directly from outlet author pages, RSS/search results, or public profile pages.
4. Score fit using `journalist-fit-check.md`.
5. Keep only journalists with a concrete reason to care now.
6. Produce a first-wave table and a rejected/hold list with reasons.

## Contact policy

- Prefer public newsroom/contact pages and author profile contact methods.
- Do not guess email addresses.
- DNS/MX/syntax checks can flag obviously invalid addresses, but they are not proof of deliverability.
- Paid email-finder/verifier services are optional user-approved integrations only; never required.

## Output columns

| Priority | Journalist | Outlet | Recent evidence | Fit reason | Angle | Contact status | Caveats |
|---|---|---|---|---|---|---|---|

Every row needs a URL-backed evidence anchor. If a journalist is plausible but unverified, place them in `Hold / research more` rather than the first wave.
