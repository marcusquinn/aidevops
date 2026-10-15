## What

Remove GenAIPro from aidevops' shipped agent guidance: delete the "Reviewed and
Not Routed" section, whose only row is GenAIPro, from
`.agents/content/media-generation-providers.md`.

## Why

Maintainer request after the t18694 review (#34713, PR #34714) found that
GenAIPro's capacity appears to come from pooled consumer accounts. A
do-not-route entry is no longer wanted in the provider surface.

## How

- Delete the `## Reviewed and Not Routed` heading and its table.
- Keep the generic "Reject consumer-subscription resale" decision check; it
  does not name GenAIPro and still guards future gateway reviews.
- Leave historical planning records (TODO.md, `todo/tasks/t18693-brief.md`,
  `todo/tasks/t18694-brief.md`) unchanged as the audit trail.

### Files Scope

- `.agents/content/media-generation-providers.md`

## Acceptance

- `git grep -n -i genaipro -- .agents` returns nothing.
- `markdownlint-cli2` passes on the changed file.

## Verification

`git grep -n -i genaipro -- .agents; npx markdownlint-cli2 .agents/content/media-generation-providers.md`

Ref #34713
