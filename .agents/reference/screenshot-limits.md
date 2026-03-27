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
