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

- `shellcheck .agents/scripts/{file}.sh` exits 0
- `gh pr view --json state` shows MERGED
- Issue closed with closing comment linking PR
```

Without this, workers explore indefinitely or stop after reading files without implementing anything.

## Recovery paths (mandatory)

For each implementation step, include what to do if the expected file/function/pattern is not found:

```markdown
### Implementation Steps

1. Read `.agents/scripts/pulse-wrapper.sh:4254` — the `auto_approve_maintainer_issues()` function
   - **If not found at that line:** `grep -n 'auto_approve_maintainer_issues' .agents/scripts/pulse-wrapper.sh`
   - **If function was renamed/removed:** check `git log --oneline -5 .agents/scripts/pulse-wrapper.sh` for recent changes
```

## Fallback patterns

For each file reference, include a fallback search so the worker doesn't stop on first miss:

```markdown
- EDIT: `.agents/scripts/memory-pressure-monitor.sh:877-888`
  - Fallback: `grep -n 'cmd_daemon' .agents/scripts/memory-pressure-monitor.sh`
```
