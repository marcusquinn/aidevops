---
description: Experiment branch - spike, POC, may not merge
mode: subagent
tools:
  read: true
  write: true
  edit: true
  bash: true
  glob: true
  grep: true
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Experiment Branch

<!-- AI-CONTEXT-START -->

| Aspect | Value |
|--------|-------|
| **Prefix** | `experiment/` |
| **Commit** | `experiment:` or `spike:` |
| **Version** | None (experiments don't get released) |
| **Create from** | `main` |
| **Key rule** | May never merge - that's okay |

```bash
git checkout main && git pull origin main
git checkout -b experiment/{description}
```

<!-- AI-CONTEXT-END -->

## When to Use

POC, technical spikes, exploring new approaches, testing third-party integrations, performance experiments, architecture exploration. May never merge — that's a valid outcome.

## Guidance

### Document the Hypothesis

Before starting, record what you're testing and the expected outcome in the first commit message:

```
experiment: test GraphQL for API layer

Hypothesis: GraphQL could reduce API calls by 60%
Testing: Apollo Server, migrate 3 endpoints, measure performance
```

### Document Results (Even If Not Merging)

When the experiment concludes, document in the PR regardless of outcome:

```markdown
## Experiment: {name}
**Hypothesis**: {what you expected}
**What we tried**: {approach}
**Results**: {what actually happened}
**Conclusion**: Proceeding / Not proceeding — {reason}
**Learnings**: {what to carry forward}
```

### Transitioning to Feature

If the experiment succeeds:

1. **Don't merge experiment directly**
2. Create new `feature/` branch from `main`
3. Cherry-pick or reimplement cleanly
4. Follow normal feature workflow
5. Reference experiment branch in PR for context

## Examples

`experiment/graphql-migration`, `experiment/redis-caching`, `experiment/serverless-functions`, `experiment/lazy-loading-images`, `experiment/microservices-split`
