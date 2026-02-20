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

## Quick Reference

- **Purpose**: Submit extensions to Chrome Web Store, Firefox Add-ons, and Edge Add-ons
- **Chrome**: $5 one-time developer fee, review in 1-3 days
- **Firefox**: Free, review in 1-7 days
- **Edge**: Free (uses same package as Chrome), review in 1-3 days
- **Automation**: See `tools/browser/chrome-webstore-release.md` for CI/CD

**Store accounts**:

| Store | Cost | URL |
|-------|------|-----|
| Chrome Web Store | $5 one-time | https://chrome.google.com/webstore/devconsole |
| Firefox Add-ons | Free | https://addons.mozilla.org/developers/ |
| Edge Add-ons | Free | https://partner.microsoft.com/dashboard/microsoftedge/ |

<!-- AI-CONTEXT-END -->

## Chrome Web Store

### Requirements

- [ ] Developer account ($5 one-time registration)
- [ ] Extension packaged as `.zip` of the build output
- [ ] Privacy policy URL (required for extensions requesting permissions)
- [ ] At least one screenshot (1280x800 or 640x400)
- [ ] Promotional tile (440x280, optional but recommended)
- [ ] Detailed description explaining what the extension does
- [ ] Category selected
- [ ] Single purpose clearly stated (Chrome policy requirement)

### Submission Process

1. Build: `npm run build` (produces `.output/chrome-mv3/`)
2. Zip: `cd .output/chrome-mv3 && zip -r ../../extension.zip .`
3. Upload to Chrome Web Store Developer Dashboard
4. Fill in listing details (description, screenshots, category)
5. Submit for review

### Automated Publishing

See `tools/browser/chrome-webstore-release.md` for full CI/CD automation:

```bash
# Interactive setup
chrome-webstore-helper.sh setup

# Publish (build + zip + upload + publish)
chrome-webstore-helper.sh publish --manifest src/manifest.json

# Check status
chrome-webstore-helper.sh status
```

### Common Rejection Reasons

| Reason | Fix |
|--------|-----|
| Not single purpose | Clearly state one purpose in description |
| Excessive permissions | Remove unnecessary permissions, use `activeTab` |
| Missing privacy policy | Add hosted privacy policy URL |
| Misleading description | Description must match actual functionality |
| Broken functionality | Test thoroughly before submission |
| Keyword stuffing | Don't repeat keywords in description |

## Firefox Add-ons

### Requirements

- [ ] Mozilla developer account (free)
- [ ] Extension packaged as `.zip` or `.xpi`
- [ ] Source code (if extension is minified/bundled — required for review)
- [ ] Description and screenshots

### Submission Process

1. Build: `npm run build` (produces `.output/firefox-mv2/` or `firefox-mv3/`)
2. Zip the build output
3. Upload to https://addons.mozilla.org/developers/
4. Upload source code zip (build tools + source for reviewer)
5. Fill in listing details
6. Submit for review

### Firefox-Specific Notes

- Firefox reviewers may request source code for bundled extensions
- Include build instructions in a README within the source zip
- Firefox supports both MV2 and MV3 (MV2 has broader API support currently)
- `browser_specific_settings.gecko.id` required in manifest for Firefox

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

## Edge Add-ons

### Requirements

- [ ] Microsoft Partner Center account (free)
- [ ] Same `.zip` as Chrome (Edge uses Chromium)
- [ ] Description and screenshots

### Submission Process

1. Use the same Chrome build (`.output/chrome-mv3/`)
2. Upload to Microsoft Partner Center
3. Fill in listing details
4. Submit for review

Edge accepts Chrome extensions with minimal or no changes.

## Listing Optimisation

### Description

- First sentence: Clear value proposition
- Bullet points: Key features (3-5)
- Permissions explanation: Why each permission is needed
- Support information: How to get help

### Screenshots

- Show the extension in action (popup, sidebar, content overlay)
- Include captions explaining features
- Show both light and dark mode if supported
- Minimum 1, recommended 3-5

### Icon

- 128x128 PNG (required for Chrome Web Store)
- Simple, recognisable at small sizes
- Consistent with extension's brand
- See `mobile-app-dev/assets.md` for icon generation guidance

## Version Management

- Use semantic versioning (major.minor.patch)
- Update version in `manifest.json` (and `package.json` if applicable)
- Chrome Web Store only publishes when version changes
- See `chrome-webstore-release.md` for version-triggered CI

## Related

- `tools/browser/chrome-webstore-release.md` - Chrome Web Store automation
- `browser-extension-dev/testing.md` - Pre-submission testing
- `mobile-app-dev/assets.md` - Icon and screenshot generation
- `mobile-app-dev/monetisation.md` - Revenue models for extensions
