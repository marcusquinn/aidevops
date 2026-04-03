---
description: Probing questions for feature tasks — surfaces latent requirements before implementation
mode: subagent
---

# Feature Probes

Use 2 probes from this file during `/define` for tasks classified as **feature**.

**Defaults** (apply unless overridden): minimal footprint, follow existing patterns, include tests for new behaviour, no breaking API changes.

## Required Questions

**Scope & Integration** — Where does this feature live in the user's workflow?

1. Standalone — menu/command/button (recommended)
2. Inline — embedded in an existing flow
3. Background — runs automatically without user action
4. Let me describe the integration point

**Data & State** — Does this feature need to persist state?

1. No — stateless, computed on demand (recommended)
2. Yes — local storage / file system
3. Yes — database / API
4. Not sure yet

## Probes (select 2)

**Pre-mortem** — Feature ships, user reports a problem in week one. Most likely complaint?

1. [Inferred from description — e.g., "Doesn't handle edge case X"] (recommended)
2. Performance too slow for large inputs
3. UI confusing or hard to discover
4. Conflicts with an existing feature

**Backcasting** — Working backwards from "done", what's the last thing you'd verify?

1. End-to-end test passes with realistic data (recommended)
2. Documentation updated
3. Existing features still work (regression check)
4. Let me specify

**Domain Grounding** — Similar features follow [detected pattern]. Should this feature:

1. Follow the same pattern (recommended — consistency)
2. Diverge — here's why: [user explains]
3. Not sure what pattern exists — show me

**Negative Space** — What makes a technically correct implementation unacceptable?

1. Too slow (>Xs response time)
2. Requires migration or breaking change
3. Adds significant bundle size / dependencies
4. Nothing — correctness is sufficient

**Outside View** — Features of this scope typically take [estimated time]. Match your expectation?

1. Yes — about right
2. No — should be simpler (~Xh)
3. No — more complex (~Xh)
4. No estimate yet

## Sufficiency Test

Before generating the brief, verify you can answer all four:

- What does the user see/experience when done?
- What existing code does this touch?
- What would a code reviewer reject?
- What's the one edge case most likely missed?

If any answer is "I don't know" — ask one more targeted question.
