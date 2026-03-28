---
description: Guidelines for working in multi-repository workspaces
mode: subagent
tools:
  read: true
  write: false
  edit: false
  bash: false
  glob: true
  grep: true
  webfetch: false
  task: true
---

# Multi-Repository Workspace Guidelines

Core principle: **scope every operation to the current repository**. Never assume features, dependencies, or patterns from one repo exist in another.

## Risks

| Risk | Description |
|------|-------------|
| **Feature hallucination** | Assuming features from Repo A exist in Repo B (most critical) |
| **Cross-repo code bleed** | Suggesting patterns/APIs/imports from another repo — causes style mismatches, wrong dependencies, incorrect API assumptions |
| **Documentation confusion** | Documenting features that exist only in other workspace repos |
| **Scope creep** | Suggesting changes based on other repos, inflating scope |
| **Dependency confusion** | Assuming shared dependencies exist across repos when they don't |

## Rules

### 1. Verify Repository Context First

Before making suggestions, documenting features, implementing changes, or running commands:

```bash
git rev-parse --show-toplevel   # repo root
git remote -v                   # confirm identity
git branch --show-current       # branch context
```

### 2. Scope All Searches

Limit code searches to the current repository. Verify search result paths are within the current repo before using them.

```bash
git grep "featureName"                          # respects .gitignore, scoped to repo
grep -r "featureName" --include="*.js" .        # explicit current-dir scope
```

### 3. Verify Before Documenting

1. Search for actual implementation in the current repo (not just references/comments)
2. Review existing docs for intended functionality
3. If uncertain, ask the developer — don't infer from other repos

### 4. Cross-Repo Inspiration

When implementing features inspired by another repo: explicitly mark as new functionality, adapt to the current repo's architecture, and confirm with the developer that adding it is appropriate.

### 5. Handle Repository Switches

When the developer switches repos: acknowledge the switch, reset assumptions (don't carry over context from the previous repo), and verify the new repo's structure, tooling, and conventions.

## Verification Checklist

Before significant changes or recommendations:

- [ ] Verified current working directory/repository
- [ ] Confirmed code searches are scoped to current repo
- [ ] Verified features exist in current repo before documenting
- [ ] Ensured cross-repo inspiration is marked as new functionality
- [ ] Checked dependencies are appropriate for current repo

## Common Workspace Layouts

### Monorepo with Packages

```text
workspace/
├── packages/
│   ├── core/           # Core library
│   ├── ui/             # UI components
│   └── utils/          # Shared utilities
├── apps/
│   ├── web/            # Web application
│   └── mobile/         # Mobile application
└── package.json        # Root workspace config
```

Shared dependencies at root level. Package-specific deps in each package. Cross-package imports use workspace protocols.

### Multiple Separate Repos

```text
workspace/
├── api-service/        # Backend API
├── web-client/         # Frontend application
├── shared-types/       # TypeScript definitions
└── infrastructure/     # IaC configurations
```

Each repo has its own dependencies — no implicit sharing. Shared code must be explicitly published/consumed.

## Warning Signs of Context Confusion

1. Import paths that don't exist in the current repo
2. API references from a different repo
3. Configuration suggestions belonging to another repo
4. Test files that don't exist in the current repo
5. Documentation mentioning features from other repos

## Recovery

If context has been mixed: **stop immediately**, re-verify which repo you're in, review recent actions for incorrect changes, correct any mixed documentation, and inform the developer about the confusion and corrections.
