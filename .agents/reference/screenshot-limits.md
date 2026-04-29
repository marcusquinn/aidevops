<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Screenshot Size Limits (CRITICAL — session-crashing)

Anthropic hard-rejects images >8000px on any dimension. This crashes the session
because the oversized image is already in message history — every subsequent
API call fails with the same error. There is no recovery except starting a new
session and losing all conversation context.

GH#4213 added guardrails to browser-qa-helper.sh but agents take screenshots
through at least 5 other paths that bypass those guardrails entirely.

## Rules

- NEVER use `fullPage: true` for screenshots intended for AI vision review. Use viewport-sized screenshots instead (`fullPage: false` or omit the option).
- When full-page capture is genuinely needed (human review, visual regression, saving to disk for later), save to file and resize before including in conversation context:
  - `sips --resampleHeightWidthMax 1568 screenshot.png --out screenshot-resized.png` (macOS)
  - `magick screenshot.png -resize "1568x1568>" screenshot-resized.png` (ImageMagick, cross-platform)
- For AI vision review: target max 1568px on the longest side. Images above this are auto-downscaled by the API, adding latency with no quality benefit.
- Anthropic hard limit: 8000px on any single dimension. Images at or above this are rejected outright.
- The Playwright MCP `browser_screenshot` tool returns base64 images directly into conversation context with NO resize hook. There is no way to intercept or resize these images after the tool returns. Prefer `browser-qa-helper.sh screenshot` which has built-in guardrails, or use viewport-sized screenshots via Playwright direct.
- The `browser-qa-helper.sh screenshot` command is the ONLY screenshot path with automatic size guardrails (post-capture resize to `--max-dim`, default 4000px). All other paths — Playwright MCP, dev-browser scripts, raw Playwright code — have zero size protection.

## macOS Filename Hygiene

macOS inserts a narrow no-break space (U+202F, UTF-8 bytes: `e2 80 af`) before AM/PM in screenshot filenames. Example: `Screenshot 2026-04-28 at 8.16.59 PM.png` — the space before "PM" is U+202F, not a regular ASCII space (U+0020).

The Claude Code Read tool truncates paths at this character and returns `File not found: /Users`, which is uninformative. Users have no way to tell that the filename contains an invisible non-standard space.

### Recovery workflow

When Read returns `File not found: /Users` on a screenshot path:

1. Glob for the file to confirm it exists:

   ```bash
   ls ~/Downloads/Screenshot*.png
   ```

2. Sanitize the path with the helper:

   ```bash
   clean=$(screenshot-import-helper.sh sanitize ~/Downloads/"Screenshot 2026-04-28 at 8.16.59 PM.png")
   ```

3. Use the returned `$clean` path with the Read tool. The helper copies the file to `~/.aidevops/.agent-workspace/tmp/session-PID/` with the U+202F bytes removed from the filename.

### Notes

- The helper is idempotent — calling it on an already-clean path prints the path unchanged without copying.
- The temp copy persists for the session (tied to the shell PID). On session end, it can be cleaned up with `rm -rf ~/.aidevops/.agent-workspace/tmp/session-PID/`.
- This is a workaround for an upstream Claude Code limitation. The root cause (path truncation at U+202F in the Read tool's error handling) is not fixable at the framework level.
