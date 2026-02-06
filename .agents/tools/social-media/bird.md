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
- **Repo**: https://github.com/steipete/bird (434+ stars)
- **Auth**: Uses browser cookies (Safari, Chrome, Firefox)

**Quick Commands**:

```bash
# Check logged-in account
bird whoami

# Read a tweet
bird read https://x.com/user/status/1234567890123456789

# Post a tweet
bird tweet "Hello world!"

# Reply to a tweet
bird reply 1234567890123456789 "Great post!"

# Search tweets
bird search "from:steipete" -n 5

# Get mentions
bird mentions -n 5
```

**Key Features**:

- Tweet, reply, read via GraphQL API
- Thread and conversation viewing
- Search and mentions
- Bookmarks and likes management
- Following/followers lists
- Media uploads (images, GIFs, video)
- Browser cookie authentication (no API keys needed)

**Auth Methods**: Browser cookies (Safari/Chrome/Firefox), or manual `--auth-token` and `--ct0`

<!-- AI-CONTEXT-END -->

## Installation

### npm (recommended)

```bash
# Global install
npm i -g @steipete/bird

# One-shot (no install)
bunx @steipete/bird whoami
```

### Homebrew (macOS Apple Silicon)

```bash
brew install steipete/tap/bird
```

## Authentication

Bird uses your existing X/Twitter web session via browser cookies. No API keys or passwords required.

### Cookie Sources (in order of precedence)

1. CLI flags: `--auth-token`, `--ct0`
2. Environment variables: `AUTH_TOKEN`, `CT0` (or `TWITTER_AUTH_TOKEN`, `TWITTER_CT0`)
3. Browser cookies via `@steipete/sweet-cookie`

### Browser Cookie Locations

| Browser | Cookie Path |
|---------|-------------|
| Safari | `~/Library/Cookies/Cookies.binarycookies` |
| Chrome | `~/Library/Application Support/Google/Chrome/<Profile>/Cookies` |
| Firefox | `~/Library/Application Support/Firefox/Profiles/<profile>/cookies.sqlite` |

### Verify Authentication

```bash
# Check which account is logged in
bird whoami

# Check available credentials
bird check
```

### Manual Cookie Override

```bash
bird tweet "Hello" --auth-token YOUR_AUTH_TOKEN --ct0 YOUR_CT0_TOKEN
```

## Commands

### Reading Tweets

```bash
# Read a single tweet (URL or ID)
bird read https://x.com/user/status/1234567890123456789
bird read 1234567890123456789

# Shorthand (just the URL/ID)
bird 1234567890123456789

# JSON output
bird read 1234567890123456789 --json

# View thread/conversation
bird thread https://x.com/user/status/1234567890123456789

# View replies to a tweet
bird replies 1234567890123456789
```

### Posting Tweets

```bash
# Post a new tweet
bird tweet "Hello world!"

# Tweet with media (up to 4 images or 1 video)
bird tweet "Check this out!" --media image.png --alt "Description"

# Multiple images
bird tweet "Photos" --media img1.png --media img2.png --alt "First" --alt "Second"
```

### Replying

```bash
# Reply to a tweet
bird reply 1234567890123456789 "Great post!"

# Reply with URL
bird reply https://x.com/user/status/1234567890123456789 "Nice!"

# Reply with media
bird reply 1234567890123456789 "Here's my response" --media response.png
```

### Search

```bash
# Search tweets
bird search "from:steipete" -n 5

# Search with JSON output
bird search "AI tools" -n 10 --json
```

### Mentions

```bash
# Your mentions
bird mentions -n 5

# Another user's mentions
bird mentions --user @steipete -n 5

# JSON output
bird mentions -n 10 --json
```

### Bookmarks

```bash
# List bookmarks
bird bookmarks -n 5

# Specific bookmark folder
bird bookmarks --folder-id 123456789123456789 -n 5

# All bookmarks with pagination
bird bookmarks --all --max-pages 2 --json

# Remove bookmark
bird unbookmark 1234567890123456789
bird unbookmark https://x.com/user/status/1234567890123456789
```

### Likes

```bash
# List your liked tweets
bird likes -n 5

# JSON output
bird likes -n 10 --json
```

### Following/Followers

```bash
# Who you follow
bird following -n 20

# Who follows you
bird followers -n 20

# Another user's following/followers (by user ID)
bird following --user 12345678 -n 10
bird followers --user 12345678 -n 10
```

### Utility Commands

```bash
# Show help
bird help
bird help tweet

# Refresh GraphQL query IDs cache
bird query-ids --fresh

# Version info
bird --version
```

## Global Options

| Option | Description |
|--------|-------------|
| `--auth-token <token>` | Set auth_token cookie manually |
| `--ct0 <token>` | Set ct0 cookie manually |
| `--cookie-source <browser>` | Choose browser (safari, chrome, firefox) |
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

## Configuration

### Config File (JSON5)

Locations:
- Global: `~/.config/bird/config.json5`
- Project: `./.birdrc.json5`

Example `~/.config/bird/config.json5`:

```json5
{
  // Cookie source order for browser extraction
  cookieSource: ["firefox", "safari"],
  firefoxProfile: "default-release",
  cookieTimeoutMs: 30000,
  timeoutMs: 20000,
  quoteDepth: 1
}
```

### Environment Variables

```bash
# Timeout settings
BIRD_TIMEOUT_MS=20000
BIRD_COOKIE_TIMEOUT_MS=30000
BIRD_QUOTE_DEPTH=1
```

## JSON Output Schema

### Tweet Object

| Field | Type | Description |
|-------|------|-------------|
| `id` | string | Tweet ID |
| `text` | string | Full tweet text |
| `author` | object | `{ username, name }` |
| `authorId` | string? | Author's user ID |
| `createdAt` | string | Timestamp |
| `replyCount` | number | Number of replies |
| `retweetCount` | number | Number of retweets |
| `likeCount` | number | Number of likes |
| `conversationId` | string | Thread conversation ID |
| `inReplyToStatusId` | string? | Parent tweet ID (if reply) |
| `quotedTweet` | object? | Embedded quote tweet |

### User Object (following/followers)

| Field | Type | Description |
|-------|------|-------------|
| `id` | string | User ID |
| `username` | string | Username/handle |
| `name` | string | Display name |
| `description` | string? | User bio |
| `followersCount` | number? | Followers count |
| `followingCount` | number? | Following count |
| `isBlueVerified` | boolean? | Blue verified flag |
| `profileImageUrl` | string? | Profile image URL |
| `createdAt` | string? | Account creation timestamp |

## Media Uploads

### Supported Formats

- **Images**: jpg, jpeg, png, webp, gif
- **Video**: mp4, mov

### Limits

- Up to 4 images/GIFs, OR 1 video (no mixing)
- Video processing may take longer

### Examples

```bash
# Single image with alt text
bird tweet "Check this out!" --media photo.jpg --alt "A beautiful sunset"

# Multiple images
bird tweet "Photo dump" \
  --media img1.png --alt "First image" \
  --media img2.png --alt "Second image" \
  --media img3.png --alt "Third image"

# Video
bird tweet "Watch this!" --media video.mp4
```

## GraphQL Query IDs

X rotates GraphQL query IDs frequently. Bird handles this automatically:

- Ships with baseline mapping in `src/lib/query-ids.json`
- Runtime cache at `~/.config/bird/query-ids-cache.json`
- Auto-recovery on 404 errors (refreshes and retries)
- TTL: 24 hours

### Manual Refresh

```bash
# Force refresh query IDs
bird query-ids --fresh

# View current query IDs
bird query-ids --json
```

## Integration with aidevops

### Use Cases

1. **Social Media Automation**: Schedule and post content
2. **Engagement Monitoring**: Track mentions and replies
3. **Research**: Search and analyze tweets
4. **Content Curation**: Bookmark and organize content
5. **Analytics**: Export data for analysis

### Example Workflows

```bash
# Post announcement
bird tweet "New release v2.0 is out! Check the changelog: https://example.com/changelog"

# Monitor mentions and respond
bird mentions -n 10 --json | jq '.[] | select(.text | contains("help"))'

# Export bookmarks for analysis
bird bookmarks --all --json > bookmarks.json

# Thread a long post
bird tweet "1/3 Here's a thread about..."
# Get the tweet ID from output, then:
bird reply <tweet_id> "2/3 Continuing the thread..."
bird reply <tweet_id_2> "3/3 Final thoughts..."
```

### Combining with summarize

```bash
# Summarize a linked article and tweet about it
url="https://example.com/article"
summary=$(summarize "$url" --length short --plain)
bird tweet "Interesting read: $summary

$url"
```

## Troubleshooting

### Common Issues

1. **Cookie extraction fails**: Ensure browser is logged into X/Twitter
2. **Rate limiting (429)**: Wait and retry, or use different account
3. **Query ID invalid (404)**: Run `bird query-ids --fresh`
4. **Error 226 (automated request)**: Bird auto-falls back to legacy endpoint

### Debug Mode

```bash
# Check credentials
bird check

# Verify account
bird whoami

# Test with plain output
bird --plain check
```

## Disclaimer

This tool uses X/Twitter's undocumented web GraphQL API with cookie authentication. X can change endpoints, query IDs, and anti-bot behavior at any time - expect potential breakage.

## Resources

- **GitHub**: https://github.com/steipete/bird
- **npm**: https://www.npmjs.com/package/@steipete/bird
- **Changelog**: https://github.com/steipete/bird/blob/main/CHANGELOG.md
