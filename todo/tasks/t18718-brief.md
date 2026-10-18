## What

Make README badge layout errors hard to ship. A managed app README (rendered
before GH#34145) still shows the wide `docs/metrics/badges/languages.svg`
chart inline with the small LOC/dependency badges, so GitHub bottom-aligns the
badges against the chart. GH#34145 fixed the canonical template, but:

1. `workflows/readme-create-update.md` and `scripts/commands/readme.md` only
   say badge sections "should reference" the metric SVGs. They never require
   `readme-badges-helper.sh inject` / `check` during README create/update, so
   an AI can hand-compose the block or leave a stale render in place.
2. `aidevops/badges.md` "How the marker block works" still shows the chart
   inline with the badges — the exact layout that renders badly.
3. Nothing enforces the layout for repo-owned `.github/readme-badges.md.tmpl`
   templates or hand-edited blocks.

## How

- `.agents/scripts/readme-badges-helper.sh`: add a layout guard. `render` /
  `inject` refuse a template whose rendered block puts the languages chart in
  the same Markdown paragraph as other content; `check` reports the same
  layout fault on an existing block (in addition to drift).
- `.agents/aidevops/badges.md`: correct the example and document the layout rule.
- `.agents/workflows/readme-create-update.md`, `.agents/scripts/commands/readme.md`:
  require `readme-badges-helper.sh inject` + `check` on every README create or
  update; never hand-write the marker block; chart on its own paragraph.

### Files Scope

- `.agents/scripts/readme-badges-helper.sh`
- `.agents/aidevops/badges.md`
- `.agents/workflows/readme-create-update.md`
- `.agents/scripts/commands/readme.md`

## Acceptance

- Rendering a template with the chart inline exits non-zero with a layout message.
- `check` on a README whose block has the chart inline reports the layout fault.
- Canonical template render and existing badge tests still pass.

## Verification

`shellcheck .agents/scripts/readme-badges-helper.sh`;
`bash .agents/scripts/tests/test-readme-badges-resilience.sh`;
render with a temporary inline-chart template to confirm the guard.
