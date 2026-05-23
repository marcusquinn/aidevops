<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# lottiefiles: Visual Theme & Browser Evidence

## Source reviewed

- Source: https://lottiefiles.com
- Title/evidence: `LottieFiles: Download Free lightweight animations for website & apps.` observed in the user's open Brave tab; unauthenticated headless fetch returned `Just a moment...`
- Browser status: Brave AppleScript could read the live tab title/URL, but JavaScript execution and Chrome DevTools Protocol access were unavailable. Headless Chrome returned anti-bot/challenge content, so computed style facts are still limited.

## Visual interpretation

This guide translates the browser-observed source into an AI-readable report/style system. Treat directly observed values as evidence and generated values as implementation-safe approximations. Preserve the source's broad mood, density, typography direction, spacing rhythm, and component language without copying proprietary brand assets.

## Mode behaviour

Browser-rendered dom includes theme/dark-mode markers. If a dark or light inverse palette is not explicitly present in the source, derive it using `tools/design/colour-palette.md`, label it as calculated, and validate text, badge, link, and border contrast before use.
