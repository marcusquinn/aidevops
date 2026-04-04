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

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Reddit CLI/API Integration

- **Install**: `pip install praw`
- **Repo**: https://github.com/praw-dev/praw (4k+ stars, Python, BSD-2)
- **Docs**: https://praw.readthedocs.io/
- **Rate limits**: Unauthenticated JSON: 96 req/10min per IP. Authenticated OAuth: 996 req/10min per account. PRAW handles rate limiting automatically; add `time.sleep(1)` for raw JSON endpoints.

## No-Auth (append `.json` to any Reddit URL)

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

OAuth app: https://www.reddit.com/prefs/apps → create "script" type → `aidevops secret set REDDIT_CLIENT_ID`.

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

## Related

- `scripts/x-helper.sh` - X/Twitter fetching via fxtwitter
- `tools/browser/curl-copy.md` - Authenticated scraping workflow
