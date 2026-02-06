---
description: Debug and validate favicon setup across platforms and PWA manifests
mode: subagent
tools:
  read: true
  write: false
  edit: false
  bash: true
  grep: true
  webfetch: true
---

# Favicon Debugger

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Purpose**: Validate favicon setup, check all icon sizes, verify PWA manifest
- **Method**: HTML parsing via curl + grep, manifest.json validation
- **No API key required** - parses HTML directly
- **Reference**: https://opengraphdebug.com/favicon

**Essential Icons**: `favicon.ico`, `apple-touch-icon.png`, `manifest.json` icons
**PWA Requirements**: 192x192 and 512x512 PNG icons in manifest

<!-- AI-CONTEXT-END -->

## Quick Validation

### Extract All Favicon/Icon Links

```bash
curl -sL "https://example.com" | grep -oE '<link[^>]+(rel="(icon|shortcut icon|apple-touch-icon|manifest)"|rel="(icon|shortcut icon|apple-touch-icon|manifest)"[^>]*)[^>]*>' | head -20
```

### Full Icon Extraction with Details

```bash
url="https://example.com"
html=$(curl -sL "$url")

echo "=== Favicon & Icon Links ==="
echo "$html" | grep -oE '<link[^>]+rel="[^"]*icon[^"]*"[^>]*>' | while read -r line; do
  rel=$(echo "$line" | grep -oE 'rel="[^"]*"' | cut -d'"' -f2)
  href=$(echo "$line" | grep -oE 'href="[^"]*"' | cut -d'"' -f2)
  sizes=$(echo "$line" | grep -oE 'sizes="[^"]*"' | cut -d'"' -f2)
  type=$(echo "$line" | grep -oE 'type="[^"]*"' | cut -d'"' -f2)
  printf "%-20s %-12s %-15s %s\n" "$rel" "${sizes:-n/a}" "${type:-n/a}" "$href"
done

echo ""
echo "=== Apple Touch Icons ==="
echo "$html" | grep -oE '<link[^>]+rel="apple-touch-icon[^"]*"[^>]*>' | while read -r line; do
  href=$(echo "$line" | grep -oE 'href="[^"]*"' | cut -d'"' -f2)
  sizes=$(echo "$line" | grep -oE 'sizes="[^"]*"' | cut -d'"' -f2)
  printf "%-12s %s\n" "${sizes:-default}" "$href"
done

echo ""
echo "=== Manifest Link ==="
manifest=$(echo "$html" | grep -oE '<link[^>]+rel="manifest"[^>]+href="[^"]*"' | grep -oE 'href="[^"]*"' | cut -d'"' -f2)
echo "Manifest: ${manifest:-[NOT FOUND]}"
```

### Check favicon.ico Directly

```bash
url="https://example.com"
status=$(curl -sI "$url/favicon.ico" | head -1 | cut -d' ' -f2)
echo "favicon.ico status: $status"

# Check content type
curl -sI "$url/favicon.ico" | grep -i "content-type"
```

## Manifest Validation

### Extract and Validate manifest.json

```bash
url="https://example.com"
html=$(curl -sL "$url")

# Find manifest URL
manifest_href=$(echo "$html" | grep -oE '<link[^>]+rel="manifest"[^>]+href="[^"]*"' | grep -oE 'href="[^"]*"' | cut -d'"' -f2)

if [ -n "$manifest_href" ]; then
  # Handle relative URLs
  if [[ "$manifest_href" != http* ]]; then
    base_url=$(echo "$url" | grep -oE 'https?://[^/]+')
    manifest_href="${base_url}${manifest_href}"
  fi
  
  echo "Manifest URL: $manifest_href"
  echo ""
  
  # Fetch and parse manifest
  manifest=$(curl -sL "$manifest_href")
  
  echo "=== Manifest Icons ==="
  echo "$manifest" | jq -r '.icons[]? | "\(.sizes)\t\(.type // "n/a")\t\(.src)"' 2>/dev/null || echo "Failed to parse manifest JSON"
  
  echo ""
  echo "=== PWA Requirements Check ==="
  has_192=$(echo "$manifest" | jq -r '.icons[]? | select(.sizes == "192x192") | .src' 2>/dev/null)
  has_512=$(echo "$manifest" | jq -r '.icons[]? | select(.sizes == "512x512") | .src' 2>/dev/null)
  
  [ -n "$has_192" ] && echo "[OK] 192x192 icon found" || echo "[MISSING] 192x192 icon (required for PWA)"
  [ -n "$has_512" ] && echo "[OK] 512x512 icon found" || echo "[MISSING] 512x512 icon (required for PWA)"
else
  echo "[MISSING] No manifest.json link found"
fi
```

## Platform Requirements

### Browser Favicons

| Icon | Size | Format | Purpose |
|------|------|--------|---------|
| `favicon.ico` | 16x16, 32x32, 48x48 | ICO (multi-size) | Legacy browsers |
| `favicon.svg` | Scalable | SVG | Modern browsers |
| `favicon-16x16.png` | 16x16 | PNG | Browser tabs |
| `favicon-32x32.png` | 32x32 | PNG | Browser tabs (Retina) |

### Apple Touch Icons

| Icon | Size | Purpose |
|------|------|---------|
| `apple-touch-icon.png` | 180x180 | iOS home screen (default) |
| `apple-touch-icon-152x152.png` | 152x152 | iPad (non-Retina) |
| `apple-touch-icon-167x167.png` | 167x167 | iPad Pro |
| `apple-touch-icon-180x180.png` | 180x180 | iPhone (Retina) |

### Android/PWA (manifest.json)

| Size | Purpose |
|------|---------|
| 48x48 | Android notification |
| 72x72 | Android home screen |
| 96x96 | Android home screen |
| 144x144 | Android home screen |
| 192x192 | **Required** - PWA install |
| 512x512 | **Required** - PWA splash screen |

### Windows

| Icon | Size | Purpose |
|------|------|---------|
| `mstile-150x150.png` | 150x150 | Windows tiles |
| `browserconfig.xml` | - | Windows tile config |

## HTML Implementation

### Minimal Setup

```html
<link rel="icon" href="/favicon.ico" sizes="48x48">
<link rel="icon" href="/favicon.svg" type="image/svg+xml">
<link rel="apple-touch-icon" href="/apple-touch-icon.png">
<link rel="manifest" href="/manifest.json">
```

### Complete Setup

```html
<!-- Standard favicons -->
<link rel="icon" type="image/x-icon" href="/favicon.ico">
<link rel="icon" type="image/svg+xml" href="/favicon.svg">
<link rel="icon" type="image/png" sizes="16x16" href="/favicon-16x16.png">
<link rel="icon" type="image/png" sizes="32x32" href="/favicon-32x32.png">

<!-- Apple Touch Icons -->
<link rel="apple-touch-icon" href="/apple-touch-icon.png">
<link rel="apple-touch-icon" sizes="152x152" href="/apple-touch-icon-152x152.png">
<link rel="apple-touch-icon" sizes="167x167" href="/apple-touch-icon-167x167.png">
<link rel="apple-touch-icon" sizes="180x180" href="/apple-touch-icon-180x180.png">

<!-- PWA Manifest -->
<link rel="manifest" href="/manifest.json">

<!-- Windows -->
<meta name="msapplication-TileColor" content="#ffffff">
<meta name="msapplication-config" content="/browserconfig.xml">

<!-- Theme color -->
<meta name="theme-color" content="#ffffff">
```

### manifest.json Example

```json
{
  "name": "My App",
  "short_name": "App",
  "icons": [
    { "src": "/icons/icon-48x48.png", "sizes": "48x48", "type": "image/png" },
    { "src": "/icons/icon-72x72.png", "sizes": "72x72", "type": "image/png" },
    { "src": "/icons/icon-96x96.png", "sizes": "96x96", "type": "image/png" },
    { "src": "/icons/icon-144x144.png", "sizes": "144x144", "type": "image/png" },
    { "src": "/icons/icon-192x192.png", "sizes": "192x192", "type": "image/png", "purpose": "any maskable" },
    { "src": "/icons/icon-512x512.png", "sizes": "512x512", "type": "image/png", "purpose": "any maskable" }
  ],
  "theme_color": "#ffffff",
  "background_color": "#ffffff",
  "display": "standalone"
}
```

## Common Issues

### 1. Missing favicon.ico

**Problem**: No favicon.ico at root
**Solution**: Always include `/favicon.ico` - browsers request it automatically

```bash
# Check if favicon.ico exists
curl -sI "https://example.com/favicon.ico" | head -1
```

### 2. Wrong Content-Type

**Problem**: Server returns wrong MIME type
**Solution**: Configure server to return correct types

| Format | MIME Type |
|--------|-----------|
| ICO | `image/x-icon` or `image/vnd.microsoft.icon` |
| PNG | `image/png` |
| SVG | `image/svg+xml` |

### 3. Missing Apple Touch Icon

**Problem**: iOS shows screenshot instead of icon
**Solution**: Add apple-touch-icon link

```html
<link rel="apple-touch-icon" href="/apple-touch-icon.png">
```

### 4. PWA Install Fails

**Problem**: "Add to Home Screen" not available
**Solution**: Ensure manifest has 192x192 and 512x512 icons

### 5. Relative URLs in Manifest

**Problem**: Icons don't load from manifest
**Solution**: Use absolute paths or paths relative to manifest location

```json
{
  "icons": [
    { "src": "/icons/icon-192x192.png", "sizes": "192x192" }
  ]
}
```

### 6. Cache Issues

Browsers cache favicons aggressively. Force refresh:

```bash
# Add version query string
<link rel="icon" href="/favicon.ico?v=2">

# Or use different filename
<link rel="icon" href="/favicon-v2.ico">
```

## Full Audit Script

```bash
#!/bin/bash
# favicon-audit.sh - Full favicon audit

url="${1:-https://example.com}"
base_url=$(echo "$url" | grep -oE 'https?://[^/]+')

echo "=== Favicon Audit: $url ==="
echo ""

html=$(curl -sL "$url")

# Check favicon.ico
echo "## Direct favicon.ico Check"
status=$(curl -sI "$base_url/favicon.ico" 2>/dev/null | head -1 | cut -d' ' -f2)
printf "  /favicon.ico: %s\n" "${status:-unreachable}"

# Check HTML link tags
echo ""
echo "## HTML Icon Links"
echo "$html" | grep -oE '<link[^>]+rel="[^"]*icon[^"]*"[^>]*>' | while read -r line; do
  rel=$(echo "$line" | grep -oE 'rel="[^"]*"' | cut -d'"' -f2)
  href=$(echo "$line" | grep -oE 'href="[^"]*"' | cut -d'"' -f2)
  sizes=$(echo "$line" | grep -oE 'sizes="[^"]*"' | cut -d'"' -f2)
  printf "  %-20s %-12s %s\n" "$rel" "${sizes:-n/a}" "$href"
done

# Check apple-touch-icon
echo ""
echo "## Apple Touch Icons"
apple_icons=$(echo "$html" | grep -c 'apple-touch-icon')
if [ "$apple_icons" -gt 0 ]; then
  echo "$html" | grep -oE '<link[^>]+rel="apple-touch-icon[^"]*"[^>]*>' | while read -r line; do
    href=$(echo "$line" | grep -oE 'href="[^"]*"' | cut -d'"' -f2)
    sizes=$(echo "$line" | grep -oE 'sizes="[^"]*"' | cut -d'"' -f2)
    printf "  %-12s %s\n" "${sizes:-180x180}" "$href"
  done
else
  echo "  [MISSING] No apple-touch-icon found"
fi

# Check manifest
echo ""
echo "## PWA Manifest"
manifest_href=$(echo "$html" | grep -oE '<link[^>]+rel="manifest"[^>]+href="[^"]*"' | grep -oE 'href="[^"]*"' | cut -d'"' -f2)
if [ -n "$manifest_href" ]; then
  [[ "$manifest_href" != http* ]] && manifest_href="${base_url}${manifest_href}"
  echo "  URL: $manifest_href"
  
  manifest=$(curl -sL "$manifest_href" 2>/dev/null)
  if [ -n "$manifest" ]; then
    echo "  Icons:"
    echo "$manifest" | jq -r '.icons[]? | "    \(.sizes)\t\(.src)"' 2>/dev/null || echo "    [Failed to parse]"
    
    has_192=$(echo "$manifest" | jq -r '.icons[]? | select(.sizes == "192x192") | .src' 2>/dev/null)
    has_512=$(echo "$manifest" | jq -r '.icons[]? | select(.sizes == "512x512") | .src' 2>/dev/null)
    echo ""
    echo "  PWA Requirements:"
    [ -n "$has_192" ] && echo "    [OK] 192x192" || echo "    [MISSING] 192x192"
    [ -n "$has_512" ] && echo "    [OK] 512x512" || echo "    [MISSING] 512x512"
  fi
else
  echo "  [MISSING] No manifest.json link found"
fi

# Theme color
echo ""
echo "## Theme Color"
theme=$(echo "$html" | grep -oE '<meta[^>]+name="theme-color"[^>]+content="[^"]*"' | grep -oE 'content="[^"]*"' | cut -d'"' -f2)
echo "  theme-color: ${theme:-[NOT SET]}"
```

## Favicon Generators

- **RealFaviconGenerator**: https://realfavicongenerator.net/ (comprehensive)
- **Favicon.io**: https://favicon.io/ (simple, free)
- **PWA Asset Generator**: `npx pwa-asset-generator` (CLI)

## Related

- `seo/debug-opengraph.md` - Open Graph meta tag validation
- `tools/browser/playwright.md` - For JS-rendered pages
- `seo/site-crawler.md` - Bulk favicon auditing
