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
- **Done When is mandatory**: Every brief must include a concrete completion signal (see below)
- **Recovery paths**: For each step, include what to do if the expected file/pattern is not found

## Done When (required section)

Every tier:standard issue body must end with a machine-verifiable completion condition:

```markdown
### Done When

- `{lint/test command}` exits 0
- PR exists with `Closes #{issue_number}` and MERGE_SUMMARY comment posted
- Issue closed with closing comment linking PR
```

Without this, workers explore indefinitely or stop after reading files without implementing anything.

## Fallback patterns

For each file reference, include a fallback search so the worker doesn't stop on first miss:

```markdown
- EDIT: `path/to/file.ts:45-60` -- {what to change}
  - Fallback: `grep -n 'functionName' path/to/file.ts`
```
