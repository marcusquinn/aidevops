## Task

Expand `.agents/tools/research/linkup.md` with Linkup's official per-endpoint best-practice and for-agents guidance: query writing, depth selection, fetch/extract/research/tasks request and response shapes, polling cadence, limits, LinkedIn routing, SerpApi migration mapping and use-case routing.

## Why

The user supplied Linkup's best-practice docs (search, fetch, research, tasks, extract, SerpApi migration, use cases). The current doc gives a blanket "start with `depth: fast`" rule and "enable `renderJs` only after failure", which the vendor guidance qualifies: `fast`/`flash` send keywords straight to the index with no LLM interpretation, so instruction-style prompts need `standard`/`deep`; and `renderJs: true` is recommended first for unknown sites. LinkedIn profile/company URLs must go through `/search`, not `/fetch`. Without this guidance agents waste credits and get empty results.

## How

- Add sections to `.agents/tools/research/linkup.md`: "Writing queries" (keyword vs instruction prompts, role → source scope → fields → format, breadth in `standard`, dependent steps in `deep`), corrected depth/cost discipline, fetch parameters/response/limits, research polling and mode choice, tasks wire shape and polling, extract beta shape, LinkedIn exception, SerpApi mapping, use-case routing.
- Verify contested facts against `https://api.linkup.so/v1/openapi.json` (spec lists `mode: auto` as default; `depth` required; `/v1/tasks` bare array 1-100; beta `/v1/rewind/search|fetch` with `asOf`).
- Allowlist `prompt.linkup.so` in `.agents/configs/allowed-urls.txt` if cited.

## Files to modify

### Files Scope

- `.agents/tools/research/linkup.md`
- `.agents/configs/allowed-urls.txt`
- `TODO.md`

## Acceptance

- Doc covers query writing, depth choice, fetch/research/tasks/extract shapes and polling, LinkedIn exception, SerpApi mapping, with source links.
- No contradictions with the OpenAPI spec.
- Stays under 500 lines; markdownlint clean.

## Verification

- `markdownlint-cli2 .agents/tools/research/linkup.md`
- `.agents/scripts/linters-local.sh --changed`
