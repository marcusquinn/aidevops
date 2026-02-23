---
description: Probing questions for research/spike tasks — surfaces time-box, deliverable format, and decision criteria
mode: subagent
---

# Research Probes

Use 2 probes from this file during `/define` for tasks classified as **research**.

## Default Assumptions

Apply these unless the user overrides during interview:

- Time-boxed — research without a deadline expands indefinitely
- Deliverable is a written recommendation, not code
- Compare at least 2 options (never recommend without alternatives)
- Include cost/effort estimates for each option

## Structured Questions

### Time Box

```text
How much time should be spent on this research?

1. 30 minutes — quick comparison (recommended for simple evaluations)
2. 1-2 hours — thorough analysis with examples
3. Half day — deep dive with prototypes
4. Let me specify
```

### Deliverable Format

```text
What should the research produce?

1. Written recommendation with pros/cons table (recommended)
2. Prototype / proof of concept
3. Decision document for team review
4. Just a verbal summary in this conversation
```

## Probes (select 2)

### Decision Criteria

```text
What matters most when choosing between options?

1. Cost (monetary or compute) (recommended if comparing services/tools)
2. Developer experience / ease of integration
3. Performance / scalability
4. Community support / longevity
5. Let me rank my priorities
```

### Assumption Surfacing

```text
I'm assuming the decision will be made by [you / the team / a specific person].
Who needs to be convinced?

1. Just me — I'll decide based on the research (recommended)
2. The team — needs to be presentable
3. A specific stakeholder — needs to address their concerns
4. No decision needed — this is exploratory
```

### Outside View

```text
Have you or the team evaluated similar options before?
What was the outcome?

1. Yes — we chose [X] last time, checking if it's still the best option
2. Yes — we rejected [X] last time, want to reconsider
3. No — this is a new area for us
4. Not sure — I'll check
```

### Pre-mortem

```text
Imagine you pick an option based on this research and regret it 3 months later.
What's the most likely reason?

1. Hidden costs or limitations that weren't obvious during evaluation (recommended)
2. The chosen option doesn't scale as expected
3. A better option emerged after the decision
4. The evaluation criteria were wrong
```

### Backcasting

```text
After this research is done, what's the next concrete action?

1. Implement the recommended option (recommended)
2. Present findings and get approval
3. Create a task/brief for the implementation
4. Nothing immediate — this is for future reference
```

## Sufficiency Test

Before generating the brief, verify you can answer:

- What's the time box?
- What format is the deliverable?
- What are the decision criteria, ranked?
- Who makes the final decision?

If any answer is "I don't know" — ask one more targeted question.
