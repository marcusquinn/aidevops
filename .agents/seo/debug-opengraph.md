---
description: Debug and validate Open Graph meta tags for social sharing
mode: subagent
tools:
  read: true
  write: false
  edit: false
  bash: true
  grep: true
  webfetch: true
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Open Graph Debugger

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Purpose**: Validate OG meta tags, preview social sharing, check image requirements
- **Method**: HTML parsing via curl + grep, or browser automation for JS-rendered pages
- **No API key required** — parses HTML directly
- **Reference**: https://opengraphdebug.com/

**Required OG Tags**: `og:title`, `og:description`, `og:image`, `og:url`
**Twitter Tags**: `twitter:card`, `twitter:title`, `twitter:description`, `twitter:image`

<!-- AI-CONTEXT-END -->

## Validation

### Check All Required Tags

```bash
url="https://example.com"
html=$(curl -sL "$url")

echo "=== Open Graph Tags ==="
for tag in og:title og:description og:image og:url og:type og:site_name; do
  value=$(echo "$html" | grep -oE "property=\"$tag\"[^>]+content=\"[^\"]*\"" | grep -oE 'content="[^"]*"' | cut -d'"' -f2)
  [ -n "$value" ] && printf "[OK] %-20s %s\n" "$tag:" "${value:0:60}" || printf "[MISSING] %s\n" "$tag"
done

echo ""
echo "=== Twitter Card Tags ==="
for tag in twitter:card twitter:title twitter:description twitter:image twitter:site; do
  value=$(echo "$html" | grep -oE "name=\"$tag\"[^>]+content=\"[^\"]*\"" | grep -oE 'content="[^"]*"' | cut -d'"' -f2)
  [ -n "$value" ] && printf "[OK] %-20s %s\n" "$tag:" "${value:0:60}" || printf "[MISSING] %s\n" "$tag"
done
```

### Extract All OG Tags (raw)

```bash
curl -sL "https://example.com" | grep -oE '<meta[^>]+(property|name)="(og:|twitter:|fb:)[^"]*"[^>]+content="[^"]*"[^>]*>' | while read -r line; do
  prop=$(echo "$line" | grep -oE '(property|name)="[^"]*"' | cut -d'"' -f2)
  content=$(echo "$line" | grep -oE 'content="[^"]*"' | cut -d'"' -f2)
  printf "%-25s %s\n" "$prop:" "$content"
done
```

## Image Validation

```bash
url="https://example.com"
og_image=$(curl -sL "$url" | grep -oE 'property="og:image"[^>]+content="[^"]*"' | grep -oE 'content="[^"]*"' | cut -d'"' -f2)

if [ -n "$og_image" ]; then
  echo "OG Image URL: $og_image"
  status=$(curl -sI "$og_image" | head -1 | cut -d' ' -f2)
  echo "HTTP Status: $status"
  curl -sI "$og_image" | grep -iE "^(content-type|content-length):"
  if command -v identify &>/dev/null; then
    curl -sL "$og_image" -o /tmp/og_image_check.tmp
    identify /tmp/og_image_check.tmp 2>/dev/null | awk '{print "Dimensions:", $3}'
    rm -f /tmp/og_image_check.tmp
  fi
else
  echo "No og:image found"
fi
```

## Platform Requirements

### Facebook/Meta

| Property | Required | Recommended |
|----------|----------|-------------|
| `og:title` | Yes | 60-90 chars |
| `og:description` | Yes | 155-200 chars |
| `og:image` | Yes | 1200x630px (1.91:1) |
| `og:url` | Yes | Canonical URL |
| `og:type` | No | `website`, `article`, etc. |
| `og:site_name` | No | Brand name |

**Image**: Min 200x200px, max 8MB, PNG/JPEG/GIF

### Twitter

| Property | Required | Notes |
|----------|----------|-------|
| `twitter:card` | Yes | `summary`, `summary_large_image`, `player` |
| `twitter:title` | Falls back to og:title | 70 chars max |
| `twitter:description` | Falls back to og:description | 200 chars max |
| `twitter:image` | Falls back to og:image | 2:1 ratio for large image |
| `twitter:site` | No | @username of website |
| `twitter:creator` | No | @username of content creator |

**Image**: `summary` 144x144px min, 1:1 ratio; `summary_large_image` 300x157px min, 2:1 ratio; max 4096x4096px

### LinkedIn

| Property | Required | Notes |
|----------|----------|-------|
| `og:title` | Yes | 70 chars recommended |
| `og:description` | Yes | 100 chars recommended |
| `og:image` | Yes | 1200x627px (1.91:1), min 1200x627px, max 5MB |
| `og:url` | Yes | Canonical URL |

## Platform Validators

| Platform | URL | Notes |
|----------|-----|-------|
| Facebook | https://developers.facebook.com/tools/debug/ | Requires login; use `?q=<url>` param |
| Twitter | https://cards-dev.twitter.com/validator | Requires login |
| LinkedIn | https://www.linkedin.com/post-inspector/ | Requires login; append URL to path |

## Common Issues

### Missing required tags

```html
<meta property="og:title" content="Page Title">
<meta property="og:description" content="Page description">
<meta property="og:image" content="https://example.com/image.jpg">
<meta property="og:url" content="https://example.com/page">
```

### Relative image URLs

`og:image` must use absolute URLs with protocol:

```html
<!-- Wrong -->
<meta property="og:image" content="/images/share.jpg">
<!-- Correct -->
<meta property="og:image" content="https://example.com/images/share.jpg">
```

### Image too small

Use 1200x630px for best cross-platform compatibility.

### Cache issues

Platforms cache OG data. Force refresh:

```bash
# Facebook
curl -X POST "https://graph.facebook.com/?id=https://example.com&scrape=true"
# LinkedIn — use Post Inspector to refresh
# Twitter — wait 7 days or use a different URL
```

### JavaScript-rendered tags

Crawlers won't see tags rendered by JS:

```bash
curl -sL "https://example.com" | grep -c 'og:title'
# If 0, tags are JS-rendered — use SSR or prerendering
```

## Structured Data

Check for JSON-LD (helps with rich snippets):

```bash
curl -sL "https://example.com" | grep -oE '<script type="application/ld\+json">[^<]+</script>' | sed 's/<[^>]*>//g' | jq . 2>/dev/null || echo "No valid JSON-LD found"
```

## Full Audit Script

```bash
#!/bin/bash
# og-audit.sh - Full Open Graph audit
url="${1:-https://example.com}"
echo "=== Open Graph Audit: $url ==="
html=$(curl -sL "$url")

echo "## Open Graph Tags"
for tag in og:title og:description og:image og:url og:type og:site_name og:locale; do
  value=$(echo "$html" | grep -oE "property=\"$tag\"[^>]+content=\"[^\"]*\"" | grep -oE 'content="[^"]*"' | cut -d'"' -f2)
  [ -n "$value" ] && printf "  %-18s %s\n" "$tag:" "${value:0:80}" || printf "  %-18s [MISSING]\n" "$tag:"
done

echo ""
echo "## Twitter Card Tags"
for tag in twitter:card twitter:title twitter:description twitter:image twitter:site; do
  value=$(echo "$html" | grep -oE "name=\"$tag\"[^>]+content=\"[^\"]*\"" | grep -oE 'content="[^"]*"' | cut -d'"' -f2)
  [ -n "$value" ] && printf "  %-22s %s\n" "$tag:" "${value:0:80}" || printf "  %-22s [MISSING]\n" "$tag:"
done

og_image=$(echo "$html" | grep -oE 'property="og:image"[^>]+content="[^"]*"' | grep -oE 'content="[^"]*"' | cut -d'"' -f2)
if [ -n "$og_image" ]; then
  echo ""
  echo "## Image Check"
  echo "  URL: $og_image"
  status=$(curl -sI "$og_image" 2>/dev/null | head -1 | cut -d' ' -f2)
  echo "  Status: ${status:-unreachable}"
fi

echo ""
echo "## Validators"
echo "  Facebook: https://developers.facebook.com/tools/debug/?q=$url"
echo "  LinkedIn: https://www.linkedin.com/post-inspector/inspect/$url"
```

## Related

- `tools/browser/playwright.md` — JS-rendered pages
- `seo/site-crawler.md` — Bulk OG tag auditing
- `seo/eeat-score.md` — Content quality signals
