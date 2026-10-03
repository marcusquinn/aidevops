# t18564: Framework value audit: retire obsolete scaffolding and keep the ideas worth keeping

## Origin

- **Created:** 2026-09-30
- **Created by:** ai-interactive
- **Issue:** GH#33139
- **Conversation context:** Framework value audit (parent GH#33139); maintainer approved retiring redundant tooling while keeping the useful ideas.

Planning-only: parent tracker for the framework value audit. Children carry the implementation.

## Why

Current models and harnesses make some aidevops scaffolding redundant. Each item costs setup time, context and maintenance. This parent tracks retiring it while keeping the ideas that still add value, including for smaller models.

## What

This audit, run with the maintainer in an interactive session on 2026-09-30, asked which parts of aidevops no longer earn their place given current frontier models and modern harnesses. It aims to retire those parts while keeping any idea behind them that is still worth having.

## Decision rule

Keep anything that provides:

- access: MCPs, APIs, credentials, account workflows
- deterministic mechanics: gates, hooks, worktree safety
- durable state: memory, TODO.md, issues
- post-cutoff facts or house decisions
- exact data models cannot recall, such as brand tokens

Retire generic knowledge restatement, reasoning crutches such as self-grading loops and prompt optimisers, token-squeezing wrappers, and code indexing.

## Decisions (maintainer-confirmed)

- **Keep:** TOON, `subagent-index.toon`, the design library, model availability and fallback checks, `/autoresearch`, the pageindex generator, Context7, `/cross-review`, the Drizzle-specific docs, and the Cloudflare and Remotion knowledge (after refresh).
- **Retire:**
  - osgrep and Augment leftovers, llm-tldr, context-builder/repomix, rapidfuzz
  - DSPy and DSPyGround
  - the Ralph loop
  - the contest and response-scoring chain
  - dead pattern-tracker callers
  - Beads
  - `todo-ready.sh`, `mission-skill-learner.sh`
  - textbook skills: modern-javascript, clean-ddd-hexagonal, feature-slicing
  - `claude-flow-comparison.md`
- **Replace:**
  - Beads becomes an issue/PR discussion archive on a separate branch in the same repo, written by a routine the pulse runs.
  - The Ralph loop becomes a keep-going hook for Claude Code, matching OpenCode's `session-continuation-guard.mjs`.
  - The contest chain is replaced by model-replay, model-ab and `frontier-harness-eval`, which already exist.
- **Ideas captured from retired code:**
  - Rule-violation counts from `ttsr.mjs` feed the list of rules that should become hooks.
  - Evidence-based model tier step-down belongs with model-ab data, not the archived pattern tracker.

## Children

Children are linked as sub-issues. GH#33135 (skill-update checker fix) is the prerequisite for the Remotion/Cloudflare re-sync child.

### Files Scope

- `TODO.md`

## Acceptance criteria

- [ ] All child issues closed with merged PRs.
- [ ] `rg -i 'osgrep|auggie|augment|llm-tldr|dspy|ralph|beads|contest-helper|response-scoring' .agents README.md setup.sh` shows only deliberate migration and cleanup code or historical entries.
