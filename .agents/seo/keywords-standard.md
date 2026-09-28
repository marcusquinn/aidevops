---
name: keywords-standard
description: >
  context/keywords.md search-targets standard -- per-repo target keywords (SEO),
  AI-answer questions (GEO), clusters, drill-down modifiers and search entities,
  with team hub sync, rank/AI-visibility history and budget-gated tracking.
  Use before any work that names, describes, tags or publishes something that
  should be found by search engines, marketplaces or AI assistants.
mode: subagent
tools:
  read: true
  write: true
  edit: true
  bash: true
  glob: true
  grep: true
  webfetch: false
  task: true
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Search Targets Standard (`context/keywords.md`)

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Files**: `context/keywords.md` (strategy + YAML front matter) and `context/keywords/{targets,queries,clusters,modifiers,entities}.toon` (pipe-delimited TOON tables, stable IDs).
- **CLI**: `aidevops keywords <cmd>` (`scripts/keywords-helper.sh`): `scaffold`, `validate`, `add`, `set`, `brief`, `score`, `expand`, `cluster`, `sync`, `track`, `rollup`, `report`, `budget`, `survey`, `issues`, `routines`, `hub`.
- **Before search-facing work**: run `aidevops keywords brief [--url U|--cluster C|--target ID] [--asset image|video|social|pr|schema|domain|product|repo]` and follow it. Fall back to legacy `context/target-keywords.md` only when the standard is absent.
- **Edits**: add or change rows with `aidevops keywords add|set` (keeps TOON row counts valid); never delete rows, set `status=retired`. Run `aidevops keywords validate` before committing.
- **Ownership**: `DESIGN.md` = visual rules; `context/brand-identity.toon` = voice and positioning; this standard = what people search for, which page answers it, and how the brand is named as a search entity. Link, never copy.
- **Public repos**: registry data is gitignored and shared through the private team hub (`aidevops keywords hub set owner/repo`, then `sync`). Private repos track it in Git (PR-reviewed) and may also sync.
- **Paid spend**: DataForSEO calls are refused beyond `budget_usd_month` (default `$1` per property per month; config `keywords.monthly_budget_usd`, per-repo `repos.json` `keywords.budget_usd_month`).
- **Related**: `seo/keyword-research.md`, `seo/conversational-search-intent.md`, `seo/ranking-opportunities.md`, `seo/ai-visibility-monitor.md`, `seo/ecommerce-seo.md`, `seo/entity-evidence-audit.md`, `tools/context/toon.md`.

<!-- AI-CONTEXT-END -->

## Ownership boundaries

| Source | Owns | Reads from this standard |
|--------|------|--------------------------|
| `DESIGN.md` | Tokens, components, UI rules | Nothing (no keyword rules in DESIGN.md) |
| `context/brand-identity.toon` | Voice, positioning, audience, power words | Canonical entity names only |
| `context/keywords.md` + tables | Search demand, target-to-page mapping, entities as search engines see them, naming/metadata rules, tracking | Voice from brand identity |

When a phrase reads awkwardly, brand voice wins in visible copy; the phrase still goes into metadata, structured data, alt text (only when true) and slugs.

## Front matter

| Key | Meaning |
|-----|---------|
| `schema` | `aidevops.keywords/v1` |
| `name`, `property` | Display name; hub property ID (defaults to `owner__repo`) |
| `surfaces` | Where the property can be found: `website`, `ecommerce`, `github`, `npm`, `pypi`, `homebrew`, `crates`, `app-store`, `play-store`, `chrome-web-store`, `wordpress-org`, `marketplace`, `youtube`, `social`, `local`, `ai-answers` (always) |
| `domains`, `locales`, `markets` | Tracked hostnames; language-region codes; country codes |
| `data` | `tracked`, `ignored` or `auto` (public repos resolve to ignored) |
| `budget_usd_month` | Optional shared team cap; wins over `repos.json` `keywords.budget_usd_month`, which wins over config `keywords.monthly_budget_usd` (default 1) |
| `location_code`, `language_code` | DataForSEO location/language |
| `tracking`, `thresholds` | Cadence notes; `drilldown_min_priority` (60), `facet_min_demand` (50), `facet_min_items` (3) |

Body sections: Positioning, Priorities, **Naming and metadata rules** (injected into every `brief`), Location targeting, Entities and E-E-A-T, Channels, Decisions.

## Tables

| Table | ID | Key fields |
|-------|----|-----------|
| `targets` | `k-0001` | `phrase`, `role` (pillar/cluster/longtail/brand/product/category), `parent_id` (drill-down), `cluster_id`, `surface`, `locale`, `market`, `classic_intent`, `journey_state`, `user_job`, `business_value` (1-5, human), `volume`, `kd`, `cpc`, `keyword_score`, `priority`, `trend_state`, `target_url`, `status`, `channels`, `evidence`, rollups `ranking_url`/`last_position`/`best_position`/`trend`/`last_checked` |
| `queries` | `q-0001` | `question`, `cluster_id`, `target_id`, `engines`, `query_form`, `grounding_likelihood`, `business_value`, `priority`, `target_url`, `status`, rollups `mention_rate`/`citation_rate` |
| `clusters` | `c-0001` | `name`, `parent_id`, `pillar_target_id`, `target_url`, `page_type`, `taxonomy`, `anchors`, `terms` (semantic coverage), `authors` (E-E-A-T), `schema_types`, `hashtags` |
| `modifiers` | `m-0001` | `dimension` (attribute/audience/use_case/problem/compatibility/occasion/location/price/brand/comparison), `value`, `pattern`, `applies_to` (cluster IDs or `*`), `demand`, `page_policy` |
| `entities` | `e-0001` | `name`, `type` (schema.org), `role` (self/competitor/partner/person/product/topic/place), `same_as`, `associations`, `evidence` |

Intent vocabulary reuses `seo/conversational-search-intent.md` (journey state, query form) and the four-class `classic_intent` from keyword research. List-valued cells use `;`.

### Validation rules

- IDs are unique and stable; references (`cluster_id`, `parent_id`, `target_id`, `pillar_target_id`, `applies_to`) must exist.
- **One phrase targets one URL**: duplicate phrases (same locale/market) fail. One URL may carry many same-intent phrases; mixed intents on one URL, or a live target ranking with a different URL, are cannibalisation warnings.
- Enums and ranges (`business_value` 1-5, `kd`/`keyword_score`/`priority` 0-100) are enforced.

## Priority and drill-down

`aidevops keywords score --apply` computes a deterministic 0-100 priority: 45% human `business_value`, 35% opportunity (`keyword_score`, else volume and difficulty), 20% position (striking distance 4-20 scores highest). Models judge intent and value; arithmetic stays in code.

Primary keywords decide where to drill down. `aidevops keywords expand <head-id>` combines a head above `drilldown_min_priority` with its modifiers into long-tail candidates (`running shoes for flat feet`, `waterproof trail running shoes`, `running shoes in London`, `tool-a vs tool-b`) with `parent_id` set, so long-tail pages link up to and build authority for the head. Candidates stay `status=candidate` until evidence promotes them. Ecommerce page policy per node: `seo/ecommerce-seo.md`.

Clustering uses SERP overlap first: `aidevops keywords cluster --serps serps.json --threshold 3 --apply` groups phrases whose top results share at least three URLs. Use a model (or bounded Jev Choice questions, `tools/ai-assistants/jev.md`) only for borderline assignments.

## Uses across work

| Work | Use |
|------|-----|
| Domains | Brand entity over exact-match; ccTLD only for one market (`brief --asset domain`, `seo/domain-research.md`) |
| URLs, file names, anchors | `aidevops keywords slug "<phrase>"`; one primary phrase per URL |
| Tags, categories, topics, hashtags | Cluster `taxonomy` and `hashtags`; GitHub topics and package keywords from cluster phrases |
| Schema | `entities.same_as` for Organization/Person/Product; cluster `terms` for `about`/`mentions`; `markets` for `areaServed` |
| Images | `brief --asset image`: file name, truthful alt text, title/caption, IPTC/XMP keywords, legible in-image text (`seo/image-seo.md`) |
| Video | Titles, descriptions, chapters, transcripts, VideoObject (`seo/video-seo.md`, `seo/transcript-seo.md`) |
| Copy and semantic coverage | Cluster `terms` from NeuronWriter or SERP term analysis (`seo/neuronwriter.md`, `seo/keyword-mapper.md`) |
| Social, PR, third-party publishing | Consistent entity names, brand-topic co-mentions, varied anchors (`brief --asset social` or `--asset pr`) |
| E-E-A-T and entity building | `entities.associations` with evidence URLs; cluster `authors` (`seo/entity-evidence-audit.md`, `seo/eeat-score.md`) |
| Local and multi-market | `markets`, `locales`, location modifiers, hreflang pairs |
| Repos and packages | GitHub description/README first paragraph/topics; npm, PyPI, crates and app-store keyword fields (`brief --asset repo`) |

## Data storage and team sharing

- **Tracked mode** (private repos): strategy and tables are committed and reviewed by PR.
- **Ignored mode** (public repos): `aidevops keywords scaffold` adds `context/keywords.md`, `context/keywords.md.hub` and `context/keywords/` to `.gitignore`; data lives in the hub.
- **Hub**: a private Git repo per team (`aidevops keywords hub set owner/repo`), recorded only in local config `keywords.hub_slug`. Never add it as a submodule or name it in public files. Layout: `<property>/keywords.md`, `<property>/keywords/*.toon`, `<property>/history/YYYY/MM/<run>.toon` (append-only, one file per run, so no merge conflicts), `<property>/spend/YYYY-MM.toon`, optional `<property>/captures/*.json` for AI-answer imports.
- **Sync**: `aidevops keywords sync` merges rows by ID (newer `updated` wins; equal timestamps with different content keep local and are reported) and syncs `keywords.md` three-way against the last synced hash (conflicts write `context/keywords.md.hub`). No hub configured → the local store `~/.aidevops/.agent-workspace/keywords/local/`.
- **Index**: `aidevops keywords index` rebuilds `~/.aidevops/.agent-workspace/keywords/index.db` (SQLite) from every property for cross-brand queries. It is derived and rebuildable, never the source of truth.

## Tracking and budget

| Source | Command | Cost |
|--------|---------|------|
| GSC/Bing/DataForSEO export files (`seo/data-export.md`) | `track --source export --file <toon>` | Free (export step may have its own cost) |
| GitHub repository search | `track --source github` (targets with `surface=github`; blank surface means `website` when listed, else the first non-AI surface) | Free (search API rate limits) |
| npm registry search | `track --source npm` | Free |
| DataForSEO ranked keywords | `track --source dataforseo [--domain D]` | Budget-gated; pre-checked with `keywords.dataforseo_estimate_usd` (conservative default 0.05), ledger stores the provider-reported `cost` |
| AI answers | `track --source ai --file captures.json` | Imports approved captures only (`seo/ai-visibility-monitor.md`) |

`rollup` writes last/best position, trend and ranking URL to targets and mention/citation rates to queries; `report` lists striking distance, movers and spend. Verify current provider pricing before raising budgets.

**Routines** (`aidevops keywords routines` prints lines for `TODO.md` `## Routines`): weekly free tracking, monthly budgeted paid tracking plus AI capture import, and a disabled-by-default quarterly review. Routines write only to the hub/local store, never to repository checkouts; maintainers pull changes into a worktree with `sync`.

## Setup and backfill

- `aidevops init` scaffolds the standard for standard/public scopes (minimal scope only with `.aidevops.json` `keywords.enabled: true`) and adds a Search targets pointer to the project `AGENTS.md`.
- Existing repos: `aidevops keywords survey --json`, then `aidevops keywords issues --apply` files worker-ready backfill issues.
- Legacy `context/target-keywords.md` and `context/competitor-analysis.md` migrate on scaffold (`aidevops keywords migrate --apply`); sources are kept.
