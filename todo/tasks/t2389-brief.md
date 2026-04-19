# t2389: tier:simple body-shape validator (auto-downgrade mis-tiered briefs pre-dispatch)

**Session origin:** interactive
**Severity:** high — every mis-tiered dispatch burns the full haiku→sonnet→opus cascade
**Tier:** standard

## What

Add a pre-dispatch validator that inspects the body shape of any `tier:simple`-labelled issue and auto-downgrades to `tier:standard` when the body contains hard disqualifiers documented in `reference/task-taxonomy.md` "Tier Assignment Validation". The validator:

1. Runs **after** `_ensure_issue_body_has_brief` and **before** `_run_predispatch_validator` in `pulse-dispatch-core.sh::dispatch_with_dedup`
2. Only activates for issues carrying `tier:simple`
3. Parses the body for 4 high-precision disqualifiers (see "How")
4. On disqualifier hit: swaps `tier:simple` → `tier:standard`, posts a feedback comment citing the specific disqualifier, returns 0 (dispatch proceeds at `tier:standard`)
5. On no hit: returns 0 (dispatch proceeds at `tier:simple`)
6. Non-blocking: never returns non-zero, never closes the issue

## Why

Issues are routinely mis-tagged `tier:simple` at creation time despite failing multiple disqualifiers. Once dispatched, haiku fails (judgment work it can't do), the pulse escalates to sonnet (12x cost), sonnet fails or succeeds after extensive exploration, and the cascade report gets filed. This wastes 1-2 dispatch cycles per mis-tier.

The taxonomy doc already has a "Quick-Check at Creation Time" list but it's only enforced by human discipline at `/new-task` time. Server-side enforcement at dispatch is defence-in-depth — it catches issues that were tagged before the rules existed, issues whose tier label was overridden later, and issues where the task-creator skipped the checklist.

Evidence: the broader 17-issue audit that produced this task identified at least 3 issues mis-tagged `tier:simple` when they required architectural reasoning. The issue-level damage is low per occurrence but recurrent.

## How

### Files to modify

- **NEW:** `.agents/scripts/tier-simple-body-shape-helper.sh` — the validator helper. Model on `.agents/scripts/pre-dispatch-validator-helper.sh` for structure, but simpler (no generator marker parsing, no scratch clone — pure body-string inspection).
- **EDIT:** `.agents/scripts/pulse-dispatch-core.sh` (around line 952-959, between `_ensure_issue_body_has_brief` and `_run_predispatch_validator`) — add one call to the new helper.
- **NEW:** `.agents/scripts/tests/test-tier-simple-body-shape.sh` — fixture-based tests.
- **EDIT:** `.agents/reference/task-taxonomy.md` — add a "Server-side enforcement" subsection under "Tier Assignment Validation" citing the new helper.
- **EDIT:** `.agents/AGENTS.md` — add a one-liner in the "Briefs, Tiers, and Dispatchability" section pointing at the validator.

### Disqualifier checks (MVP set — 4 of 9 from taxonomy)

High-precision only. The other 5 (skeleton code, conditional logic, error handling, cross-package, large-file + no verbatim) require fuzzier heuristics and are deferred.

1. **File count >2** — parse `## Files to modify` / `## Files to Modify` / `## How` sections; count lines matching `^[\s-]*(NEW:|EDIT:)` or bullet points containing explicit file paths (`\.(sh|py|md|ts|tsx|js|jsx|yml|yaml|json|toml|go|rs)`). Exit 10 if count > 2.
2. **Estimate >1h** — parse `~Nh`, `~Nm`, or `~Nd` tokens. Convert to minutes. Exit 10 if > 60 minutes.
3. **Acceptance criteria >4** — count `- [ ]` checkboxes inside a `## Acceptance` or `## Acceptance Criteria` section. Exit 10 if count > 4.
4. **Judgment keywords present** — case-insensitive grep for the token set: `graceful degradation`, `fallback`, `retry`, `conditional`, `coordinate`, `design`, `architecture`, `trade-off`, `strategy`. Exit 10 if any hit.

Each disqualifier is a separate `_check_*` function returning 0=pass, 10=fail with a populated `$DISQUALIFIER_REASON` global.

### Integration hook

In `pulse-dispatch-core.sh::dispatch_with_dedup` just after `_ensure_issue_body_has_brief`:

```bash
_run_tier_simple_body_shape_check "$issue_number" "$repo_slug"
# Non-blocking — always returns 0 so dispatch proceeds. If a disqualifier
# was detected the helper already mutated the labels and posted feedback.
```

The helper is a separate script (not sourced) to keep dispatch-core.sh blast radius small.

### Feedback comment format

Idempotent via `<!-- tier-simple-auto-downgrade -->` marker. Body:

```markdown
<!-- tier-simple-auto-downgrade -->
## Tier Auto-Downgrade: simple → standard

Pre-dispatch body-shape check detected a `tier:simple` disqualifier. Swapping `tier:simple` → `tier:standard` before worker dispatch.

**Disqualifier:** <specific reason>

**Evidence:** <quoted body fragment>

The worker is still dispatching — just at the appropriate tier. See `.agents/reference/task-taxonomy.md` "Tier Assignment Validation" for the full disqualifier list.

_Automated by `tier-simple-body-shape-helper.sh` (t2389)._
```

## Acceptance criteria

- [ ] `tier-simple-body-shape-helper.sh` exists and is shellcheck-clean
- [ ] 4 `_check_*` functions implemented with clear return conventions
- [ ] `_apply_downgrade` helper that swaps labels + posts comment (idempotent via marker)
- [ ] `pulse-dispatch-core.sh` wires in the new check between freshness guard and pre-dispatch validator
- [ ] `test-tier-simple-body-shape.sh` covers each disqualifier with a pass + fail fixture
- [ ] Clean dispatch (no `tier:simple` label) is a no-op
- [ ] Idempotency test: running twice on same issue does not post duplicate comment

## Context

Related to the broader pipeline-autonomy investigation. Companion fixes:
- t2386 (#19909, merged) — NMR circuit-breaker loop
- t2387 (#19918, merged) — no_work crash tier-escalation skip
- t2388 (#19928, open) — parent-task decomposition nudge

This is Fix #6 of that investigation. Fix #4 (duplicate close) and Fix #5 (age-based closure) are done/deferred respectively.

## Tier checklist (this brief)

- [x] Files to modify: 5 (helper, dispatch-core, test, taxonomy doc, AGENTS.md) — above tier:simple threshold of 2
- [x] Estimate: ~2h — above tier:simple threshold of 1h
- [x] Acceptance criteria: 7 — above tier:simple threshold of 4
- [x] Judgment keywords in How section: "coordinate" (for label/comment mutations), "design" (of the disqualifier detection heuristics)

All four hard disqualifiers hit → `tier:standard` is correct. This brief is, somewhat fittingly, exactly the kind of brief the validator it proposes would reject as tier:simple.
