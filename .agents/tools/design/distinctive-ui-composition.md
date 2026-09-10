<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2026 Marcus Quinn -->
<!-- SPDX-FileCopyrightText: 2026 Hallmark contributors -->

# Distinctive UI Composition

Load from `distinctive-ui.md` when choosing a page's arrangement. Inspired by
Hallmark's structure-first approach; provenance and MIT notice: `hallmark.md`.
The existing `ui-ux-catalogue.toon` and brand/style library supply visual styles;
this reference answers a different question: **what should the user encounter,
in what order, and why?**

## Select from the job and evidence

Choose a family, not a template. These are options, not an exhaustive menu or a
requirement to change an existing working pattern.

| Family | Fits | Content needed | Avoid / adapt when |
|--------|------|----------------|--------------------|
| Task workspace | Dashboards, editors, operational tools | Primary task, controls, status and recovery | Marketing ornament competes with frequent work |
| Product demonstration | Tools whose value is visible in use | Real screenshot, sample interaction or truthful demo | No functioning demo exists; don't fabricate one |
| Evidence-led | Comparison, research, proven outcomes | Sourced measures with units, dates and context | No verified numbers; choose another family |
| Editorial narrative | Articles, explanations, considered decisions | Coherent argument, headings and supporting evidence | Users need direct lookup or immediate action |
| Process sequence | Onboarding, how-it-works, guided services | Meaningful ordered steps, progress and exit/recovery | Items are independent; numbering implies false order |
| Questions and answers | Objections, support, eligibility | Actual questions with useful answers | Essential content becomes buried in collapsed panels |
| Catalogue or portfolio | Inventory, work, resources | Comparable items, useful metadata and detail routes | Artificially unequal cards impede comparison |
| Index and discovery | Documentation hubs, ecosystems, directories | Real destinations, categories and search | A short page gets unnecessary navigation machinery |
| Image-led | Physical products, places, visual work | Relevant rights-cleared imagery and useful captions | Generic stock hides the actual offering |
| Statement or letter | A campaign, founder message, focused proposition | Distinct point of view and an understandable next action | Style obscures what the product does |
| Spatial explanation | Maps, systems, relationships | Meaningful spatial model plus accessible linear alternative | Diagram is only decoration or unusable on small screens |
| Playground | APIs, components, configurable products | Working controls, examples and reset/error states | Interactive-looking controls are inert |

A SaaS demo, bakery catalogue and operational dashboard should not get the same
hero/features/pricing recipe merely because they share a CSS framework. Conversely,
two settings pages in one application should share familiar structure and controls.

## Compose the whole surface

Describe these decisions together before fine styling:

1. **Entry**: What establishes purpose and the next action? A hero is optional.
   Keep essential meaning readable on the first screen without forcing every
   element above the fold or shrinking text to satisfy an arbitrary ratio.
2. **Information order**: What must be understood before the next step? Place
   proof near its claim, detail near its action, and errors near their cause.
3. **Navigation**: Match actual destinations and task frequency. Compact links
   suit a few destinations; grouped navigation/search suits a large collection;
   a stable rail can suit an application. Hidden command navigation is an
   enhancement, not the sole route for users who do not know the shortcut.
4. **Body**: Use a table for comparison, a list for a sequence, a grid for peers,
   prose for explanation. Cards need meaningful grouping, not decoration alone.
5. **Rhythm**: Make spacing express relationships. Repeated tasks benefit from
   consistency; different narrative sections can vary density and emphasis.
   Asymmetry is optional and must not corrupt reading/focus order.
6. **Close**: Offer the appropriate next step: purchase, visit, try, read, contact,
   or return to work. A footer contains real destinations and required notices,
   not empty columns invented to resemble a large company.

Choose component variants within the existing system. A large sitemap may justify
columns; three genuinely comparable features may justify three equal cards.
Do not replace usable conventions solely because they are common.

## Explore without creating a new default

When alternatives are requested, vary information order, evidence placement,
density, navigation and component arrangement—not only colour or border radius.
Compare two or three viable directions against the same content and constraints.
Explain the trade-off and recommend one. Do not render every option by default.

For an established product, keep tokens and interaction language stable. For a
new identity, use `brand-identity.md` and `colour-palette.md`; catalogue archetypes
are starting points, not compulsory themes. Use bespoke composition when the
brief demands it. Novelty does not justify changing licensed brand colours,
unreadable display type, extra dependencies or decorative motion.

## Stress the arrangement before polishing

- Long headings, translated labels, empty inventory, dense data and user text.
- Narrow screens, 200% text scaling, focus order and touch access without hover.
- Image intrinsic sizing, flexible grid minimums and wrapping. Use local
  `min-width: 0` / `minmax(0, 1fr)` where the content needs to shrink, not as a
  substitute for inspecting the actual overflow.
- Sticky headers, in-page navigation and focused controls: account for real
  header height, including wrapped/localized content, so nothing is obscured.
- Content remains understandable with images unavailable and optional motion
  disabled. Do not force all links onto one line or hide them at narrow widths;
  reflow, wrap or use an accessible alternate navigation appropriate to the task.

Record the chosen arrangement, close alternatives and responsive allowances in
the existing brief / `DESIGN.md`. Verify the rendered result; code inspection
cannot establish visual balance.
