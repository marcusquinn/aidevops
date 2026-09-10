# Hallmark-informed distinctive UI design

## Goal and authority

User requested deep comparison, planning, implementation, full-loop merge and
release on 2026-09-10. Integrate useful design judgment rather than install or
vendor an upstream skill. Preserve existing design systems, accessibility,
functional verification, runtime neutrality, and repository knowledge ownership.

Tracking: https://github.com/marcusquinn/aidevops/issues/31735 (interactive claim).

## Evidence and execution units

Upstream: https://github.com/nutlope/hallmark at
`13ac0ec7e148655948100b6396439e481361d690` (MIT; reviewed 2026-09-10).

Concurrency cap: two advisory children; implementation remains primary-owned.

| Unit | Owner / tier | Scope | Dependencies | Reuse key | State |
|------|--------------|-------|--------------|-----------|-------|
| H1 | Primary | Upstream goals, references, conflicts, provenance | None | Hallmark commit above | Complete |
| H2 | Primary after bounded research capability refusal | Existing local design capability inventory; no writes | None | aidevops base c1a1271fd | Complete |
| H3 | Primary | Synthesis, focused design guidance and routing | H1, H2 | H1/H2 evidence | Complete |
| H4 | Primary | Narrow checks, behavior scenarios, PR and merge | H3 | Exact changed tree | Local checks complete; PR/merge next |
| H5 | Primary / bounded release route | Authorized release, postflight, deployed evidence | H4 | Verified merge SHA | Pending |

H2 owns only the inventory question across `.agents/tools/design/`,
`.agents/tools/ui/`, `.agents/product/`, relevant design commands and setup
discovery. H1 owns upstream study; no duplicate investigation. Returned evidence
will be retained here. No child may delegate or modify files.

## Acceptance

- Explain upstream aims, unique value, existing equivalents, gaps, rejected rules,
  and maintenance/licensing costs with source evidence.
- Deliver a discoverable optional build/audit/redesign/study design layer with
  concise entry points and on-demand detail; no always-loaded prompt expansion.
- Preserve brand consistency within a product; use variety for distinct briefs or
  authorized alternatives, not compulsory redesign of every page.
- Distinguish subjective design critique from measured accessibility, functional,
  responsive and performance checks; never fabricate pass counts.
- Reuse canonical DESIGN.md, palette, reference study, UI and browser workflows;
  no new hidden state, mandatory dependencies, or test infrastructure.
- Verify affected lint, links/agent discovery and bounded comprehension scenarios;
  review, merge, release and verify publication/deployment evidence.

## Findings and delivery

Full aim/overlap/treatment matrix, source inventory, rejected rules and MIT notice:
`.agents/tools/design/hallmark.md`. Research-only H2 could not read the linked
worktree under its permission envelope; it returned no evidence. The primary
completed the inventory locally without changing child permissions or repeating
completed child work.

Local evidence: `design-md.md` owns the token schema, palette and evolution;
`ui-ux-inspiration.md` owns interviews and rendered extraction;
`design-md-from-links.md` owns provenance and production export;
`product/ui-design.md` and `tools/ui/ui-skills.md` own platform/implementation;
`workflows/ui-verification.md` owns rendered/functional evidence.
`open-design-ingestion.md` is an ingestion plan, not proof every candidate skill
is already implemented. The style catalogue is vocabulary, not a universal
composition decision process.

Implementation: focused Distinctive UI entry point, composition and audit
references; routing through DESIGN.md, UI inspiration, product UI, domain index
and the existing design-artifact command; README/credits. No new command,
dependency, plugin, style catalogue or always-loaded prompt expansion. No root
DESIGN.md change: this adds cross-project design guidance, not a new aidevops
brand preference or rendered visual change.

In-scope correction: UI inspiration's extraction recipe requested full-page
screenshots despite the canonical viewport-size limit; it now uses the existing
bounded screenshot path and avoids unbounded network-idle assumptions.

Verification scenarios: audit missing DESIGN.md remains read-only; existing
multi-page app preserves its system; different briefs select distinct suitable
structures; screenshot study does not invent exact fonts/rights; long localized
navigation does not get globally clipped; unavailable browser checks remain
not checked.

## Verification evidence

- `npx --no-install markdownlint-cli2` on all 13 changed Markdown files: zero issues.
- `.agents/scripts/linters-local.sh --changed`: exit 0; 13-file secret scan clean,
  Markdown/whitespace clean, no applicable mapped code tests. Historical size and
  policy advisories are pre-existing and reported as non-regressions by the gate.
- Canonical `subagent_validation.collect_subagent_files(".agents")`: resolves
  `distinctive-ui` and `tools/design/distinctive-ui`. Generator inspection confirms
  normal subfolder Markdown discovery and canonical-source stub delivery.
- Referenced existing production/design/browser paths verified with tracked-file
  discovery; new sibling links inspected; Markdoc validation of new guides and
  design-artifact command exits 0.
- Bounded standard-tier inference over the actual changed guides and routing
  excerpts returned the intended next action and prohibited overreach for all six
  scenarios above. Parent checked the answers against the owning sections. The
  generic DESIGN.md create-if-absent rule is scoped out by the new audit/study
  exception before those workflow steps. This is comprehension evidence only,
  not a rendered UI, runtime-agent integration or conversion benchmark.
- Risk is low (instruction/docs change). Direct assembled-context/diff review,
  existing checks and exact-head remote gates apply. No new test infrastructure.

Release delivery remains pending until the canonical full-loop release helper
verifies publication channels, postflight and exact-tag deployment. The linked PR
and release receipt own those subsequent immutable Git identities; this plan
records pre-merge implementation and verification rather than predicting them.
