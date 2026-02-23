---
description: Probing questions for documentation tasks — surfaces audience, accuracy, and maintenance concerns
mode: subagent
---

# Docs Probes

Use 2 probes from this file during `/define` for tasks classified as **docs**.

## Default Assumptions

Apply these unless the user overrides during interview:

- Follow existing documentation patterns and style in the project
- Accurate and verifiable — no speculative claims
- Concise — prefer examples over lengthy explanations
- Maintainable — don't document implementation details that change frequently

## Structured Questions

### Audience

```text
Who is the primary reader of this documentation?

1. Developers using this project (recommended)
2. Contributors to this project
3. End users (non-technical)
4. AI agents / automated systems
```

### Format

```text
What format should this take?

1. Inline code comments / docstrings
2. Markdown file (README, guide, reference) (recommended)
3. API documentation (OpenAPI, JSDoc, etc.)
4. Tutorial / walkthrough with examples
```

## Probes (select 2)

### Accuracy Verification

```text
How will you verify the documentation is accurate?

1. Run the examples / commands described (recommended)
2. Cross-reference with source code
3. Review by someone who uses the feature
4. It's conceptual — accuracy is about clarity, not runnable examples
```

### Staleness Risk

```text
How likely is this documentation to become stale?

1. Low — documents stable interfaces or concepts (recommended)
2. Medium — documents features that evolve quarterly
3. High — documents implementation details that change frequently
4. Not sure
```

### Negative Space

```text
What's the most common mistake someone would make after reading this?

1. Misunderstanding the scope — thinking it covers more than it does
2. Missing a prerequisite or setup step
3. Using an outdated example
4. Nothing obvious — the topic is straightforward
```

### Backcasting

```text
After reading this documentation, what should the reader be able to do?

1. [Inferred from task description] (recommended)
2. Understand the concept but not necessarily implement it
3. Follow step-by-step to a working result
4. Let me specify the learning outcome
```

## Sufficiency Test

Before generating the brief, verify you can answer:

- Who reads this and what do they need to do afterwards?
- What existing docs does this complement or replace?
- How will accuracy be verified?
- What's the maintenance burden?

If any answer is "I don't know" — ask one more targeted question.
