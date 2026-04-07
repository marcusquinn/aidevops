<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Reasoning Brief Format (tier:reasoning)

For tasks requiring deep reasoning. Describe the problem space and constraints.

## Format

```markdown
### Problem

{What needs to be solved, why the obvious approach may be wrong}

### Constraints

- {Hard constraint — must hold}
- {Soft constraint — prefer but can trade off}

### Prior Art

- `path/to/similar.ts` — {how a similar problem was solved}
- {External reference if applicable}

### Acceptance Criteria

- [ ] {Testable criterion}
- [ ] {Testable criterion}
```

## Key principles

- **Problem-first**: Describe the challenge, not the solution
- **Constraints matter**: Hard constraints (must hold) vs soft constraints (prefer)
- **Prior art**: Reference similar solutions in the codebase
- **Testable criteria**: Each criterion must be verifiable, not subjective
