# Experiment Branch Workflow

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Prefix**: `experiment/`
- **Example**: `experiment/new-auth-approach`, `experiment/performance-spike`
- **Version bump**: None (experiments don't get released)
- **Key rule**: May never merge - that's okay

**Create**:
```bash
git checkout main && git pull origin main
git checkout -b experiment/{description}
```

**Commit pattern**: `experiment: description` or `spike: description`

<!-- AI-CONTEXT-END -->

## When to Use

Use `experiment/` branches for:
- Proof of concept (POC)
- Technical spikes
- Exploring new approaches
- Testing third-party integrations
- Performance experiments
- Architecture exploration
- "What if we tried..." investigations

**Key difference from other branches**: Experiments may never merge, and that's a valid outcome.

## Branch Naming

```bash
# Technical exploration
experiment/graphql-migration
experiment/redis-caching
experiment/serverless-functions

# Performance
experiment/lazy-loading-images
experiment/database-query-optimization

# Architecture
experiment/microservices-split
experiment/event-driven-architecture
```

## Workflow

1. Create branch from updated `main`
2. **Document the hypothesis** (what are you testing?)
3. Implement minimal viable experiment
4. **Document findings** (success or failure)
5. Decide: merge, adapt, or abandon

## The Experiment Mindset

Experiments are about **learning**, not shipping:

- **Success** = You learned something valuable
- **Failure** = You learned what doesn't work (also valuable)
- **Abandoned** = Priorities changed (document why)

## Commit Messages

```bash
experiment: test GraphQL for API layer

Hypothesis: GraphQL could reduce API calls by 60%

Testing:
- Set up Apollo Server
- Migrate 3 endpoints
- Measure performance

Results will be documented in PR description.
```

## Documenting Results

When experiment concludes, document in PR (even if not merging):

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
**Not proceeding** - benefits don't outweigh costs for our use case.

### Learnings
- GraphQL works well for complex nested data
- Our API is mostly flat, so benefit is limited
- Consider for future mobile app API
```

## Version Impact

Experiments have **no version bump**:
- They don't get released
- If successful, create a proper `feature/` branch for the real implementation

## Transitioning to Feature

If experiment succeeds and should be productionized:

1. **Don't merge experiment directly**
2. Create new `feature/` branch from `main`
3. Cherry-pick or reimplement cleanly
4. Follow normal feature workflow
5. Reference experiment branch in PR for context

## Related

- **If experiment succeeds**: `branch/feature.md`
- **Code review**: `workflows/code-review.md` (experiments benefit from early feedback)
