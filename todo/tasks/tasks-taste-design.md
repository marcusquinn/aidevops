<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2026 Marcus Quinn -->

# Taste-informed design concepts and accessible handoff

## Goal and authority

Adapt useful ideas from https://github.com/Leonxlnx/taste-skill without installing
the collection or replacing aidevops design owners. The user accepted the review
and explicitly requested planning, implementation and full-loop release, then
reaffirmed accessibility as a consideration throughout the work and harness.
Interactive primary owns implementation, verification, PR and merge. Tracking:
https://github.com/marcusquinn/aidevops/issues/31783.

## Evidence and boundaries

- Reviewed upstream commit: `ccbc15639c97057cbfcf32ecebc38ef716e4bb37`.
- MIT, copyright 2026 Leonxlnx; retain attribution and licence in a source assessment.
- Existing owners: `.agents/tools/design/brand-identity.md`, `design-md.md`,
  `distinctive-ui.md`, `.agents/product/ui-design.md`, and
  `.agents/workflows/ui-verification.md`.
- Upstream brandkit, image-to-code and multi-screen concepts add useful direction
  and handoff guidance. Reject mandatory generators, motion, arbitrary bans,
  random selection, unlimited retries and screenshot-only acceptance.
- Confirmed palette documentation uses unlinearized RGB and pixel-based large-text
  thresholds. Existing `accessibility-helper.sh` compares rounded ratios; its CLI
  contrast path also exits 2 with no output because an unhandled dispatch group
  triggers `errexit`. Correct these in the existing helper, not a parallel tool.
- No new runtime dependency, test infrastructure, global prompt expansion or
  change to aidevops' own brand. Product-specific preferences remain in the target
  project's `context/brand-identity.toon` and `DESIGN.md` after acceptance.

## Units and ownership

Concurrency cap: one implementation executor. No delegated critical-path work.
Stable units can be verified independently; retain evidence across retries.

| Unit | Owner and effort | Files / question | Depends on |
|------|------------------|------------------|------------|
| T1 | Primary, standard | New `tools/design/brand-concepts.md`, `visual-concepts.md`, `taste-skill.md`; extend brand, DESIGN.md, Distinctive UI, product/mobile and artifact routes, domain index, README and CREDITS | Reviewed source |
| T2 | Primary, standard | `tools/design/colour-palette.md`, `scripts/accessibility-helper.sh`, focused `scripts/tests/test-accessibility-contrast.py`: correct threshold decisions and runnable CLI | Reproduced defects |
| T3 | Primary, standard | Changed-file checks, CLI regressions, assembled-context review/comprehension scenarios | T1, T2 |
| T4 | Primary, standard | Guarded PR/merge and canonical release helper, exact-tag delivery verification | T3 |

Paths in the table are relative to `.agents/` except README and CREDITS.

## Acceptance and verification

- [x] Brand directions explain a core idea, mark exploration and applications;
  concept boards are not production assets or trademark clearance.
- [x] Visual concept generation is optional, cost/rights bounded and approval-led;
  absent provider/authority has a useful non-generated fallback.
- [x] Accepted direction feeds canonical tokens without promoting speculative
  image details; implementation preserves real copy, behaviour and accessibility.
- [x] Mobile journeys share a system and model navigation/state/error recovery.
- [x] Audit/study stays read-only even without brand files; concept-only work
  never writes unaccepted preferences into canonical brand/design files.
- [x] Redesign preserves SEO, analytics and consent; motion remains scoped and
  reduced-motion support is required, not traded for visual fidelity.
- [x] WCAG contrast documentation uses linearized sRGB, correct large-text units
  and contextual thresholds. CLI compares unrounded values and reports failures.
- [x] Run `python3 .agents/scripts/tests/test-accessibility-contrast.py`, relevant
  ShellCheck/Bash compatibility checks and `.agents/scripts/linters-local.sh --changed`.
- [x] Review assembled routing with scenarios for missing brand files, unavailable
  image generation, concept-vs-production kit, accepted reference fidelity,
  multi-screen continuity, reduced motion and near-threshold contrast failure.
- [ ] Create/merge verified PR, publish through `full-loop-release-helper.sh`,
  verify deployed source hashes and terminal release receipt.

No generated UI is delivered by this change; documentation comprehension and CLI
results are evidence, not rendered-design quality or conversion benchmarks.

## Verification evidence

- Public CLI before correction: `contrast '#6e7978' '#ffffff'` exited 2 with no
  output. After correction it reports normal-text AA FAIL (rounded display 4.50),
  large-text AA PASS and exit 1. Black/white reports 21.00 and all four PASS.
- Standard-library regression suite exercises seven colour pairs, invalid/missing
  inputs, help and unknown command dispatch. Three test methods pass; no network
  services or new test infrastructure. Native Bash 3.2 contrast also exercised.
- ShellCheck and Bash syntax pass; Markdoc validates all 15 changed Markdown files.
- Changed-file local gates pass for all 17 files, including secret scanning,
  Markdown, shell portability and complexity/compatibility regression checks.
  Both new guides resolve through canonical subagent discovery.
- Direct assembled-context review (not an independent model benchmark):

| Scenario | Observed instruction path and conclusion |
|----------|------------------------------------------|
| Audit with no brand files | Artifact → Distinctive UI plus brand/design/inspiration guards: report only, no canonical creation |
| Concept with no generator | Artifact → visual concepts: textual/reference/wireframe fallback, no implied installation or spend |
| Approved raster brand board | Brand concepts: selection is not a vector master, licensed kit or trademark clearance |
| Accepted reference conflicts with catalogue | Visual concepts → Distinctive UI → DESIGN.md: retain accepted direction and factual copy; explain necessary adaptations |
| Mobile screen sequence | Product/mobile → visual concepts: shared tokens/navigation and action/destination/persisted state/back/recovery |
| Motion conflicts with accessibility | Visual concepts → UI verification: reduced motion and real feedback remain required; no forced library |
| Rounded contrast close to threshold | Palette → actual CLI: full-precision decisions, contextual thresholds and explicit opaque-sRGB limitation |

Publication and exact-tag deployment evidence will be recorded on the source PR
and issue after their gates complete; the final acceptance item remains open until
those results exist.
