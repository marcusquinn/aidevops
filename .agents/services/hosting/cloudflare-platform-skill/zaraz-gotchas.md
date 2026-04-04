<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Cloudflare Zaraz — Gotchas & Debugging

## Debugging

Enable debug: dashboard toggle or `zaraz.debug = true`. Check trigger conditions, tool enabled status, browser console, `zaraz.consent.getAll()` for consent issues.

## Common Issues

- **Trigger not firing**: Verify CSS selector matches, check trigger type (DOM Ready fires after Pageview), confirm tool is enabled.
- **Consent blocking events**: Call `zaraz.consent.getAll()` to inspect state; ensure consent modal shown before tracking.
- **Data layer not accessible**: Set `window.zaraz.dataLayer` before Zaraz initialises; access via `{{client.__zarazTrack.key}}` in trigger conditions.
- **Request size exceeded**: 100 KB limit per request; split large payloads or reduce event properties.
- **Custom component not loading**: Check component export default class, verify `handleEvent` async signature, confirm HTTPS endpoint.
