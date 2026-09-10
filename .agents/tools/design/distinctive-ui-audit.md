<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2026 Marcus Quinn -->
<!-- SPDX-FileCopyrightText: 2026 Hallmark contributors -->

# Distinctive UI Audit

Load for an explicit design audit or after a `distinctive-ui.md` build/redesign.
Audit is read-only unless implementation is separately authorized. Hallmark
informs this critique; `hallmark.md` records provenance and the MIT notice.

## Two different questions

1. **Does it work?** Observe the real task, accessibility, responsive behaviour,
   data, assets and diagnostics using `workflows/ui-verification.md`. Apply that
   workflow's S1/S2/S3 severity to observed defects.
2. **Does it suit this brief?** Critique the design with evidence and rationale.
   Subjective taste is advisory, not a failed technical test. A familiar pattern
   or font is not proof that a page is AI-generated.

Scope the audit to the named surface. If only source or a screenshot is available,
report that limitation; do not infer keyboard behaviour, contrast compliance,
performance or cross-device coverage from it. Never claim a gate count, score,
conversion lift or "looks good" without the corresponding evidence.

## Brief-fit critique

| Lens | Ask | Evidence / useful correction |
|------|-----|------------------------------|
| Intent | Is the audience's job and next action clear? | Point to visible copy and action; replace vague positioning with a concrete benefit |
| Hierarchy | Do emphasis and order reflect importance? | Name competing elements; group, reorder or reduce emphasis |
| Specificity | Could this be any unrelated product with a name swap? | Use real product evidence and domain language; change arrangement if needed |
| Restraint | Does each element earn its attention and cost? | Remove purposeless badges, nested containers, repeated labels or motion |
| Craft | Do type, spacing, assets and states form a coherent system? | Compare actual elements with DESIGN.md and nearby canonical examples |
| Appropriate variety | Are independent alternatives truly different while one product stays consistent? | Compare structure, not palette alone; retain shared navigation and controls |

Treat these as judgment prompts, not six numerical scores. Recommend the smallest
revision that addresses the observed weakness. Replacing purple with beige or
cards with oversized serif headings does not by itself solve generic design.

## Named checks

Only apply relevant checks. Each result is **pass**, **fail**, **not applicable**
or **not checked**, with evidence. Do not count not-checked items as passed.

| Check | Failure mechanism to look for | Correction / verification |
|-------|-------------------------------|---------------------------|
| Template mismatch | Structure reflects a stock marketing page rather than the user's task | Compare against `distinctive-ui-composition.md`; explain a better arrangement |
| Hierarchy flattening | Equal cards/weights hide differences in importance; nested cards add no meaning | Remove a containment layer or use lists/tables; inspect reading order |
| Empty chrome | Invented nav/footer categories or dead CTAs imply nonexistent content | Use real destinations; exercise each affected control |
| Decorative proof | Unsourced metrics, quotes, customers, prices or trust badges | Source, conspicuously label in prototypes, or remove; no plausible invented endorsements |
| Token drift | One-off colours/type/states conflict with the accepted system | Reuse or explicitly extend canonical semantic roles; inspect both supported themes |
| Typography failure | Clipped headings, illegible text, missing glyphs or fallback layout shifts | Test real fonts, long text, text scaling and relevant languages |
| Asset mismatch | Stock/generated media pretends to show real people, products or outcomes | Use real evidence or disclose illustration; confirm rights and provenance |
| Interaction theatre | Working-looking search, toggles, forms or demo controls do nothing | Implement the actual path or clearly state the agreed prototype boundary |
| State omissions | Loading/error/empty/disabled states lose input or leave users stranded | Exercise applicable transitions; confirm feedback, retry and state semantics |
| Focus/hover exclusion | Touch or keyboard users cannot discover/use controls; ring appears late or is obscured | Use accessible primitives; test focus, activation, escape/return and tap paths |
| Feedback noise | Duplicate toasts, needless confirmations or motion obscure the outcome | Keep useful visible/announced status; remove redundancy, not essential feedback |
| Unsafe optimism | Undo is promised without reversible persistence, or errors leave optimistic state uncorrected | Retain confirmation where required; verify persistence, rollback and recovery |
| Motion without purpose | Every section reveals or every unrelated element scales; content depends on animation | Follow authorized motion policy; test reduced motion and content visibility |
| Overflow masking | Global clipping hides a layout defect, content or a focus ring | Diagnose intrinsic sizing, wrapping and sticky offsets; recheck narrow screens |
| Media cost | Nonessential media competes with the LCP resource, lacks dimensions or starts unwanted playback | Use the framework's media path, appropriate loading priority and controls; inspect network/runtime evidence |
| Study drift | Accepted reference traits quietly replaced by a catalogue theme | Compare output with accepted study decisions; document justified adaptations |

Spacing rhythm, gradients, italic headings, system fonts, white/black surfaces,
side-stripe alerts and symmetrical grids can be intentional. Flag them only for
a specific conflict with the brief, system or usability—not because a catalogue
labels them unfashionable. WCAG contrast must be computed against the effective
background; OKLCH lightness and APCA are not substitutes for WCAG ratio evidence.

## Report and repair

For each finding, provide:

```text
ID / technical S1-S3 or advisory / check / observed scope
Evidence: file:line plus screenshot, viewport/state or command result when available
Impact: what fails for the user, or why it conflicts with the agreed direction
Correction: smallest useful change, including any scope/rights dependency
Verify: the normal user path or comparison that would prove the correction
```

End with coverage (including not checked), technical blockers, advisory
recommendations and next action. Audit-only stops here. Authorized implementation
fixes in-scope defects, rechecks the affected evidence and reports remaining
limitations. Reuse unchanged evidence; do not run an open-ended perfection loop.
Broader redesign or unrelated findings follow the existing task lifecycle rather
than silently expanding a small UI change.
