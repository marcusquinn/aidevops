# t1550: Add Composer 2 to model routing tiers and bundle presets

## Session Origin

Interactive session, issue #5363. Blocker t1549 (Cursor as OAuth pool provider) resolved.

## What

Add Cursor Composer 2 as a new `composer` tier in the model routing system, positioned between `haiku` and `sonnet` in the cost spectrum.

## Why

Composer 2 offers frontier-level coding at $0.50/$2.50 per M tokens (~83% cheaper than sonnet at $3/$15). For Cursor users doing routine code implementation, this provides significant cost savings without sacrificing code quality.

## How

1. Update `model-routing.md` with new `composer` tier in all tables (Model Tiers, Cost Estimation, Subagents, Fallback Routing), routing rules, decision flowchart, and examples
2. Create `models/composer.md` subagent following existing pattern (sonnet.md)
3. Update `bundles/schema.json` to include `composer` in the `model_tier` enum
4. Update `models/README.md` tier mapping table
5. Update `AGENTS.md` cost spectrum reference
6. Update all helper scripts that enumerate tiers: `model-availability-helper.sh`, `model-label-helper.sh`, `compare-models-helper.sh`, `fallback-chain-helper.sh`, `onboarding-helper.sh`
7. Update archived scripts: `evaluate.sh`, `issue-sync.sh`, `ai-actions.sh`, `pattern-tracker-helper.sh`
8. Update `fallback-chain-config.json.txt` with composer chain entry
9. Add runtime-specific tier documentation (Cursor-only constraint, automatic fallback to sonnet)

## Acceptance Criteria

- [ ] `composer` tier appears in all model routing tables and documentation
- [ ] `models/composer.md` exists with correct frontmatter and pricing
- [ ] Bundle schema validates `composer` as a valid tier
- [ ] All helper scripts accept `composer` as a valid tier name
- [ ] Runtime constraint (Cursor-only) is clearly documented with fallback behaviour
- [ ] Linters pass on all modified files

## Context

- Composer 2 is Cursor-specific -- not available via Anthropic/Google/OpenAI APIs
- Fallback from composer is always sonnet (next general-purpose tier)
- Bundle defaults are NOT changed -- composer is opt-in via explicit model_defaults override
- Pricing: $0.50 input / $2.50 output per 1M tokens
