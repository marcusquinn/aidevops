---
description: Typography selection and font pairing — role-first choices, freely usable font licences, self-hosting without third-party requests, rendered verification
mode: subagent
tools:
  read: true
  write: true
  edit: true
  bash: true
  glob: false
  grep: true
  webfetch: true
  task: false
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2026 Marcus Quinn -->

# Font Pairing and Typography Selection

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Use when**: choosing fonts for a new site, app or brand; replacing a font;
  "font pairing", "Fontjoy", "free fonts", "Google Fonts", "self-host fonts".
- **Skip when**: repo `DESIGN.md` or `context/brand-identity.toon` already names
  the fonts and the task does not change them. Preserve them.
- **Order**: roles → one family or a pair → licence per family → self-hosted
  delivery → rendered check → record in `DESIGN.md`.
- **Defaults**: one well-made family (or the system stack) before a pair; no
  third-party font host for visitors; a licence file for every shipped family.
- **Owners**: `design-md.md` holds typography tokens; `brand-identity.md` holds
  `heading_font`/`body_font`/`mono_font`; `workflows/ui-verification.md` holds
  rendered checks. This file adds no schema, package or helper.

<!-- AI-CONTEXT-END -->

## 1. Roles before faces

List the jobs type must do on this surface: display/headline, body or UI text,
labels, data and numerals, code, and any brand wordmark. Then decide by visitor
mode (`distinctive-ui.md` §1):

- **Persuade / experience** (marketing, launches, portfolios): display type may
  carry the voice; a contrasting display face can earn its cost.
- **Operate / read** (apps, dashboards, docs, articles): stability, scanability and
  measure come first. One family with a fixed role scale is often right.

Add a second family only for a job the first cannot do (a serif reading face for
long articles, a display face for brand voice, a monospace for code). Give each
face one job and keep it; do not mix two faces in one headline or add a third for
labels or numbers. A variable family with true weights and italics often removes
the need for a pair. System stacks (`system-ui`, `ui-sans-serif`, `ui-monospace`)
are valid choices with no download or licence step.

## 2. Pairing: contrast with shared structure

Fontjoy's method states the problem well: faces that are nearly the same look like
a mistake, and faces that differ on every axis look accidental. Pick fonts that
differ on one or two axes and share the rest.

| Share (usually) | Contrast (pick one or two) |
|-----------------|----------------------------|
| x-height and proportions, so sizes sit together | Classification: serif with sans, or slab with grotesque |
| Construction or era (humanist, geometric, grotesque, transitional) | Weight or width at display sizes |
| Aperture and stroke rhythm | Formality: a lively display face over a quiet text face |

Superfamilies designed together (serif, sans and mono from one project) share
metrics by design and are a safe start; check that each member covers your
languages. Body legibility outranks pairing: test the text face at small sizes,
on low-contrast screens and in your languages before judging the pair.

### Using Fontjoy

[Fontjoy](https://fontjoy.com/) generates three-font combinations that end in a
body face, with Generate, Lock and Edit controls and editable sample text. The
model ([Jack000/fontjoy](https://github.com/Jack000/fontjoy), MIT, 2017) embeds
1,883 Google web font variants as visual feature vectors and rewards pairs that are
similar on some features and different on others, with body legibility weighted
second.

Use it for divergent exploration: lock the face that carries the brand, generate
alternatives, type the real product name and copy, and shortlist two or three
pairs. Then evaluate in the product, because the tool does not check:

- licence terms, language and glyph coverage, true italics, tabular figures,
  hinting, file size or families published after its 2017 dataset;
- how the pair behaves at your sizes, density and both themes.

Nothing from Fontjoy ships with the product. Do not scrape it or call it as an
API. `tools/design/ui-ux-catalogue.toon` pairings are style starting points, and
some name commercial or platform fonts (Helvetica, SF Pro): check every licence
the same way.

## 3. Freely usable fonts: check the licence per family

"Free to download" is not a licence. Read the licence file shipped with each
family, at the version you will use, and confirm it covers the intended use (web
embedding, apps, logos, print, client work).

| Licence | Typical source | What to check |
|---------|----------------|---------------|
| SIL Open Font License 1.1 (OFL) | Most Google Fonts families (1,000+ under `ofl/` in google/fonts), many foundry open releases | Free to use, embed, self-host and bundle; the font may not be sold by itself; modified versions must drop any Reserved Font Name; keep the copyright and licence with distributed files. Documents and artwork made with the font are not restricted |
| Apache-2.0 | A few dozen Google Fonts families (`apache/`) | Permissive; keep the licence and any NOTICE with the files |
| Ubuntu Font Licence (UFL) | Ubuntu families (`ufl/`) | Different terms from OFL; read them before modifying or redistributing |
| "Free for personal use", demo or trial | Font marketplaces | Not for commercial, client or brand work without a purchased licence. Reject for shipped work |
| Platform or OS fonts (SF Pro, Segoe UI, Helvetica) | Installed on the device | Reference through a system stack; do not self-host, embed or redistribute the files |

The google/fonts repository groups families by licence directory (`ofl/`,
`apache/`, `ufl/`; checked 2026-10-25), so "on Google Fonts" does not mean one set
of terms. npm wrappers such as Fontsource carry a package licence for their code;
each font keeps its own licence. For a brand mark, outlined artwork is normally a
document made with the font, but trademark and name rules still apply; record the
licence beside the mark's source files.

## 4. Delivery without third-party requests

Loading fonts from a public CDN stylesheet (for example Google Fonts or Fontshare
`<link>` tags) makes every visitor's browser request the font host, sending IP
address and request metadata to a third party and adding a runtime dependency.
Default to:

- **Self-hosting**: serve WOFF2 files from the site's own origin with the licence
  text beside them. Next.js `next/font/google` downloads Google Fonts at build time
  and self-hosts them, so the browser sends no request to Google; `next/font/local`
  serves files you supply. Other stacks: Fontsource packages or files from the
  family's own release, plus `@font-face`.
- **Only what renders**: request the used weights, styles and subsets; prefer one
  variable file over three or more static files. Do not subset away scripts the
  site's languages need.
- **No invisible text or jumps**: `font-display: swap` (or `optional` for
  non-critical faces), preload only the critical file, and a metric-matched
  fallback (`size-adjust`, `ascent-override` or the framework's fallback
  adjustment) to limit layout shift.
- **Numerals and features**: enable `font-variant-numeric: tabular-nums` for data,
  prices and aligned columns; record the feature as a `fontFeature` token.

## 5. Verify in the rendered product

Screenshots of a fallback face are not typography evidence. Use
`browser-qa-helper.sh screenshot --measure-file` (contract:
`tools/browser/browser-qa.md` "Step 3: Screenshot Capture") with a trusted function
such as:

```javascript
() => {
  const files = performance.getEntriesByType('resource')
    .filter((e) => /\.(woff2?|otf|ttf)(\?|$)/i.test(e.name));
  return {
    loaded: [...document.fonts].filter((f) => f.status === 'loaded')
      .map((f) => `${f.family} ${f.weight} ${f.style}`),
    fontHosts: [...new Set(files.map((e) => new URL(e.name).host))],
    pageHost: location.host,
  };
}
```

Pass when `loaded` matches the faces in `DESIGN.md`, `fontHosts` contains only
the page's own or an explicitly accepted host, and the screenshots show no missing
glyphs, synthesised bold/italic, clipped headings or reflow. Stress long headings,
translated copy, 200% text zoom and both themes as in `workflows/ui-verification.md`.

## 6. Record the decision

In `DESIGN.md`, set `typography` tokens per role (`fontFamily` with fallback stack,
`fontFeature` where used). In its Markdown rationale, record: roles, pairing reason,
alternatives considered, family source and version, licence, hosting method and
fallback. Update `context/brand-identity.toon` font fields when the brand changes.

## Provenance

Adapted, not copied: Fontjoy's similarity-with-contrast pairing method
(Jack Qiao, MIT, `3f47f4c2890cd5ede20f728f01fb54d6ad7c97f2`); Impeccable's
typography roles, stress and delivery questions (`impeccable.md`); Taste Skill's
one-family-or-two rule, tabular figures and rendered-family check (`taste-skill.md`).
Taste Skill's CDN `<link>` loading is deliberately not adopted.
