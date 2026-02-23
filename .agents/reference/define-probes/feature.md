---
description: Probing questions for feature tasks — surfaces latent requirements before implementation
mode: subagent
---

# Feature Probes

Use 2 probes from this file during `/define` for tasks classified as **feature**.

## Default Assumptions

Apply these unless the user overrides during interview:

- Minimal footprint — no new dependencies without discussion
- Follow existing patterns in the codebase
- Include tests for new behaviour
- No breaking changes to existing APIs

## Structured Questions

### Scope & Integration

```text
Where does this feature live in the user's workflow?

1. Standalone — accessed from a menu/command/button (recommended)
2. Inline — embedded in an existing flow
3. Background — runs automatically without user action
4. Let me describe the integration point
```

### Data & State

```text
Does this feature need to persist state?

1. No — stateless, computed on demand (recommended)
2. Yes — local storage / file system
3. Yes — database / API
4. Not sure yet
```

## Probes (select 2)

### Pre-mortem

```text
Imagine this feature ships and a user reports a problem within the first week.
What's the most likely complaint?

1. [Inferred from feature description — e.g., "It doesn't handle edge case X"] (recommended)
2. Performance is too slow for large inputs
3. The UI is confusing or hard to discover
4. It conflicts with an existing feature
```

### Backcasting

```text
Working backwards from "done" — what's the very last thing you'd verify
before calling this complete?

1. End-to-end test passes with realistic data (recommended)
2. Documentation is updated
3. Existing features still work (regression check)
4. Let me specify
```

### Domain Grounding

```text
Similar features in this codebase follow [detected pattern].
Should this feature:

1. Follow the same pattern (recommended — consistency)
2. Diverge — here's why: [user explains]
3. I'm not sure what pattern exists — show me
```

### Negative Space

```text
What would make a technically correct implementation unacceptable?

1. If it's too slow (>Xs response time)
2. If it requires a migration or breaking change
3. If it adds significant bundle size / dependencies
4. Nothing — correctness is sufficient
```

### Outside View

```text
Features of this scope in this project typically take [estimated time].
Does that match your expectation?

1. Yes — that's about right
2. No — this should be simpler (~Xh)
3. No — this is more complex (~Xh)
4. I have no estimate yet
```

## Sufficiency Test

Before generating the brief, verify you can answer:

- What does the user see/experience when this is done?
- What existing code does this touch?
- What would a code reviewer reject?
- What's the one edge case most likely to be missed?

If any answer is "I don't know" — ask one more targeted question.
