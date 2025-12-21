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

- Proof of concept (POC)
- Technical spikes
- Exploring new approaches
- Testing third-party integrations
- Performance experiments
- Architecture exploration
- "What if we tried..." investigations

**Key difference**: Experiments may never merge, and that's a valid outcome.

## The Experiment Mindset

Experiments are about **learning**, not shipping:

- **Success** = You learned something valuable
- **Failure** = You learned what doesn't work (also valuable)
- **Abandoned** = Priorities changed (document why)

## Unique Guidance

### Document the Hypothesis

Before starting, document what you're testing:

```bash
experiment: test GraphQL for API layer

Hypothesis: GraphQL could reduce API calls by 60%

Testing:
- Set up Apollo Server
- Migrate 3 endpoints
- Measure performance
```

### Document Results (Even If Not Merging)

When experiment concludes, document in PR:

```markdown
## Experiment: GraphQL Migration

### Hypothesis
GraphQL could reduce API calls by 60%

### What We Tried
- Migrated user, posts, and comments endpoints
- Implemented DataLoader for batching

### Results
- API calls reduced by 45% (not 60%)
- Complexity increased significantly
- Team learning curve is steep

### Conclusion
**Not proceeding** - benefits don't outweigh costs.

### Learnings
- GraphQL works well for complex nested data
- Our API is mostly flat, so benefit is limited
- Consider for future mobile app API
```

### Transitioning to Feature

If experiment succeeds and should be productionized:

1. **Don't merge experiment directly**
2. Create new `feature/` branch from `main`
3. Cherry-pick or reimplement cleanly
4. Follow normal feature workflow
5. Reference experiment branch in PR for context

## Examples

```bash
experiment/graphql-migration
experiment/redis-caching
experiment/serverless-functions
experiment/lazy-loading-images
experiment/microservices-split
```
