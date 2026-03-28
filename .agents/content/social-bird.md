---
description: X/Twitter CLI for reading, posting, and replying using steipete/bird
mode: subagent
tools:
  read: true
  write: false
  edit: false
  bash: true
  glob: true
  grep: true
  webfetch: true
  task: true
---

# Bird CLI - X/Twitter Integration

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Purpose**: Fast X/Twitter CLI for tweeting, replying, and reading
- **Install**: `npm i -g @steipete/bird` or `brew install steipete/tap/bird`
- **One-shot**: `npx -y @steipete/bird whoami`
- **Repo**: https://github.com/steipete/bird
- **Auth**: Browser cookies (Safari, Chrome, Firefox) — no API keys needed
- **Output**: `--json` for machine-readable, `--plain` for stable (no emoji/color)
- **Media**: `--media <path>` (up to 4 images/GIFs or 1 video) + `--alt <text>`. Formats: jpg, png, webp, gif, mp4, mov.

<!-- AI-CONTEXT-END -->

## Authentication

Uses existing X/Twitter web session via browser cookies.

**Cookie sources** (precedence order):

1. CLI flags: `--auth-token <token>`, `--ct0 <token>`
2. Environment: `AUTH_TOKEN`/`CT0` (or `TWITTER_AUTH_TOKEN`/`TWITTER_CT0`)
3. Browser cookies via `@steipete/sweet-cookie` (Safari, Chrome, Firefox)

**Verify**: `bird whoami` (account info), `bird check` (credential status).

**Config files** (JSON5): `~/.config/bird/config.json5` (global), `./.birdrc.json5` (project).

```json5
{
  cookieSource: ["firefox", "safari"],
  firefoxProfile: "default-release",
  cookieTimeoutMs: 30000,
  timeoutMs: 20000,
  quoteDepth: 1
}
```

**Environment variables**: `BIRD_TIMEOUT_MS`, `BIRD_COOKIE_TIMEOUT_MS`, `BIRD_QUOTE_DEPTH`.

## Commands

### Reading

```bash
bird read <url-or-id>              # Single tweet (or just pass bare ID)
bird read <id> --json              # JSON output
bird thread <url>                  # Thread/conversation
bird replies <id>                  # Replies to a tweet
```

### Posting

```bash
bird tweet "Hello world!"
bird tweet "Check this out!" --media image.png --alt "Description"
bird tweet "Photos" --media img1.png --media img2.png --alt "First" --alt "Second"
bird tweet "Watch this!" --media video.mp4
```

### Replying

```bash
bird reply <id-or-url> "Great post!"
bird reply <id> "Here's my response" --media response.png
```

### Search, Mentions, and Social

```bash
bird search "AI tools" -n 10 --json
bird mentions -n 5
bird mentions --user @steipete -n 5 --json
bird bookmarks -n 5
bird bookmarks --folder-id <id> -n 5
bird bookmarks --all --max-pages 2 --json
bird unbookmark <id-or-url>
bird likes -n 10 --json
bird following -n 20
bird followers -n 20
bird following --user <user-id> -n 10   # Another user's list
bird followers --user <user-id> -n 10
```

## Global Options

| Option | Description |
|--------|-------------|
| `--auth-token <token>` | Manual auth_token cookie |
| `--ct0 <token>` | Manual ct0 cookie |
| `--cookie-source <browser>` | Browser: safari, chrome, firefox |
| `--chrome-profile <name>` | Chrome profile for cookies |
| `--firefox-profile <name>` | Firefox profile for cookies |
| `--cookie-timeout <ms>` | Cookie extraction timeout |
| `--timeout <ms>` | Request timeout |
| `--quote-depth <n>` | Max quoted tweet depth in JSON (default: 1) |
| `--plain` | Stable output (no emoji, no color) |
| `--no-emoji` | Disable emoji output |
| `--no-color` | Disable ANSI colors |
| `--media <path>` | Attach media file (repeatable, up to 4) |
| `--alt <text>` | Alt text for media (repeatable) |

## JSON Output Schema

Tweet fields: `id`, `text`, `author` (`{ username, name }`), `authorId`, `createdAt`, `replyCount`, `retweetCount`, `likeCount`, `conversationId`, `inReplyToStatusId`, `quotedTweet`.

User fields: `id`, `username`, `name`, `description`, `followersCount`, `followingCount`, `isBlueVerified`, `profileImageUrl`, `createdAt`.

## GraphQL Query IDs

X rotates GraphQL query IDs frequently. Bird handles this automatically with a runtime cache (`~/.config/bird/query-ids-cache.json`, 24h TTL) and auto-recovery on 404 errors.

```bash
bird query-ids --fresh   # Force refresh
bird query-ids --json    # View current IDs
```

## Workflow Examples

```bash
# Post announcement
bird tweet "New release v2.0 is out! Check the changelog: https://example.com/changelog"

# Monitor mentions for help requests
bird mentions -n 10 --json | jq '.[] | select(.text | contains("help"))'

# Export bookmarks for analysis
bird bookmarks --all --json > bookmarks.json

# Thread a long post (reply to each previous tweet)
bird tweet "1/3 Here's a thread about..."
bird reply <id_of_first_tweet> "2/3 Continuing the thread..."
bird reply <id_of_second_tweet> "3/3 Final thoughts..."
```

## Troubleshooting

| Issue | Fix |
|-------|-----|
| Cookie extraction fails | Ensure browser is logged into X/Twitter |
| Rate limiting (429) | Wait and retry, or use different account |
| Query ID invalid (404) | Run `bird query-ids --fresh` |
| Error 226 (automated request) | Bird auto-falls back to legacy endpoint |

**Debug**: `bird check` (credentials), `bird whoami` (account), `bird --plain check` (plain output).

## Disclaimer

This tool uses X/Twitter's undocumented web GraphQL API with cookie authentication. X can change endpoints, query IDs, and anti-bot behavior at any time — expect potential breakage.

## Resources

- **GitHub**: https://github.com/steipete/bird
- **npm**: https://www.npmjs.com/package/@steipete/bird
- **Changelog**: https://github.com/steipete/bird/blob/main/CHANGELOG.md
