# t18573: docs: trim textbook skills, fold minor branch-type docs, merge best-practices, retire mission-skill-learner

## Origin

- **Created:** 2026-09-30
- **Created by:** ai-interactive
- **Issue:** GH#33149
- **Conversation context:** Framework value audit (parent GH#33139); maintainer approved retiring redundant tooling while keeping the useful ideas.

## Why

These docs restate knowledge current models already have. No agent is routed to them, and they cost maintenance and index space. The house decisions and pitfalls in them still help smaller models, so those are kept.

## What

Remove agent docs that restate knowledge models already have, and keep the house decisions and pitfalls smaller models need. Parent: GH#33139.

No file outside the generated `subagent-index.toon` links to these docs, so no agent, small or large, is currently routed to them.

## Decisions (maintainer delegated these calls)

1. **Delete:**
   - `tools/programming/modern-javascript-skill` (29 files; ES2016–ES2025 and promise basics)
   - `tools/architecture/clean-ddd-hexagonal-skill` and `feature-slicing-skill` (22 files; textbook architecture)

   If `tools/app-stack/` lacks a genuine house architecture decision found in these files, move that decision there first.
2. **Condense Mermaid:** replace the `tools/diagrams/mermaid-diagrams-skill` folder (8 files) with a single `mermaid-diagrams-skill.md` of about 60 lines covering syntax pitfalls smaller models actually hit: edge-label quoting, reserved words such as `end`, special characters in node text, subgraph IDs, and renderer differences between GitHub and mermaid-cli.
3. **Postgres/Drizzle:** delete the generic Postgres `performance*.md` files (8). Keep the Drizzle cheatsheets and the entry doc, because Drizzle's API has changed since many models were trained. Keep the entry doc's house pairing with PGlite and RLS.
4. **Branch docs:** fold `workflows/branch/{chore,refactor,release,experiment}.md` into `workflows/branch.md` as a compact table.
   - Keep `feature.md`, `bugfix.md` and `hotfix.md`; the generated slash commands load them.
   - Keep the house rule in `bugfix.md` about not adding new test infrastructure.
5. **Code standards:** merge the non-duplicated content of `tools/code-review/best-practices.md` into `code-standards.md` (Sonar rule IDs, hotspot handling), then delete it. Drop anything that repeats `.agents/AGENTS.md` shell rules.
6. **Mission skill learning:** delete `mission-skill-learner.sh` (no executable caller; memory graduation covers it) and `workflows/mission-skill-learning.md`. Update `mission-orchestrator.md:90` and `mission-template.md`.
7. Update every inbound reference, add the deleted deployed paths to the migrations cleanup list, and regenerate `subagent-index.toon`.

## How: reference pattern

Model deployed-file removal on the osgrep doc cleanup list in `.agents/scripts/setup/modules/migrations.sh:160-170`.

### Files Scope

- `.agents/tools/programming`
- `.agents/tools/architecture`
- `.agents/tools/diagrams/mermaid-diagrams-skill`
- `.agents/tools/diagrams/mermaid-diagrams-skill.md`
- `.agents/services/database/postgres-drizzle-skill/performance.md`
- `.agents/services/database/postgres-drizzle-skill/performance-caching.md`
- `.agents/services/database/postgres-drizzle-skill/performance-explain.md`
- `.agents/services/database/postgres-drizzle-skill/performance-indexing.md`
- `.agents/services/database/postgres-drizzle-skill/performance-monitoring.md`
- `.agents/services/database/postgres-drizzle-skill/performance-pagination.md`
- `.agents/services/database/postgres-drizzle-skill/performance-pooling.md`
- `.agents/services/database/postgres-drizzle-skill/performance-queries.md`
- `.agents/services/database/postgres-drizzle-skill.md`
- `.agents/workflows/branch.md`
- `.agents/workflows/branch/chore.md`
- `.agents/workflows/branch/refactor.md`
- `.agents/workflows/branch/release.md`
- `.agents/workflows/branch/experiment.md`
- `.agents/workflows/branch/bugfix.md`
- `.agents/tools/code-review/best-practices.md`
- `.agents/tools/code-review/code-standards.md`
- `.agents/tools/code-review/code-simplifier.md`
- `.agents/tools/git/conflict-resolution.md`
- `.agents/tools/runtime/node-server-admin.md`
- `.agents/workflows/conversation-starter.md`
- `.agents/marketing-sales/cro-chapter-15.md`
- `.agents/scripts/mission-skill-learner.sh`
- `.agents/workflows/mission-skill-learning.md`
- `.agents/workflows/mission-orchestrator.md`
- `.agents/templates/mission-template.md`
- `.agents/scripts/generate-runtime-config-agents.sh`
- `.agents/scripts/tests/test-basename-collision-resolver.sh`
- `.agents/scripts/tests/test-scoped-ripgrep-searches.sh`
- `.agents/scripts/setup/modules/migrations.sh`
- `.agents/configs/simplification-state.json`
- `.agents/subagent-index.toon`

## Acceptance criteria

- [ ] The deleted trees are gone, and `rg -n 'modern-javascript-skill|clean-ddd-hexagonal|feature-slicing-skill|mission-skill-learn|best-practices\.md' .agents` returns only migration entries.
- [ ] The Mermaid doc is a single file of about 60 lines or fewer, focused on pitfalls.
- [ ] `branch.md` covers chore, refactor, release and experiment, and the three kept branch docs still load from the generated commands.
- [ ] `code-standards.md` keeps its Sonar and hotspot content and absorbs any unique best-practices content.
- [ ] Markdown lint passes; `subagent-index.toon` is regenerated.

## Verification

```bash
rg -n 'modern-javascript-skill|clean-ddd-hexagonal|feature-slicing-skill|mission-skill-learn|best-practices\.md' .agents
.agents/scripts/linters-local.sh
```

Parent: #33139
