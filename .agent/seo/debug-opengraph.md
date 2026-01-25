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

# Open Graph Debugger

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Purpose**: Validate OG meta tags, preview social sharing, check image requirements
- **Method**: HTML parsing via curl + grep, or browser automation for JS-rendered pages
- **No API key required** - parses HTML directly
- **Validators**: Facebook Sharing Debugger, Twitter Card Validator, LinkedIn Post Inspector
- **Reference**: https://opengraphdebug.com/

**Required OG Tags**: `og:title`, `og:description`, `og:image`, `og:url`
**Twitter Tags**: `twitter:card`, `twitter:title`, `twitter:description`, `twitter:image`

<!-- AI-CONTEXT-END -->

## Quick Validation

### Extract All OG Tags

```bash
curl -sL "https://example.com" | grep -oE '<meta[^>]+(property|name)="(og:|twitter:)[^"]*"[^>]*>' | sed 's/.*content="\([^"]*\)".*/\1/' | head -20
```

### Full OG Tag Extraction with Values

```bash
curl -sL "https://example.com" | grep -oE '<meta[^>]+(property|name)="(og:|twitter:|fb:)[^"]*"[^>]+content="[^"]*"[^>]*>' | while read -r line; do
  prop=$(echo "$line" | grep -oE '(property|name)="[^"]*"' | cut -d'"' -f2)
  content=$(echo "$line" | grep -oE 'content="[^"]*"' | cut -d'"' -f2)
  printf "%-25s %s\n" "$prop:" "$content"
done
```

### Check Specific Required Tags

```bash
url="https://example.com"
html=$(curl -sL "$url")

echo "=== Open Graph Tags ==="
for tag in og:title og:description og:image og:url og:type og:site_name; do
  value=$(echo "$html" | grep -oE "property=\"$tag\"[^>]+content=\"[^\"]*\"" | grep -oE 'content="[^"]*"' | cut -d'"' -f2)
  if [ -n "$value" ]; then
    printf "[OK] %-20s %s\n" "$tag:" "${value:0:60}"
  else
    printf "[MISSING] %s\n" "$tag"
  fi
done

echo ""
echo "=== Twitter Card Tags ==="
for tag in twitter:card twitter:title twitter:description twitter:image twitter:site; do
  value=$(echo "$html" | grep -oE "name=\"$tag\"[^>]+content=\"[^\"]*\"" | grep -oE 'content="[^"]*"' | cut -d'"' -f2)
  if [ -n "$value" ]; then
    printf "[OK] %-20s %s\n" "$tag:" "${value:0:60}"
  else
    printf "[MISSING] %s\n" "$tag"
  fi
done
```

## Image Validation

### Check OG Image Accessibility and Size

```bash
url="https://example.com"
og_image=$(curl -sL "$url" | grep -oE 'property="og:image"[^>]+content="[^"]*"' | grep -oE 'content="[^"]*"' | cut -d'"' -f2)

if [ -n "$og_image" ]; then
  echo "OG Image URL: $og_image"
  
  # Check if image is accessible
  status=$(curl -sI "$og_image" | head -1 | cut -d' ' -f2)
  echo "HTTP Status: $status"
  
  # Get content type and size
  curl -sI "$og_image" | grep -iE "^(content-type|content-length):"
  
  # Download and check dimensions (requires ImageMagick)
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

| Property | Required | Recommended Size |
|----------|----------|------------------|
| `og:title` | Yes | 60-90 chars |
| `og:description` | Yes | 155-200 chars |
| `og:image` | Yes | 1200x630px (1.91:1) |
| `og:url` | Yes | Canonical URL |
| `og:type` | No | `website`, `article`, etc. |
| `og:site_name` | No | Brand name |

**Image requirements**: Min 200x200px, max 8MB, PNG/JPEG/GIF

### Twitter

| Property | Required | Notes |
|----------|----------|-------|
| `twitter:card` | Yes | `summary`, `summary_large_image`, `player` |
| `twitter:title` | Falls back to og:title | 70 chars max |
| `twitter:description` | Falls back to og:description | 200 chars max |
| `twitter:image` | Falls back to og:image | 2:1 ratio for large image |
| `twitter:site` | No | @username of website |
| `twitter:creator` | No | @username of content creator |

**Image requirements**: 
- `summary`: 144x144px min, 4096x4096px max, 1:1 ratio
- `summary_large_image`: 300x157px min, 4096x4096px max, 2:1 ratio

### LinkedIn

| Property | Required | Notes |
|----------|----------|-------|
| `og:title` | Yes | 70 chars recommended |
| `og:description` | Yes | 100 chars recommended |
| `og:image` | Yes | 1200x627px (1.91:1) |
| `og:url` | Yes | Canonical URL |

**Image requirements**: Min 1200x627px, max 5MB

## Platform Validators

### Facebook Sharing Debugger

```bash
# Open in browser (requires Facebook login)
open "https://developers.facebook.com/tools/debug/?q=https://example.com"
```

### Twitter Card Validator

```bash
# Open in browser (requires Twitter login)
open "https://cards-dev.twitter.com/validator"
```

### LinkedIn Post Inspector

```bash
# Open in browser (requires LinkedIn login)
open "https://www.linkedin.com/post-inspector/inspect/https://example.com"
```

## Common Issues

### 1. Missing Required Tags

```html
<!-- Minimum required OG tags -->
<meta property="og:title" content="Page Title">
<meta property="og:description" content="Page description">
<meta property="og:image" content="https://example.com/image.jpg">
<meta property="og:url" content="https://example.com/page">
```

### 2. Relative Image URLs

**Problem**: `og:image` uses relative path
**Solution**: Always use absolute URLs with protocol

```html
<!-- Wrong -->
<meta property="og:image" content="/images/share.jpg">

<!-- Correct -->
<meta property="og:image" content="https://example.com/images/share.jpg">
```

### 3. Image Too Small

**Problem**: Image doesn't meet minimum size requirements
**Solution**: Use 1200x630px for best cross-platform compatibility

### 4. Cache Issues

Platforms cache OG data. Force refresh:

```bash
# Facebook - scrape again
curl -X POST "https://graph.facebook.com/?id=https://example.com&scrape=true"

# LinkedIn - use Post Inspector to refresh
# Twitter - wait 7 days or use different URL
```

### 5. JavaScript-Rendered Content

If OG tags are rendered by JavaScript, crawlers won't see them:

```bash
# Check if tags are in initial HTML
curl -sL "https://example.com" | grep -c 'og:title'

# If 0, tags are JS-rendered - use SSR or prerendering
```

## Structured Data Bonus

Check for JSON-LD structured data (helps with rich snippets):

```bash
curl -sL "https://example.com" | grep -oE '<script type="application/ld\+json">[^<]+</script>' | sed 's/<[^>]*>//g' | jq . 2>/dev/null || echo "No valid JSON-LD found"
```

## Full Audit Script

```bash
#!/bin/bash
# og-audit.sh - Full Open Graph audit

url="${1:-https://example.com}"
echo "=== Open Graph Audit: $url ==="
echo ""

html=$(curl -sL "$url")

# Check OG tags
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

# Check image
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

- `tools/browser/playwright.md` - For JS-rendered pages
- `seo/site-crawler.md` - Bulk OG tag auditing
- `seo/eeat-score.md` - Content quality signals
