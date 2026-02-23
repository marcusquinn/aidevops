---
description: Probing questions for refactor tasks — surfaces behaviour preservation constraints and migration risks
mode: subagent
---

# Refactor Probes

Use 2 probes from this file during `/define` for tasks classified as **refactor**.

## Default Assumptions

Apply these unless the user overrides during interview:

- Zero behaviour changes — all existing tests must pass unchanged
- No new dependencies
- Improve readability, maintainability, or performance (pick one primary goal)
- If tests don't exist for the refactored code, add them before refactoring

## Structured Questions

### Primary Goal

```text
What's the main reason for this refactor?

1. Readability — code is hard to understand or maintain (recommended)
2. Performance — current implementation is too slow
3. Extensibility — need to add features and current structure blocks it
4. Duplication — same logic exists in multiple places
5. Let me explain
```

### Scope Boundary

```text
How far should this refactor go?

1. Minimal — only the specific file/function mentioned (recommended)
2. Module-level — refactor the entire module for consistency
3. Cross-cutting — follow the pattern change across the codebase
4. Let me specify the boundary
```

## Probes (select 2)

### Behaviour Preservation

```text
How will you verify that behaviour hasn't changed?

1. Existing tests cover it — they must all pass (recommended)
2. No tests exist — I'll add them before refactoring
3. Manual testing against specific scenarios
4. Type system / compiler will catch regressions
```

### Outside View

```text
Refactors of this scope in this codebase typically follow [detected pattern].
Should this refactor:

1. Follow the same approach (recommended — consistency)
2. Establish a new pattern — here's why: [user explains]
3. I'm not sure what the existing pattern is
```

### Pre-mortem

```text
Imagine this refactor is merged and something breaks in production.
What's the most likely cause?

1. A code path that wasn't covered by tests (recommended)
2. Subtle behaviour change in edge cases
3. Performance regression under load
4. Downstream consumers that depend on internal implementation details
```

### Assumption Surfacing

```text
I'm assuming this refactor should NOT change the public API / interface.
Is that correct?

1. Correct — internal changes only (recommended)
2. No — the API should change too (this might be a feature, not a refactor)
3. The API can change if callers are updated in the same PR
```

### Domain Grounding

```text
The [language/framework] community typically recommends [pattern] for this kind of restructuring.
Does that apply here?

1. Yes — follow the standard approach (recommended)
2. Partially — adapt it because [reason]
3. No — this codebase has its own conventions
```

## Sufficiency Test

Before generating the brief, verify you can answer:

- What tests exist for the code being refactored?
- What's the public API that must not change?
- What's the primary metric that improves (readability/performance/extensibility)?
- What would a code reviewer check to verify behaviour preservation?

If any answer is "I don't know" — ask one more targeted question.
