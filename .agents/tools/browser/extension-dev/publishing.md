---
description: Browser extension publishing - Chrome Web Store, Firefox Add-ons, Edge Add-ons submission
mode: subagent
tools:
  read: true
  write: true
  edit: true
  bash: true
  glob: true
  grep: true
  webfetch: true
  task: true
---

# Extension Publishing - Store Submission

<!-- AI-CONTEXT-START -->

## Store Accounts

| Store | Cost | Review | URL |
|-------|------|--------|-----|
| Chrome Web Store | $5 one-time | 1-3 days | https://chrome.google.com/webstore/devconsole |
| Firefox Add-ons | Free | 1-7 days | https://addons.mozilla.org/developers/ |
| Edge Add-ons | Free | 1-3 days | https://partner.microsoft.com/dashboard/microsoftedge/ |

**Automation**: `tools/browser/chrome-webstore-release.md` for CI/CD.

<!-- AI-CONTEXT-END -->

## Chrome Web Store

### Requirements

- [ ] Developer account ($5 one-time)
- [ ] Extension zipped from build output
- [ ] Privacy policy URL (required if requesting permissions)
- [ ] Screenshot (1280x800 or 640x400); promotional tile (440x280, optional)
- [ ] Single purpose clearly stated (Chrome policy requirement)

### Submission

1. Build: `npm run build` → `.output/chrome-mv3/`
2. Zip: `cd .output/chrome-mv3 && zip -r ../../extension.zip .`
3. Upload to Developer Dashboard, fill listing details, submit for review

### Automated Publishing

```bash
chrome-webstore-helper.sh setup                              # Interactive setup
chrome-webstore-helper.sh publish --manifest src/manifest.json  # Build + upload + publish
chrome-webstore-helper.sh status                             # Check status
```

Full CI/CD: `tools/browser/chrome-webstore-release.md`

### Common Rejection Reasons

| Reason | Fix |
|--------|-----|
| Not single purpose | State one purpose clearly in description |
| Excessive permissions | Remove unnecessary permissions; use `activeTab` |
| Missing privacy policy | Add hosted privacy policy URL |
| Misleading description | Description must match actual functionality |
| Broken functionality | Test before submission (`extension-dev/testing.md`) |
| Keyword stuffing | Don't repeat keywords in description |

## Firefox Add-ons

### Requirements

- [ ] Mozilla developer account (free)
- [ ] Extension as `.zip` or `.xpi`
- [ ] Source code zip if minified/bundled (required for review; include build instructions)
- [ ] `browser_specific_settings.gecko.id` in manifest:

```json
{
  "browser_specific_settings": {
    "gecko": {
      "id": "your-extension@example.com",
      "strict_min_version": "109.0"
    }
  }
}
```

### Submission

1. Build: `npm run build` → `.output/firefox-mv2/` or `.output/firefox-mv3/`
2. Zip build output; upload source code zip separately for reviewer
3. Upload to https://addons.mozilla.org/developers/, fill listing details, submit

**Note**: Firefox supports MV2 and MV3; MV2 has broader API support currently.

## Edge Add-ons

### Requirements

- [ ] Microsoft Partner Center account (free)
- [ ] Same `.zip` as Chrome (Edge uses Chromium)

### Submission

1. Use Chrome build (`.output/chrome-mv3/`)
2. Upload to Microsoft Partner Center, fill listing details, submit

## Listing Optimisation

**Description**: Value proposition first; 3-5 feature bullets; explain each permission; include support info.

**Screenshots**: Show popup/sidebar/content overlay in action; captions per feature; light + dark if supported; 1 minimum, 3-5 recommended.

**Icon**: 128x128 PNG; simple and recognisable at small sizes. See `tools/mobile/app-dev-assets.md` for generation, `product/ui-design.md` for standards.

## Version Management

- Semantic versioning (`major.minor.patch`) in `manifest.json` (and `package.json` if applicable)
- Chrome Web Store only publishes on version change
- See `chrome-webstore-release.md` for version-triggered CI

## Related

- `tools/browser/chrome-webstore-release.md` — Chrome Web Store automation
- `tools/browser/extension-dev/testing.md` — Pre-submission testing
- `tools/mobile/app-dev-assets.md` — Icon and screenshot generation
- `product/monetisation.md` — Revenue models for extensions
