<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Standard Brief Format (tier:standard)

For tasks requiring judgment. Provide skeletons rather than verbatim code.

## Format

```markdown
### Files to Modify

- `EDIT: path/to/file.ts:45-60` — {what to change and why}
- `NEW: path/to/new-file.ts` — {purpose, model on `path/to/reference.ts`}

### Implementation Steps

1. Read `path/to/reference.ts` for the existing pattern
2. {Step with code skeleton:}

\`\`\`typescript
// Function signature and structure — worker fills in logic
export function handleAuth(req: Request): Response {
  // TODO: validate token using pattern from middleware/auth.ts:12
  // TODO: check role using checkRole() at roles.ts:22
}
\`\`\`

3. {Verification step}

### Verification
\`\`\`bash
{commands to confirm implementation}
\`\`\`
```

## Key principles

- **Skeletons, not verbatim**: Provide function signatures and structure; worker fills in logic
- **Reference patterns**: Point to existing code that demonstrates the pattern
- **Line ranges**: Use `file:line-line` format for clarity
- **Judgment required**: Worker decides approach, error handling, edge cases
