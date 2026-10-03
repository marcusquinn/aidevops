## What

Add layout checks to the declarative browser QA journey (`browser-qa-helper.sh journey`):

1. A new `layout` step that compares the rendered boxes of two elements.
2. Custom viewport widths, in addition to the named `desktop` (1440×900) and `mobile` (375×667).

## Why

An interactive session had to confirm that a WordPress admin search field matched its button's height and top edge at 1440, 1024, 782, 600 and 375px, on two WordPress versions (core buttons are 30px on WP 6.2 desktop and 40px on WP 7 and on small screens). The current steps (`navigate`, `click`, `visible`, `count`, `text`, `attribute`, `no-horizontal-overflow`) cannot assert geometry, and only two fixed viewports exist, so the session wrote a one-off Playwright script (login, loop widths, `getBoundingClientRect()` on both elements, compare height/top, check overflow, clip screenshots). With these two additions the same check is a reusable, read-only journey config for any app.

## How

Files to modify:

- `.agents/scripts/browser-qa-journey-config.mjs`
  - `STEP_FIELDS`: add `layout: { selector: 'text', compare: 'text', match: 'layoutMatch' }` (names are a suggestion). `match` is a non-empty array of unique edges from a fixed allowlist: `top`, `bottom`, `left`, `right`, `width`, `height`, `centerX`, `centerY`. Optional `tolerancePx` is an integer 0–8 (default 1). Add the matching check to `FIELD_CHECKS` and handle optional fields in step validation.
  - `validateViewports()`: also accept objects `{ "name": "tablet-782", "width": 782, "height": 900 }`, with integer bounds (e.g. width 320–3840, height 320–2160), unique names and a cap on the count (e.g. 8). Named strings `desktop`/`mobile` keep working unchanged.
- `.agents/scripts/browser-qa-journey-steps.mjs`
  - Add a `layout` handler following the existing `pollUntil` pattern: read `boundingBox()` of the first match for `selector` and `compare` (with `probeTimeout`), compare each requested edge within tolerance, and fail with a message that names the edges and measured values, e.g. `layout assertion failed: height 30 vs 40`. Never evaluate config-supplied code.
- `.agents/scripts/browser-qa-journey.mjs`
  - `runViewport()` currently uses `VIEWPORTS[viewportName]`; resolve custom viewport objects too, and report the viewport name and size in each result.
- `.agents/tools/browser/browser-qa.md`: document the `layout` step and custom viewports with an example (field and button same `top` and `height`, plus `no-horizontal-overflow`, at 1440/782/375).
- `.agents/scripts/tests/test-browser-qa-journey.sh`: extend the existing validation cases (accept valid `layout` steps and custom viewports, reject unknown edges, out-of-range tolerance or sizes, duplicate names). This extends an existing suite; it does not add new test infrastructure.

Reference pattern: the existing `count`/`attribute` handlers and their `STEP_FIELDS` entries; `no-horizontal-overflow` for a page-level geometry check.

### Files Scope

- `.agents/scripts/browser-qa-journey-config.mjs`
- `.agents/scripts/browser-qa-journey-steps.mjs`
- `.agents/scripts/browser-qa-journey.mjs`
- `.agents/tools/browser/browser-qa.md`
- `.agents/scripts/tests/test-browser-qa-journey.sh`

## Acceptance criteria

- A journey config with a `layout` step passes when both boxes match within tolerance and fails with a redacted, specific message otherwise.
- `viewports` accepts a mix of `"desktop"` and `{ name, width, height }` objects; invalid entries fail validation before any browser launch or sign-in.
- Existing configs (named viewports only, existing step types) behave unchanged. `SCHEMA_VERSION` stays 1 if the change is purely additive.
- `test-browser-qa-journey.sh` passes; ShellCheck is clean for any touched shell.

## Verification

- `bash .agents/scripts/tests/test-browser-qa-journey.sh`
- Run a journey against a local isolated page with a form field next to a button: assert `match: ["top", "height"]` at viewports 1440, 782 and 375, then change one element's CSS height and confirm the step fails with both values in the message. No external authenticated site or credentials are needed for this geometry verification.

## Recovery context

The unattended backlog mission restores the canonical Files Scope above without changing the requested implementation. The previous launch on 2026-10-01 ended with `CLAIM_RELEASED reason=worker_ownership_lost` and a terminal lease. Verify current ownership normally before continuation; do not bypass a live owner or an external-directory permission boundary.

<!-- aidevops:origin:interactive -->
