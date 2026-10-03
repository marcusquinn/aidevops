# t18570: refactor(models): retire contest and response-scoring chain, keep /cross-review, route model comparison to model-replay and model-ab

## Origin

- **Created:** 2026-09-30
- **Created by:** ai-interactive
- **Issue:** GH#33145
- **Conversation context:** Framework value audit (parent GH#33139); maintainer approved retiring redundant tooling while keeping the useful ideas.

## Why

The contest and response-scoring chain is unused scaffolding. Model comparison stays useful through model-replay and model A/B evaluation, and `/cross-review` stays, so retiring the chain loses no capability.

## What

The maintainer still wants to compare new models, including across providers. That need is already met by newer, stronger tools:

- `workflows/model-replay.md` plus `model-replay-*.mjs`: isolated replay of past tasks, scored by deterministic checks.
- `model-ab-*.mjs`: live A/B tests on real issues.
- `tools/ai-assistants/frontier-harness-eval.md`.

The older chain (send one prompt to three models, then have a model judge the answers) has no live entry point. It also depends on the archived `pattern-tracker-helper.sh`. Retire it and keep `/cross-review`. Parent: GH#33139.

## How

- Delete:
  - the contest scripts: `contest-helper.sh`, `contest-helper-create.sh`, `contest-helper-dispatch.sh`, `contest-helper-evaluate.sh`, `contest-helper-status.sh`, `contest-helper-apply.sh`
  - `response-scoring-helper.sh`
  - the tests `test-contest-helper.sh` and `test-response-scoring.sh`
  - `/score-responses` (workflow and command)
  - `tools/ai-assistants/response-scoring.md`
- `/cross-review` is live (`commands/cross-review.md:13` calls `compare-models-helper.sh cross-review`). Keep it. Slim `compare-models-helper.sh` down to cross-review plus a model listing that reads `model-registry-helper.sh` data, instead of the hardcoded `MODEL_DATA` that `model-registry-helper.sh:396` currently extracts. Remove `compare-models-bench-lib.sh` and the scoring lib if nothing still needs them.
- Point `/compare-models`, `/compare-models-free` and `tools/ai-assistants/compare-models.md` at the replay, A/B and harness-eval paths for the question "how good is a new model at our work?"
- `generate-models-md.sh` (called from `aidevops-init-lib.sh:951`): drop the performance mode that reads the pattern-tracker and scoring databases, keep the registry-backed global mode, and remove or regenerate `MODELS-PERFORMANCE.md`.
- Update the complexity-threshold comments that name the deleted files.

## Reference pattern

For wording, model the routing doc on how `frontier-harness-eval.md` describes the right tool for each measurement question.

### Files Scope

- `.agents/scripts/contest-helper.sh`
- `.agents/scripts/contest-helper-create.sh`
- `.agents/scripts/contest-helper-dispatch.sh`
- `.agents/scripts/contest-helper-evaluate.sh`
- `.agents/scripts/contest-helper-status.sh`
- `.agents/scripts/contest-helper-apply.sh`
- `.agents/scripts/response-scoring-helper.sh`
- `.agents/scripts/compare-models-helper.sh`
- `.agents/scripts/compare-models-scoring-lib.sh`
- `.agents/scripts/compare-models-bench-lib.sh`
- `.agents/scripts/compare-models-cross-review-lib.sh`
- `.agents/scripts/model-registry-helper.sh`
- `.agents/scripts/model-label-helper.sh`
- `.agents/scripts/generate-models-md.sh`
- `.agents/scripts/aidevops-cli/aidevops-init-lib.sh`
- `.agents/scripts/tests/test-compare-models-catalogue.sh`
- `.agents/scripts/tests/test-cross-review-tier-comparison.sh`
- `.agents/scripts/tests/test-generated-markdown-default-lint.sh`
- `tests/test-contest-helper.sh`
- `tests/test-response-scoring.sh`
- `MODELS-PERFORMANCE.md`
- `.agents/configs/complexity-thresholds.conf`
- `.agents/configs/simplification-state.json`
- `.agents/subagent-index.toon`
- `.agents/tools/ai-assistants/response-scoring.md`
- `.agents/tools/ai-assistants/compare-models.md`
- `.agents/tools/ai-assistants/models-README.md`
- `.agents/tools/ai-assistants/datasets.md`
- `.agents/tools/context/model-routing.md`
- `.agents/tools/local-models/local-models.md`
- `.agents/workflows/cross-review.md`
- `.agents/workflows/compare-models.md`
- `.agents/workflows/compare-models-free.md`
- `.agents/workflows/score-responses.md`
- `.agents/scripts/commands/cross-review.md`
- `.agents/scripts/commands/compare-models.md`
- `.agents/scripts/commands/score-responses.md`
- `.agents/aidevops/claude-flow-comparison.md`
- `.agents/scripts/setup/modules/migrations.sh`

## Acceptance criteria

- [ ] `/cross-review` still dispatches to several models and shows the differences between their answers.
- [ ] `rg -n 'contest-helper|response-scoring' .agents tests` returns only migration entries.
- [ ] The model-comparison docs send "compare a new model" to model-replay, model-ab and harness-eval.
- [ ] `aidevops init` still generates MODELS.md without errors.
- [ ] ShellCheck is clean.

## Verification

```bash
rg -n 'contest-helper|response-scoring|pattern-tracker' .agents tests
bash .agents/scripts/tests/test-cross-review-tier-comparison.sh
shellcheck .agents/scripts/compare-models-helper.sh .agents/scripts/generate-models-md.sh
.agents/scripts/linters-local.sh
```

Parent: #33139
