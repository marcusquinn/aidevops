# t1329: Cross-review judge pipeline and /cross-review slash command

## Origin

- **Created:** 2026-02-25
- **Session:** OpenCode:ouroboros-comparison
- **Created by:** human (ai-interactive)
- **Conversation context:** Reviewing joi-lab/ouroboros repo for inspiration. Ouroboros uses multi-model adversarial review (o3/Gemini/Claude review each other's changes before commit). We have the pieces (cross-review dispatch, response-scoring, gemini-reviewer, gpt-reviewer) but they're not chained into an automated pipeline.

## What

An automated pipeline that:
1. Dispatches the same code/prompt to N models via existing `compare-models-helper.sh cross-review`
2. Feeds outputs to a judge model (configurable, default: opus) that scores and declares a winner with reasoning
3. Records results in the existing scoring framework (`response-scoring-helper.sh` or `cmd_score`)
4. Exposes this as a `/cross-review` slash command for interactive use

The user/system will experience: run `/cross-review --prompt "review this PR diff" --models "sonnet,gemini-pro,gpt-4.1"` and get a structured report with per-model scores, a winner, and reasoning — all automatically scored and fed into the pattern tracker.

## Why

The cross-review command and scoring framework exist independently but aren't connected. Ouroboros demonstrated that multi-model adversarial review catches issues single-model review misses. Wiring these together is a small lift with high value — it closes Gap 1 and Gap 4 identified in the codebase exploration.

## How (Approach)

1. Add `--score` flag to `cmd_cross_review()` in `compare-models-helper.sh` (~line 645-867)
2. When `--score` is set, after collecting outputs, spawn a judge model call via `ai-research` (or direct API) that reads all outputs and produces structured scores (correctness/completeness/quality/clarity, 1-10)
3. Feed judge scores into `cmd_score` or `response-scoring-helper.sh record`
4. Create `.agents/scripts/commands/cross-review.md` slash command doc
5. Pattern: follow existing `compare-models.md` and `score-responses.md` command patterns

Key files:
- `.agents/scripts/compare-models-helper.sh:645` — `cmd_cross_review()` function
- `.agents/scripts/compare-models-helper.sh:1396` — `cmd_score()` function
- `.agents/scripts/response-scoring-helper.sh` — scoring framework
- `.agents/scripts/commands/compare-models.md` — existing slash command pattern
- `.agents/scripts/commands/score-responses.md` — existing slash command pattern
- `.agents/tools/ai-assistants/models/gemini-reviewer.md` — cross-provider reviewer
- `.agents/tools/ai-assistants/models/gpt-reviewer.md` — cross-provider reviewer

## Acceptance Criteria

- [ ] `compare-models-helper.sh cross-review --prompt "..." --models "sonnet,gemini-pro" --score` dispatches to models, collects outputs, and auto-scores via judge model
  ```yaml
  verify:
    method: codebase
    pattern: "--score"
    path: ".agents/scripts/compare-models-helper.sh"
  ```
- [ ] Judge model output is structured JSON with per-model scores and winner declaration
- [ ] Scores are recorded in response-scoring or model-comparisons SQLite DB
  ```yaml
  verify:
    method: codebase
    pattern: "cmd_score\\|response-scoring"
    path: ".agents/scripts/compare-models-helper.sh"
  ```
- [ ] `/cross-review` slash command doc exists at `.agents/scripts/commands/cross-review.md`
  ```yaml
  verify:
    method: bash
    run: "test -f .agents/scripts/commands/cross-review.md"
  ```
- [ ] Pattern tracker receives results from cross-review scoring
- [ ] ShellCheck clean on modified scripts
  ```yaml
  verify:
    method: bash
    run: "shellcheck .agents/scripts/compare-models-helper.sh"
  ```

## Context & Decisions

- Inspired by Ouroboros multi-model review (o3/Gemini/Claude consensus before commit)
- We already have all the pieces — this is orchestration/wiring, not new infrastructure
- Judge model defaults to opus (highest reasoning) but is configurable
- Chose to extend existing `cross-review` with `--score` flag rather than creating a new command
- The `/cross-review` slash command is a convenience wrapper, not a new tool

## Relevant Files

- `.agents/scripts/compare-models-helper.sh` — main script to extend
- `.agents/scripts/response-scoring-helper.sh` — scoring framework to integrate
- `.agents/scripts/pattern-tracker-helper.sh` — feedback loop target
- `.agents/scripts/commands/compare-models.md` — pattern for slash command
- `.agents/scripts/commands/score-responses.md` — pattern for slash command

## Dependencies

- **Blocked by:** none
- **Blocks:** nothing critical
- **External:** API keys for multiple providers (already configured)

## Estimate Breakdown

| Phase | Time | Notes |
|-------|------|-------|
| Research/read | 15m | Review cmd_cross_review and cmd_score internals |
| Implementation | 1.5h | Add --score flag, judge prompt, wiring, slash command |
| Testing | 30m | End-to-end test with real models |
| **Total** | **~2h** | |
