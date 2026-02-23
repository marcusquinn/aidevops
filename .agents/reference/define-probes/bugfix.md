---
description: Probing questions for bugfix tasks — surfaces reproduction context and regression risks
mode: subagent
---

# Bugfix Probes

Use 2 probes from this file during `/define` for tasks classified as **bugfix**.

## Default Assumptions

Apply these unless the user overrides during interview:

- Preserve all existing behaviour except the bug
- Add a regression test that fails before the fix and passes after
- Root-cause fix preferred over symptom suppression
- No scope creep — fix the reported bug, not adjacent issues

## Structured Questions

### Reproduction

```text
Can you reproduce this bug reliably?

1. Yes — here are the steps: [user provides]
2. Intermittent — happens sometimes under [conditions]
3. Reported by others — I haven't reproduced it myself
4. Only in production / specific environment
```

### Expected vs Actual

```text
What's the expected behaviour vs what actually happens?

1. [Inferred from description] (recommended)
2. Let me describe both explicitly
```

## Probes (select 2)

### Root Cause vs Symptom

```text
Is the fix you have in mind addressing the root cause or a symptom?

1. Root cause — I know why it breaks (recommended)
2. Symptom — I know a workaround but not the underlying issue
3. Not sure — needs investigation first
```

### Blast Radius

```text
What else could break when this is fixed?

1. Nothing — the fix is isolated to one code path (recommended)
2. Related features that share the same code path
3. Not sure — need to trace dependencies
4. Let me specify what's at risk
```

### Regression Context

```text
Did this work before? If so, what changed?

1. Yes — broke after a recent commit/deploy (regression)
2. Never worked correctly — latent bug
3. Works in some environments but not others
4. Not sure when it started
```

### Assumption Surfacing

```text
I'm assuming this bug affects [inferred scope — e.g., "all users" or "only mobile"].
Is that correct?

1. Yes — affects [scope]
2. No — it's narrower: [user specifies]
3. No — it's broader: [user specifies]
```

### Pre-mortem

```text
Imagine the fix ships but the bug comes back in a different form.
What's the most likely variant?

1. Same root cause, different trigger (recommended)
2. Fix introduces a new bug in adjacent code
3. Fix works locally but not in production
4. The original report was incomplete — there's a deeper issue
```

## Sufficiency Test

Before generating the brief, verify you can answer:

- Can I reproduce this (or do I have clear reproduction steps)?
- Do I know the root cause or at least where to look?
- What regression test would catch this if it recurs?
- What's the blast radius of the fix?

If any answer is "I don't know" — ask one more targeted question.
