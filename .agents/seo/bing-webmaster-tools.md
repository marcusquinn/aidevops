---
description: Bing Webmaster Tools API integration via curl
mode: subagent
tools:
  read: true
  write: false
  edit: false
  bash: true
  glob: true
  grep: true
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

## Quick Reference

- **API Base**: `https://ssl.bing.com/webmaster/api.svc/json/`
- **Auth**: query param `apikey=$BING_WEBMASTER_API_KEY`
- **Credentials**: `aidevops secret set BING_WEBMASTER_API_KEY` (or `BING_WEBMASTER_API_KEY_<ACCOUNT>`)
- **Docs**: [Bing Webmaster API](https://www.bing.com/webmasters/help/webmaster-api-5f3c5e1e)

## Setup

1. [Bing Webmaster Tools](https://www.bing.com/webmasters/) → **Settings** → **API Access** → **Generate API Key**
2. Store it: `aidevops secret set BING_WEBMASTER_API_KEY`. For an account-specific key use `BING_WEBMASTER_API_KEY_<ACCOUNT>` instead and inject that name in step 3 (`seo-export-bing.sh` uses a suffixed key only when gopass is installed and exactly one exists; without gopass, `aidevops secret set` writes to the plaintext `credentials.sh` fallback, where a suffixed key is not found, so store the unsuffixed name). Keyword research (`keyword-research-helper-webmaster.sh`) reads only the unsuffixed `BING_WEBMASTER_API_KEY`, so store that name if you use it
3. Run curl inside the wrapper so the key is injected, never printed: `aidevops secret BING_WEBMASTER_API_KEY -- sh -c 'BASE=https://ssl.bing.com/webmaster/api.svc/json; KEY=$BING_WEBMASTER_API_KEY; curl -s -G "$BASE/GetUserSites" --data-urlencode "apikey=$KEY"'`

## API Operations (`BASE="https://ssl.bing.com/webmaster/api.svc/json"`)

Run each example below inside the Setup step 3 wrapper (`aidevops secret BING_WEBMASTER_API_KEY -- sh -c '...'`), setting `BASE=https://ssl.bing.com/webmaster/api.svc/json` inside the same `sh -c` command. The wrapper injects the key only into that child process, so `BASE` and `$BING_WEBMASTER_API_KEY` are empty in the calling shell.

### Submit URL

```bash
curl -s -X POST "$BASE/SubmitUrl?apikey=$BING_WEBMASTER_API_KEY" \
  -H "Content-Type: application/json" \
  -d '{"siteUrl": "https://example.com", "url": "https://example.com/new-page"}'
```

### Batch Submit (up to 10,000/day)

```bash
curl -s -X POST "$BASE/SubmitUrlBatch?apikey=$BING_WEBMASTER_API_KEY" \
  -H "Content-Type: application/json" \
  -d '{"siteUrl": "https://example.com", "urlList": ["https://example.com/page1", "https://example.com/page2"]}'
```

### URL Inspection

```bash
curl -s -G "$BASE/GetUrlInfo" \
  --data-urlencode "apikey=$BING_WEBMASTER_API_KEY" \
  --data-urlencode "siteUrl=https://example.com" \
  --data-urlencode "url=https://example.com/page"
```

### Search Analytics

```bash
curl -s -X POST "$BASE/GetQueryStats?apikey=$BING_WEBMASTER_API_KEY" \
  -H "Content-Type: application/json" \
  -d '{"siteUrl": "https://example.com", "startDate": "2025-01-01", "endDate": "2025-01-31"}'
```

### Sitemap Submit

```bash
curl -s -X POST "$BASE/SubmitFeed?apikey=$BING_WEBMASTER_API_KEY" \
  -H "Content-Type: application/json" \
  -d '{"siteUrl": "https://example.com", "feedUrl": "https://example.com/sitemap.xml"}'
```

### Sitemap List

```bash
curl -s -G "$BASE/GetFeedStats" \
  --data-urlencode "apikey=$BING_WEBMASTER_API_KEY" \
  --data-urlencode "siteUrl=https://example.com"
```

## New Site Setup

Add, verify and submit a new site with no browser sign-in. Run every call inside the wrapper from Setup step 3, which sets `BASE` and `KEY` (`KEY=$BING_WEBMASTER_API_KEY`, or the suffixed variable for an account key) before the commands below.

### 1. List sites

```bash
curl -s -G "$BASE/GetUserSites" --data-urlencode "apikey=$KEY"
# {"d":[{"Url","IsVerified","DnsVerificationCode","AuthenticationCode"},...]}
```

### 2. Add site

```bash
curl -s -X POST "$BASE/AddSite?apikey=$KEY" \
  -H "Content-Type: application/json" \
  -d '{"siteUrl": "https://example.com/"}'
# HTTP 200 {"d":null}
```

### 3. Get DNS code

Repeat step 1. The new entry has `IsVerified: false` and `DnsVerificationCode` of the form `<32 hex>.example.com`.

### 4. Add DNS record

Create a CNAME from `<32 hex>.example.com` to `verify.bing.com` (DNS only, not proxied) and wait until it resolves.

### 5. Verify

```bash
curl -s -X POST "$BASE/VerifySite?apikey=$KEY" \
  -H "Content-Type: application/json" \
  -d '{"siteUrl": "https://example.com/"}'
# HTTP 200 {"d":true}
```

### 6. Submit sitemap

Same call as [Sitemap Submit](#sitemap-submit), but with `siteUrl` `https://example.com/` and the apikey value taken from `$KEY` (as in steps 1, 2 and 5), so account-specific keys work. Expect HTTP 200 `{"d":null}`.

## IndexNow

Push changed URLs to participating engines (including Bing) without the Webmaster API key.

1. Generate a 32-character hex key and serve it as `https://example.com/<key>.txt` (file body is the key).
2. Submit URLs:

```bash
curl -s -o /dev/null -w "%{http_code}\n" -X POST "https://api.indexnow.org/indexnow" \
  -H "Content-Type: application/json" \
  -d '{"host": "example.com", "key": "<key>", "keyLocation": "https://example.com/<key>.txt", "urlList": ["https://example.com/new-page"]}'
```

| Status | Meaning |
|--------|---------|
| 200 | Accepted |
| 202 | Received, key validation pending (observed on first submission) |
| 403 | Key invalid or key file not found at `keyLocation` |
| 422 | URLs do not match `host`, or key schema invalid |

## Troubleshooting

| Error | Cause / Fix |
|-------|-------------|
| HTTP 400 | Bad JSON or `siteUrl` mismatch (check http/https, www/non-www) |
| HTTP 401 | `BING_WEBMASTER_API_KEY` incorrect or revoked |
| HTTP 500 | Transient — retry |
| Quota exceeded | 10,000 URLs/day/site limit |

## Integration with SEO Audit

Used by `seo-audit-skill` for cross-engine verification: check GSC index status, check Bing index status, compare for engine-specific issues.
