---
description: Reddit API integration via PRAW for reading and posting
mode: subagent
tools:
  read: true
  write: false
  edit: false
  bash: true
  webfetch: true
---

# Reddit CLI/API Integration

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Purpose**: Read and post to Reddit via API (PRAW) or JSON endpoints
- **Install**: `pip install praw`
- **Repo**: https://github.com/praw-dev/praw (4k+ stars, Python, BSD-2)
- **Docs**: https://praw.readthedocs.io/

**Rate limits**: Unauthenticated JSON: 96 req/10min per IP. Authenticated OAuth: 996 req/10min per account.

<!-- AI-CONTEXT-END -->

## Quick Access (No Auth)

Reddit exposes JSON endpoints by appending `.json` to any URL:

```bash
# Subreddit posts
curl -s "https://www.reddit.com/r/devops/hot.json?limit=10" | jq '.data.children[].data | {title, score, url}'

# Post comments
curl -s "https://www.reddit.com/r/devops/comments/POST_ID.json" | jq '.[1].data.children[].data | {author, body, score}'

# User profile
curl -s "https://www.reddit.com/user/USERNAME/about.json" | jq '.data | {name, link_karma, comment_karma}'

# Search
curl -s "https://www.reddit.com/search.json?q=aidevops&sort=relevance" | jq '.data.children[].data | {title, subreddit, score}'
```

## PRAW (Authenticated)

```python
import praw

reddit = praw.Reddit(
    client_id="YOUR_CLIENT_ID",
    client_secret="YOUR_CLIENT_SECRET",
    user_agent="aidevops/1.0",
    username="YOUR_USERNAME",
    password="YOUR_PASSWORD"
)

# Read subreddit
for post in reddit.subreddit("devops").hot(limit=10):
    print(f"{post.score}: {post.title}")

# Submit post
reddit.subreddit("test").submit("Title", selftext="Body text")

# Reply to comment
comment = reddit.comment("COMMENT_ID")
comment.reply("Reply text")
```

## OAuth App Setup

1. Go to https://www.reddit.com/prefs/apps
2. Create "script" type application
3. Note `client_id` (under app name) and `client_secret`
4. Store credentials: `aidevops secret set REDDIT_CLIENT_ID`

## Rate Limit Handling

```python
# PRAW handles rate limiting automatically
# For JSON endpoints, add delay:
import time
for url in urls:
    response = requests.get(url, headers={"User-Agent": "aidevops/1.0"})
    time.sleep(1)  # Stay under 96/10min
```

## Related

- `scripts/x-helper.sh` - X/Twitter fetching via fxtwitter
- `tools/browser/curl-copy.md` - Authenticated scraping workflow
