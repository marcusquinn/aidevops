# t18569: refactor: remove dead pattern-tracker callers and route rule-violation counts to observability

## Origin

- **Created:** 2026-09-30
- **Created by:** ai-interactive
- **Issue:** GH#33144
- **Conversation context:** Framework value audit (parent GH#33139); maintainer approved retiring redundant tooling while keeping the useful ideas.

## Why

Pattern-tracker callers write to a store nothing reads, which costs time on every call. Rule-violation counts are still useful, and they belong in the observability path, where they get used.

## What

t1335 (PR #2305) archived `pattern-tracker-helper.sh` and `self-improve-helper.sh`, but their callers are still in the code and do nothing. Remove them, and keep the one idea still worth having. Parent: GH#33139.

Inert callers, verified 2026-09-30:

- `.agents/plugins/opencode-aidevops/quality-hooks.mjs:137-160`, `recordGitPattern()`: records git success or failure, behind `existsSync`.
- `.agents/plugins/opencode-aidevops/ttsr.mjs:367-375`, `recordViolationsToTracker()`: records rule violations, behind `existsSync`.
- `.agents/scripts/headless-runtime-model.sh:337-370`, `_choose_model_tier_downgrade()`: marked as a dormant hook that calls `scripts/archived/pattern-tracker-helper.sh`, which does not ship.
- `shared-constants.sh` and `agent-test-helper.sh:704` references, test mocks in `tests/test-ai-supervisor-e2e.sh:767` and `:1454`, `tests/test-tier-downgrade.sh`, `tests/test-pattern-scoring.sh`, and `.agents/plugins/opencode-aidevops/tests/test-tui-console-routing.mjs`.

The compare-models, contest and response-scoring references are out of scope; a sibling child handles them.

## Ideas to keep

1. **Rule-violation telemetry.** TTSR violation counts show which prompt rules models break most often. That is the evidence `.agents/configs/prompt-hook-candidates.conf` needs to decide which rules to turn into hooks. Send violations to the existing observability path (see `.agents/reference/observability.md` and `observability-helper.sh`) as a counted event per rule ID. Add a short report command, or extend an existing report, that lists the most-violated rules alongside `prompt-hook-candidates.conf`.
2. **Evidence-based tier step-down.** The pattern tracker's goal (use a cheaper tier when evidence shows it succeeds for this task type) now belongs with model-ab and dispatch telemetry (`model-ab-*.mjs`, `dispatch-tier-telemetry.jq`). Delete the dormant hook and its test. Record the idea in `.agents/reference/observability.md` or `model-routing.md` as a pointer to the model-ab data. Do not re-implement it here.

Drop the git success/failure recording in `quality-hooks.mjs`; it has no consumer.

## How: reference pattern

Model the violation event on how `ttsr.mjs` already logs through the plugin quality log, or on an existing OTEL span enrichment in the plugin (`rg -n 'span' .agents/plugins/opencode-aidevops/*.mjs`).

### Files Scope

- `.agents/plugins/opencode-aidevops/quality-hooks.mjs`
- `.agents/plugins/opencode-aidevops/ttsr.mjs`
- `.agents/plugins/opencode-aidevops/tests/test-tui-console-routing.mjs`
- `.agents/scripts/headless-runtime-model.sh`
- `.agents/scripts/shared-constants.sh`
- `.agents/scripts/agent-test-helper.sh`
- `.agents/scripts/observability-helper.sh`
- `.agents/configs/prompt-hook-candidates.conf`
- `.agents/reference/observability.md`
- `.agents/reference/memory.md`
- `.agents/tools/context/model-routing.md`
- `.agents/aidevops/self-improving-agents.md`
- `tests/test-tier-downgrade.sh`
- `tests/test-pattern-scoring.sh`
- `tests/test-ai-supervisor-e2e.sh`

## Acceptance criteria

- [ ] `rg -n 'pattern-tracker-helper|self-improve-helper' .agents tests` returns only migration entries and the compare-models, contest and response-scoring files left to the sibling child.
- [ ] A TTSR violation produces a counted per-rule observability event, and the report lists the top violated rules.
- [ ] Routing tests still pass with the dormant step-down removed.
- [ ] ShellCheck and the plugin tests are clean.

## Verification

```bash
rg -n 'pattern-tracker-helper|self-improve-helper' .agents tests
node --test .agents/plugins/opencode-aidevops/tests/
shellcheck .agents/scripts/headless-runtime-model.sh .agents/scripts/agent-test-helper.sh
.agents/scripts/linters-local.sh
```

Parent: #33139
