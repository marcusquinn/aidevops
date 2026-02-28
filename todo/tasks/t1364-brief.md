# t1364: Multi-Model Orchestration Improvements (Parallel Verification + Bundle Presets)

## Origin

- **Created:** 2026-02-28
- **Session:** claude-code:headless
- **Created by:** ai-interactive
- **Parent task:** none (umbrella for #2558 near-term items)
- **Conversation context:** User requested task decomposition for issue #2558 — a research review comparing aidevops against Perplexity Computer and Microsoft Amplifier. This task covers the two near-term improvements: parallel model verification (item 1) and bundle-based project presets (item 4).

## What

Two independent workstreams that improve aidevops reliability and performance:

1. **Parallel model verification** (t1364.1-t1364.3): Before destructive operations (force push, production deploy, data migration), invoke a second cross-provider model as an independent verifier. Different providers have different failure modes, so correlated errors are rare. Targeted verification only — not full council-style parallel invocation on every task.

2. **Bundle-based project presets** (t1364.4-t1364.6): Composable configuration packages per project type (web-app, CLI tool, infrastructure, content-site) that pre-configure model tier defaults, quality gates, and agent routing. Declared in repos.json or auto-detected from project structure.

## Why

- **Verification**: Single-model hallucinations on destructive operations can cause irreversible damage. The cost of a second model call is negligible compared to the cost of a force-push to the wrong branch or a botched production deploy.
- **Bundles**: Currently every project gets the same quality gates and model routing. This wastes time (ShellCheck on content sites) and under-provisions (haiku for complex web-app architecture). Right-sized defaults improve both speed and quality.

## How (Approach)

### Workstream 1: Parallel Verification
- Define taxonomy of high-stakes operations in `.agents/reference/high-stakes-operations.md`
- Create verification agent doc at `.agents/tools/verification/parallel-verify.md`
- Create `verify-operation-helper.sh` with verify/check/config subcommands
- Wire into pre-edit-check.sh, dispatch.sh, and full-loop
- Use `ai-research` MCP for cross-provider model calls
- Build on existing cross-review pipeline (t1329), gemini-reviewer.md, gpt-reviewer.md

### Workstream 2: Bundle Presets
- Design bundle JSON schema with model_defaults, quality_gates, skip_gates, agent_routing, dispatch settings
- Create default bundles in `.agents/bundles/` for 6 project types
- Create `bundle-helper.sh` with detect/resolve/show/list/validate subcommands
- Auto-detect project type from marker files (package.json, Dockerfile, etc.)
- Wire into dispatch.sh, linters-local.sh, agent routing
- Extend repos.json with optional `bundle` field

### Key files to modify
- `.agents/scripts/pre-edit-check.sh` — add verification hook
- `.agents/scripts/supervisor/dispatch.sh` — add verification + bundle integration
- `.agents/tools/context/model-routing.md` — document bundle interaction
- `~/.config/aidevops/repos.json` — extend schema with bundle field
- `.agents/AGENTS.md` — document both capabilities

## Acceptance Criteria

- [ ] High-stakes operation taxonomy defined with at least 5 categories
  ```yaml
  verify:
    method: codebase
    pattern: "high-stakes-operations"
    path: ".agents/reference/"
  ```
- [ ] Verification agent doc exists with cross-provider selection logic
  ```yaml
  verify:
    method: bash
    run: "test -f .agents/tools/verification/parallel-verify.md"
  ```
- [ ] verify-operation-helper.sh passes ShellCheck
  ```yaml
  verify:
    method: bash
    run: "shellcheck .agents/scripts/verify-operation-helper.sh"
  ```
- [ ] At least 6 default bundle definitions exist
  ```yaml
  verify:
    method: bash
    run: "test $(ls .agents/bundles/*.json 2>/dev/null | wc -l) -ge 6"
  ```
- [ ] bundle-helper.sh detect correctly identifies project types
  ```yaml
  verify:
    method: bash
    run: "shellcheck .agents/scripts/bundle-helper.sh"
  ```
- [ ] Bundle resolution integrates with dispatch pipeline
  ```yaml
  verify:
    method: codebase
    pattern: "get_bundle_config\\|bundle-helper"
    path: ".agents/scripts/supervisor/"
  ```

## Context & Decisions

- Inspired by Perplexity Computer's "model council" but deliberately scoped down — targeted verification on high-stakes ops only, not every task
- Cross-provider verification preferred over same-provider (Anthropic primary → Google verifier) because different providers have different failure modes
- Bundle system uses composition (multiple bundles can combine) rather than inheritance
- Auto-detection is a convenience — explicit bundle in repos.json always takes precedence
- Mid-term items (confidence-weighted selection, modular supervisor) are deferred to separate tasks

## Relevant Files

- `.agents/tools/context/model-routing.md` — current model routing system
- `.agents/scripts/pre-edit-check.sh` — where verification hooks go
- `.agents/scripts/supervisor/dispatch.sh` — dispatch pipeline
- `~/.config/aidevops/repos.json` — repo configuration
- `.agents/scripts/linters-local.sh` — quality gate runner

## Dependencies

- **Blocked by:** none
- **Blocks:** mid-term items from #2558 (confidence-weighted selection, modular supervisor)
- **External:** none

## Estimate Breakdown

| Phase | Time | Notes |
|-------|------|-------|
| Research/read | 1h | Review existing cross-review, model routing, dispatch |
| Verification workstream | 9h | Taxonomy + agent + wiring |
| Bundle workstream | 10h | Schema + detection + wiring |
| **Total** | **~20h** | Two independent workstreams, parallelisable |
