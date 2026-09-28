<!-- aidevops:brief-schema=v2 -->

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->
# t18509: Search targets standard — context/keywords.md registry, hub sync, tracking and ecommerce drill-down

## Pre-flight (auto-populated by briefing workflow)

- [x] Memory recall: `keywords SEO GEO DESIGN.md init standard file rank tracking` → 0 hits
- [x] Discovery pass: `prework-discovery-helper.sh` found no open PRs on the target files; only `context/target-keywords.md` (opt-in seomachine template) overlaps
- [x] File refs verified at HEAD `1da93b63c`
- [x] Tier: `tier:thinking` — new standard, data model, sync semantics and budget gate
- [x] Seeded draft PR decision: skipped — implemented in the originating interactive session

## Origin

- **Created:** 2026-09-28
- **Session:** opencode interactive (Build+)
- **Created by:** ai-interactive
- **Parent task:** none
- **Conversation context:** The maintainer asked for a DESIGN.md-like per-repo standard for target keywords (SEO) and questions/queries (GEO/AI search), with prioritisation, difficulty, clustering, rank tracking across platforms, routines, init scaffolding and backfill across `repos.json`. Decisions agreed in session: keep it under `context/` next to `brand-identity.toon`; name `context/keywords.md` + `context/keywords/*.toon`; DESIGN.md and brand identity keep ownership of visual/voice rules; public repos gitignore the data and share it through a private team hub repo; every repo is a search property (GitHub, package registries, AI answers) even without a site; ecommerce drill-down (collections, attributes, "X for Y"); default paid-provider budget $1/month per property, configurable.

## What

1. A documented standard (`.agents/seo/keywords-standard.md`) for `context/keywords.md` (strategy + YAML front matter) and `context/keywords/{targets,queries,clusters,modifiers,entities}.toon` (tabular TOON registry with stable IDs), including ownership boundaries with `DESIGN.md` and `context/brand-identity.toon`.
2. `keywords-helper.sh` (`aidevops keywords …`) with `detect`, `scaffold`, `validate`, `migrate`, `brief`, `expand`, `cluster`, `hub`, `sync`, `index`, `budget`, `track`, `report`, `survey`, `issues`, `routines`.
3. Private team hub support: local-only hub config, per-property mirror, append-only history shards, spend ledger, local SQLite index rebuilt from the hub.
4. Trackers: import existing GSC/Bing/DataForSEO exports; GitHub repository search and npm search positions (free); budget-gated DataForSEO ranked-keywords; AI answer captures via existing `ai_visibility.py`.
5. `aidevops init` scaffolds the standard for standard/public scopes (or explicit opt-in), gitignores data for public repos, and adds a project AGENTS.md pointer; survey/issues backfill for existing repos.
6. New `seo/ecommerce-seo.md` agent; consumer pointers in SEO/content/brand/PR/domain agents; `context/target-keywords.md` becomes a migrated legacy fallback.

## Why

Keyword research output is ephemeral (`~/Downloads` CSVs), exports are point-in-time snapshots with no history ledger, there is no rank tracking or canonical storage for AI visibility, and most media/schema/social/PR agents re-derive keywords ad hoc. See session findings: `seo.md:130` (no position tracking), `reference/routines.md:27` (example-only routine), `content/context-templates.md:63` (opt-in template read by three agents).

## Tier

**Selected tier:** `tier:thinking` — new data contract, merge semantics and budget enforcement.

## PR Conventions

Leaf issue: the PR uses a closing keyword for this issue.

## How (Approach)

### Files to Modify

- `NEW: .agents/seo/keywords-standard.md` — the standard.
- `NEW: .agents/seo/ecommerce-seo.md` — collections, facets, modifiers, product/merchant surfaces.
- `NEW: .agents/scripts/keywords-helper.sh` — shell entry, detection, scaffold, survey/issues, routines; model on `.agents/scripts/design-guidelines-helper.sh`.
- `NEW: .agents/scripts/keywords-registry-helper.py` plus sibling modules `keywords_toon.py`, `keywords_registry.py`, `keywords_hub.py`, `keywords_track.py`, `keywords_cluster.py` — data operations (model CLI on `.agents/scripts/ai-visibility-helper.py`).
- `NEW: .agents/templates/keywords/keywords.md.template` — strategy template; TOON table headers are generated from the registry schema.
- `NEW: .agents/scripts/tests/test-keywords-helper.sh` — focused regression test modelled on `tests/test-design-guidelines-helper.sh`.
- `EDIT: aidevops.sh` — `keywords)` dispatch next to `design)`.
- `EDIT: .agents/scripts/aidevops-cli/aidevops-init-lib.sh` (`_init_scaffold_scope_gated_files`, `_init_commit_files`) and `aidevops-repos-lib.sh` (`_init_scaffold_keywords` next to `_init_scaffold_design_md`).
- `EDIT: .agents/configs/aidevops.defaults.jsonc`, `aidevops-config.schema.json`, `.agents/scripts/config-helper.sh` env map — `keywords.*` settings.
- `EDIT: .agents/reference/repos-json-fields.md` — `keywords` object.
- `EDIT:` consumer pointers — `seo.md`, `content/context-templates.md`, `content/seo-writer.md`, `seo/seo-write.md`, `content/internal-linker.md`, `content/research.md`, `seo/image-seo.md`, `seo/video-seo.md`, `seo/transcript-seo.md`, `seo/programmatic-seo.md`, `seo/neuronwriter.md`, `seo/eeat-score.md`, `seo/entity-evidence-audit.md`, `seo/domain-research.md`, `seo/keyword-research.md`, `seo/ranking-opportunities.md`, `seo/ai-visibility-monitor.md`, `tools/design/brand-identity.md`, `content/platform-personas.md`, `pr.md`.

### Hazards and Compatibility

- Canonical checkouts stay read-only: backfill only files worker-ready issues; routines write only to the hub clone under the workspace, never to repo canonicals.
- Public-repo privacy: the hub slug lives only in local config (`config.jsonc`/`repos.json`); never a submodule or public file.
- Budget: paid calls are pre-checked against the monthly ledger and refused once the cap would be exceeded.
- Legacy: agents read `context/keywords.md` first and fall back to `context/target-keywords.md`; `migrate` never deletes user files.

### Verification Before Dispatch

```bash
shellcheck .agents/scripts/keywords-helper.sh
python3 -m py_compile .agents/scripts/keywords_*.py .agents/scripts/keywords-registry-helper.py
bash .agents/scripts/tests/test-keywords-helper.sh
bash .agents/scripts/tests/test-config-schema-defaults.sh
.agents/scripts/linters-local.sh --changed
```

### Files Scope

- `.agents/seo/keywords-standard.md`
- `.agents/seo/ecommerce-seo.md`
- `.agents/seo.md`
- `.agents/seo/keyword-research.md`
- `.agents/seo/ranking-opportunities.md`
- `.agents/seo/ai-visibility-monitor.md`
- `.agents/seo/image-seo.md`
- `.agents/seo/video-seo.md`
- `.agents/seo/transcript-seo.md`
- `.agents/seo/programmatic-seo.md`
- `.agents/seo/neuronwriter.md`
- `.agents/seo/eeat-score.md`
- `.agents/seo/entity-evidence-audit.md`
- `.agents/seo/domain-research.md`
- `.agents/seo/seo-write.md`
- `.agents/content/context-templates.md`
- `.agents/content/seo-writer.md`
- `.agents/content/internal-linker.md`
- `.agents/content/research.md`
- `.agents/content/platform-personas.md`
- `.agents/pr.md`
- `.agents/tools/design/brand-identity.md`
- `.agents/scripts/keywords-helper.sh`
- `.agents/scripts/keywords-registry-helper.py`
- `.agents/scripts/keywords_toon.py`
- `.agents/scripts/keywords_registry.py`
- `.agents/scripts/keywords_strategy.py`
- `.agents/scripts/keywords_validate.py`
- `.agents/scripts/keywords_overlap.py`
- `.agents/scripts/keywords_markdown.py`
- `.agents/scripts/keywords_migrate.py`
- `.agents/scripts/keywords_brief.py`
- `.agents/scripts/keywords_hub.py`
- `.agents/scripts/keywords_store.py`
- `.agents/scripts/keywords_track.py`
- `.agents/scripts/keywords_detect.py`
- `.agents/scripts/keywords_routine.py`
- `.agents/scripts/keywords_cluster.py`
- `.agents/scripts/tests/test-keywords-helper.sh`
- `.agents/scripts/tests/test-generated-markdown-default-lint.sh`
- `.agents/AGENTS.md`
- `.agents/scripts/aidevops-cli/aidevops-init-lib.sh`
- `.agents/scripts/aidevops-cli/aidevops-repos-lib.sh`
- `.agents/scripts/config-helper.sh`
- `.agents/configs/aidevops.defaults.jsonc`
- `.agents/configs/aidevops-config.schema.json`
- `.agents/templates/keywords/keywords.md.template`
- `.agents/reference/repos-json-fields.md`
- `.agents/subagent-index.toon`
- `aidevops.sh`
- `TODO.md`
- `todo/tasks/t18509-brief.md`
- `todo/tasks/t18511-brief.md`

## Acceptance Criteria

- [ ] `aidevops keywords scaffold <repo>` creates `context/keywords.md` and five valid TOON tables, with detected surfaces in front matter.
- [ ] `validate` rejects duplicate IDs, unknown references, bad enums and duplicate phrases (one phrase → one URL), and warns on mixed intents per URL.
- [ ] `migrate` converts a legacy `context/target-keywords.md` into registry rows without deleting it.
- [ ] `sync` merges registry rows by ID with the hub and writes append-only history shards; `index` rebuilds a SQLite index.
- [ ] Paid DataForSEO calls are refused when the monthly ledger would exceed the configured budget (default $1).
- [ ] `aidevops init` (standard/public scope) scaffolds the standard, and public repos get the data paths gitignored.
- [ ] Focused test and changed-file lint pass.

## Context & Decisions

- Location `context/` (not repo root): `DESIGN.md` is root because of the external Google spec; keywords is an aidevops format and belongs with `brand-identity.toon`.
- Rank history is never committed to product repos; it lives in the hub as append-only per-run shards (no merge conflicts), indexed locally in SQLite.
- Clustering: SERP overlap first (deterministic); model/Jev only for borderline assignment.
- Cannibalisation rule (corrected during implementation): one phrase must target one URL (duplicate phrases fail validation); one URL may carry many same-intent phrases. Mixed intents on one URL and live targets ranking with a different URL are warnings.
- Budget precedence: explicit front matter `budget_usd_month` (shared team cap) > `repos.json` `keywords.budget_usd_month` > config `keywords.monthly_budget_usd` (default 1).
- `.agents/AGENTS.md` DESIGN.md maintenance line extended to `context/keywords.md` within the 24000-byte ratchet (23993 bytes) by tightening wording; no baseline increase.
- Non-goal: live AI-engine scraping; AI visibility imports approved captures only, matching `seo/ai-visibility-monitor.md`.
