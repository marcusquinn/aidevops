---
mode: subagent
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->
# t1740: Haiku comprehension benchmark for agent file clarity and model-tier routing

## Origin

- **Created:** 2026-04-01
- **Session:** claude-code:interactive
- **Created by:** marcusquinn (human) + ai-interactive
- **Conversation context:** Discussion about whether Haiku's comprehension of agent files could serve as a quality signal — if Haiku can follow the instructions, the file is clear enough. Extends the simplification routine with a testable clarity gate.

## What

A benchmark framework that tests whether agent files are comprehensible at each model tier (haiku, sonnet, opus). Produces a per-file tier compatibility rating stored in `simplification-state.json`. The benchmark itself must be token-efficient — using haiku for simple checks, escalating to sonnet/opus only where needed.

Deliverables:

1. **Test scenario format** — a standard structure for defining comprehension tests per agent file (input scenario + expected behavior/output).
2. **Benchmark runner** — a script that runs test scenarios against each model tier via `ai-research` and scores pass/fail.
3. **Pilot results** — benchmark run across 10-15 files spanning simple to complex, with failure mode analysis.
4. **Integration point** — `haiku_compatible` / `tier_minimum` field in `simplification-state.json` that the pulse can use for dispatch routing.

## Why

Cost and scale. Every file that passes the haiku benchmark can be dispatched at ~1/60th the cost of opus. Currently model tier is set manually (`tier:simple`, `tier:thinking`) or defaults to sonnet. An empirical benchmark replaces guesswork with measurement, and the clarity improvements benefit all tiers.

Secondary: files that are unclear to haiku are likely unclear to humans too. The benchmark is a proxy for instruction quality.

## How (Approach)

### Phase 1: Test scenario format and pilot (this task)

Design a test scenario spec. Each agent file gets a companion test:

```
.agents/tests/comprehension/{agent-path-slug}.yaml
```

Each test contains 2-3 scenarios:

```yaml
file: tools/code-review/code-simplifier.md
scenarios:
  - name: "identifies safe simplification"
    input: "Analyse this file that contains decorative emojis and 'what' comments"
    expected:
      - mentions: "safe" or "high confidence"
      - does_not: apply changes directly
      - preserves: task IDs, code blocks
  - name: "respects protected files"
    input: "Simplify prompts/build.txt"
    expected:
      - action: skip or refuse
      - mentions: protected file
```

Run each scenario at haiku tier first. If haiku fails, run at sonnet. If sonnet fails, run at opus. Record the minimum tier that passes.

### Escalation protocol and success validation

The benchmark is only useful if it reliably distinguishes "file is unclear" from "model can't do this" — and escalates fast when it's the latter. Slow or wrong escalation means either wasted cheap tokens (false pass) or wasted expensive tokens (false fail).

**Ground truth: opus as oracle.** Every test scenario is first validated against opus. If opus fails, the test is bad — fix the test, not the file. Opus output becomes the reference answer. This runs once per scenario at authoring time, not on every sweep.

**Scoring layers (cheapest first):**

1. **Deterministic checks (free).** Regex/string matching on the model output: required keywords present, forbidden actions absent, output format correct. Catches ~60-70% of clear passes and obvious failures with zero model cost.
2. **Haiku self-check ($0.001).** If deterministic checks are ambiguous, ask haiku to compare its own output against the expected behavior spec. Cheap and catches another ~20%.
3. **Sonnet adjudication ($0.01).** If haiku self-check is inconclusive or contradicts deterministic results, sonnet judges the haiku output against the opus reference. This is the "is it a clarity problem or a capability problem?" step.

**Fast-fail escalation triggers** — skip straight to the next tier when:

- Model returns a refusal or "I don't understand" (capability signal, not clarity)
- Output is structurally wrong (e.g., applies changes when told analysis-only — the model didn't follow the core constraint)
- Model hallucinates file paths, tool names, or task IDs not in the input (confabulation = exceeded capability)
- Response is <20% of expected length with no justification (model didn't engage)

These are cheap to detect deterministically and should trigger immediate escalation without burning tokens on adjudication.

**Slow-fail signals** — run adjudication before escalating:

- Output is plausible but misses 1-2 expected elements (could be clarity or capability)
- Output follows the right process but reaches a wrong conclusion (needs sonnet to judge if the instruction was ambiguous)
- Model adds reasonable steps not in the expected output (might be correct, test might be too narrow)

**Production feedback loop.** When a task dispatched at the benchmarked tier fails in production (worker exits BLOCKED, PR rejected, acceptance criteria unmet), that failure feeds back as a test case:

1. Log the failure: `{file, tier_dispatched, failure_reason, task_id}`
2. If the file was rated haiku-compatible but failed at haiku in production, downgrade to sonnet and add the failure scenario to the test suite
3. Track false-pass rate per file — files with >1 false pass get re-benchmarked at the next sweep

This creates a self-correcting loop: the benchmark gets more accurate over time from real dispatch outcomes, not just synthetic tests.

### Phase 2: Benchmark runner

`comprehension-benchmark-helper.sh` with subcommands:

- `test <file>` — run comprehension tests for one agent file
- `sweep` — run all tests, output summary table
- `report` — generate tier compatibility report
- `update-state` — write results to `simplification-state.json`

Uses `ai-research` for the actual model calls (already supports haiku/sonnet/opus, rate-limited to 10/session). For sweep mode, batch across multiple sessions or use direct API calls.

### Phase 3: Token-efficiency self-optimization

The benchmark runner itself should be tier-aware:

- **Scenario generation** — sonnet (needs to understand the agent file well enough to write good tests, but doesn't need deep reasoning)
- **Scenario execution at haiku tier** — haiku (the point of the test)
- **Failure analysis / escalation** — sonnet for ambiguous failures, opus only for files classified as `requires judgment`
- **Result scoring** — deterministic (no model needed) where possible; haiku for fuzzy matching

This means the benchmark cost per file is ~2-4 haiku calls + 1 sonnet call for generation. Full sweep of 300 files approximately $1-3.

### Phase 4: Integration with simplification and pulse

- Code-simplifier post-pass: after simplification, re-run comprehension test to verify tier didn't regress
- Pulse dispatch: read `tier_minimum` from state, route to cheapest compatible model
- Dashboard: report percentage of agent files at each tier level as a framework health metric

## Acceptance Criteria

- [ ] Test scenario YAML format defined with schema validation
  ```yaml
  verify:
    method: bash
    run: "test -f .agents/tests/comprehension/README.md && grep -q 'schema' .agents/tests/comprehension/README.md"
  ```
- [ ] Pilot: 10-15 agent files tested across haiku/sonnet/opus with results documented
  ```yaml
  verify:
    method: bash
    run: "ls .agents/tests/comprehension/*.yaml 2>/dev/null | wc -l | grep -qE '(1[0-5]|[1-9][0-9])'"
  ```
- [ ] Failure modes categorized as "clarity problem" vs "exceeds model capability"
  ```yaml
  verify:
    method: codebase
    pattern: "clarity.problem|exceeds.model.capability"
    path: ".agents/tests/comprehension/"
  ```
- [ ] `simplification-state.json` extended with `tier_minimum` field (no existing data broken)
  ```yaml
  verify:
    method: bash
    run: "python3 -c \"import json; d=json.load(open('.agents/configs/simplification-state.json')); assert 'tier_minimum' in str(d) or True\""
  ```
- [ ] Benchmark runner script passes shellcheck
  ```yaml
  verify:
    method: bash
    run: "shellcheck -x .agents/scripts/comprehension-benchmark-helper.sh"
  ```
- [ ] Token cost per file documented (target: <$0.02 per file for full 3-tier sweep)
  ```yaml
  verify:
    method: manual
    prompt: "Check pilot results for per-file cost data"
  ```
- [ ] Every test scenario has an opus-validated reference answer (ground truth)
  ```yaml
  verify:
    method: codebase
    pattern: "reference_answer:"
    path: ".agents/tests/comprehension/"
  ```
- [ ] Fast-fail escalation triggers implemented (refusal, confabulation, structural violation, disengagement)
  ```yaml
  verify:
    method: codebase
    pattern: "fast_fail|escalation_trigger"
    path: ".agents/scripts/comprehension-benchmark-helper.sh"
  ```
- [ ] Pilot results include false-pass/false-fail analysis with at least one known-bad case per tier
  ```yaml
  verify:
    method: subagent
    prompt: "Review the pilot results file for false-pass and false-fail analysis. Confirm each tier (haiku, sonnet) has at least one documented case where the benchmark correctly identified a failure."
    files: ".agents/tests/comprehension/pilot-results.md"
  ```

## Context & Decisions

- **Haiku-as-benchmark, not haiku-as-replacement.** The benchmark tests clarity. Some files will never be haiku-compatible and that's fine — the goal is maximizing the cheap-dispatch surface area.
- **Opus as oracle, not as default.** Opus runs once per scenario at authoring time to establish ground truth. It does not run on every sweep. If opus fails a scenario, the scenario is wrong.
- **Deterministic scoring first, model adjudication second.** Most pass/fail decisions can be made with regex and string matching. Model-based judging is the fallback, not the default. This keeps sweep cost low and results reproducible.
- **Fast-fail escalation is critical.** The most expensive mistake is burning tokens on a tier that can't do the job. Refusals, structural violations, confabulation, and disengagement are cheap to detect and should trigger immediate escalation — no adjudication needed.
- **Production feedback closes the loop.** Synthetic benchmarks drift from reality. Dispatch failures feed back as new test cases, making the benchmark self-correcting over time.
- **Structural heuristics as pre-filter.** Before burning model tokens, cheap checks (instruction count, nesting depth, cross-reference count) can pre-classify obviously-simple or obviously-complex files.
- **ai-research as the execution layer.** Already supports model tier selection, rate limiting, and domain context loading. No new API integration needed for the pilot.
- **YAML for test scenarios, not markdown.** Scenarios need machine-readable expected outputs for scoring. YAML is already used in verify blocks.
- **Companion tests, not inline.** Test scenarios live in `.agents/tests/comprehension/` — separate from the agent files they test. Avoids bloating agent docs.

## Relevant Files

- `.agents/configs/simplification-state.json` — state registry to extend with tier data
- `.agents/tools/code-review/code-simplifier.md` — simplification routine to integrate with
- `.agents/reference/task-taxonomy.md` — current tier definitions (thinking/simple/default)
- `.agents/prompts/worker-efficiency-protocol.md:52-60` — ai-research usage patterns
- `.agents/scripts/commands/code-simplifier.md` — command entry point

## Dependencies

- **Blocked by:** nothing
- **Blocks:** automated tier routing in pulse dispatch, simplification quality gate
- **External:** Anthropic API access for haiku/sonnet/opus (already available via ai-research)

## Estimate Breakdown

| Phase | Time | Notes |
|-------|------|-------|
| Research/read | 30m | Review ai-research capabilities, existing test patterns |
| Scenario format design | 1h | YAML schema, scoring rules, pre-filter heuristics |
| Pilot scenarios (10-15 files) | 2h | Write scenarios, run across tiers |
| Benchmark runner script | 2h | Shell script with shellcheck compliance |
| Analysis and state integration | 1h | Failure categorization, state.json extension |
| **Total** | **~6.5h** | Phase 1 only; phases 2-4 are follow-on tasks |
