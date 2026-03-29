---
description: Debug and validate favicon setup across platforms and PWA manifests
mode: subagent
tools:
  read: true
  bash: true
  grep: true
  webfetch: true
---

# Favicon Debugger

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Method**: HTML parsing via curl + grep, manifest.json validation
- **Reference**: https://opengraphdebug.com/favicon
- **Essential**: `favicon.ico`, `apple-touch-icon.png`, manifest icons (192x192 + 512x512 PNG)

<!-- AI-CONTEXT-END -->

## Quick Checks

```bash
# Extract all favicon/icon links
curl -sL "https://example.com" \
  | grep -ioE "<link[^>]*rel=['\"](icon|shortcut icon|apple-touch-icon|manifest)['\"][^>]*>" \
  | head -20

# Check favicon.ico status
curl -sI "https://example.com/favicon.ico" | head -1 | cut -d' ' -f2
```

## Platform Requirements

| Icon | Size | Format | Platform |
|------|------|--------|----------|
| `favicon.ico` | 16/32/48 | ICO (multi) | All browsers (legacy) |
| `favicon.svg` | Scalable | SVG | Modern browsers |
| `favicon-16x16.png` | 16x16 | PNG | Browser tabs |
| `favicon-32x32.png` | 32x32 | PNG | Browser tabs (Retina) |
| `apple-touch-icon.png` | 180x180 | PNG | iOS home screen (default) |
| `apple-touch-icon-152x152.png` | 152x152 | PNG | iPad (non-Retina) |
| `apple-touch-icon-167x167.png` | 167x167 | PNG | iPad Pro |
| manifest icon | 192x192 | PNG | **Required** — PWA install |
| manifest icon | 512x512 | PNG | **Required** — PWA splash |
| manifest icon | 48/72/96/144 | PNG | Android (optional) |
| `mstile-150x150.png` | 150x150 | PNG | Windows tiles (`browserconfig.xml`) |

## HTML Implementation

Minimal `<head>` setup:

```html
<link rel="icon" href="/favicon.ico" sizes="48x48">
<link rel="icon" href="/favicon.svg" type="image/svg+xml">
<link rel="apple-touch-icon" href="/apple-touch-icon.png">
<link rel="manifest" href="/manifest.json">
```

For complete setup: add sized PNG icons from the table above, `<meta name="theme-color">`, and `<meta name="msapplication-config" content="/browserconfig.xml">`.

### manifest.json Example

```json
{
  "name": "My App",
  "short_name": "App",
  "icons": [
    { "src": "/icons/icon-192x192.png", "sizes": "192x192", "type": "image/png", "purpose": "any maskable" },
    { "src": "/icons/icon-512x512.png", "sizes": "512x512", "type": "image/png", "purpose": "any maskable" }
  ],
  "theme_color": "#ffffff",
  "background_color": "#ffffff",
  "display": "standalone"
}
```

## Common Issues

| # | Problem | Solution |
|---|---------|----------|
| 1 | Missing `favicon.ico` | Always serve `/favicon.ico` — browsers request it automatically |
| 2 | Wrong Content-Type | ICO: `image/x-icon`, PNG: `image/png`, SVG: `image/svg+xml` |
| 3 | Missing Apple Touch Icon | Add `<link rel="apple-touch-icon" href="/apple-touch-icon.png">` |
| 4 | PWA install fails | Ensure manifest has 192x192 and 512x512 icons |
| 5 | Manifest URL resolution | Use absolute paths (`/icons/icon-192.png`); relative resolves from manifest location |
| 6 | Cache issues | Add version query string: `href="/favicon.ico?v=2"` |

## Audit Script

```bash
#!/bin/bash
url="${1:-https://example.com}"
base_url=$(echo "$url" | grep -oE 'https?://[^/]+')
html=$(curl -sL "$url")
echo "=== Favicon Audit: $url ==="
status=$(curl -sI "$base_url/favicon.ico" 2>/dev/null | head -1 | cut -d' ' -f2)
echo "favicon.ico: ${status:-unreachable}"
# All icon links (standard + apple-touch)
echo "$html" | grep -oE '<link[^>]+rel="[^"]*icon[^"]*"[^>]*>' | while read -r line; do
  href=$(echo "$line" | grep -oE 'href="[^"]*"' | cut -d'"' -f2)
  sizes=$(echo "$line" | grep -oE 'sizes="[^"]*"' | cut -d'"' -f2)
  echo "  ${sizes:-n/a} $href"
done
echo "$html" | grep -oE '<link[^>]+rel="apple-touch-icon[^"]*"[^>]*>' | while read -r line; do
  href=$(echo "$line" | grep -oE 'href="[^"]*"' | cut -d'"' -f2)
  sizes=$(echo "$line" | grep -oE 'sizes="[^"]*"' | cut -d'"' -f2)
  echo "  apple ${sizes:-180x180} $href"
done
# PWA manifest
manifest_href=$(echo "$html" | grep -oE '<link[^>]+rel="manifest"[^>]+href="[^"]*"' | grep -oE 'href="[^"]*"' | cut -d'"' -f2)
if [ -n "$manifest_href" ]; then
  [[ "$manifest_href" != http* ]] && manifest_href="${base_url}${manifest_href}"
  manifest=$(curl -sL "$manifest_href" 2>/dev/null)
  echo "manifest: $manifest_href"
  echo "$manifest" | jq -r '.icons[]? | "  \(.sizes)\t\(.src)"' 2>/dev/null || echo "  [parse error]"
  has_192=$(echo "$manifest" | jq -r '.icons[]? | select(.sizes == "192x192") | .src' 2>/dev/null)
  has_512=$(echo "$manifest" | jq -r '.icons[]? | select(.sizes == "512x512") | .src' 2>/dev/null)
  [ -n "$has_192" ] && echo "  [OK] 192x192" || echo "  [MISSING] 192x192"
  [ -n "$has_512" ] && echo "  [OK] 512x512" || echo "  [MISSING] 512x512"
else
  echo "  [MISSING] No manifest link found"
fi
theme=$(echo "$html" | grep -oE '<meta[^>]+name="theme-color"[^>]+content="[^"]*"' | grep -oE 'content="[^"]*"' | cut -d'"' -f2)
echo "theme-color: ${theme:-[NOT SET]}"
```

## Generators

- **RealFaviconGenerator**: https://realfavicongenerator.net/ (comprehensive)
- **Favicon.io**: https://favicon.io/ (simple, free)
- **PWA Asset Generator**: `npx pwa-asset-generator` (CLI)

## Related

- `seo/debug-opengraph.md` — Open Graph meta tag validation
- `tools/browser/playwright.md` — For JS-rendered pages
- `seo/site-crawler.md` — Bulk favicon auditing
