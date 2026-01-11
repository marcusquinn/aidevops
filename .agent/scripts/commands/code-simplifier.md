---
description: Simplify and refine code for clarity, consistency, and maintainability
agent: Build+
mode: subagent
---

Simplify and refine code for clarity, consistency, and maintainability while preserving all functionality.

Target: $ARGUMENTS

## Quick Reference

- **Purpose**: Simplify code without changing functionality
- **Priority**: Clarity over brevity
- **Scope**: Recently modified code unless target specified

## Process

1. **Identify scope**: Use $ARGUMENTS if provided, otherwise find recently modified files
2. **Read the code-simplifier agent**: `tools/code-review/code-simplifier.md`
3. **Apply refinements** following the agent's principles
4. **Verify** functionality is preserved
5. **Report** changes made

## Scope Detection

If no target specified ($ARGUMENTS is empty):

```bash
# Find recently modified files (last commit or staged)
git diff --name-only HEAD~1
git diff --name-only --staged
```

If target specified:
- Directory path: Simplify all code files in directory
- File path: Simplify specific file
- `--all`: Review entire codebase (use sparingly)

## Refinement Principles

From `tools/code-review/code-simplifier.md`:

1. **Preserve Functionality**: Never change what code does
2. **Apply Project Standards**: Follow CLAUDE.md/AGENTS.md conventions
3. **Enhance Clarity**: Reduce complexity, eliminate redundancy
4. **Maintain Balance**: Avoid over-simplification
5. **Focus Scope**: Only refine recently modified code unless instructed otherwise

## Key Patterns to Fix

- Nested ternaries -> switch/if-else chains
- Dense one-liners -> readable multi-line
- Redundant abstractions -> direct code
- Obvious comments -> remove
- Inconsistent naming -> standardize

## Output Format

```text
Code Simplification Report
==========================

Files reviewed: {count}
Changes made: {count}

{file1}:
  - Line {n}: {before} -> {after}
  - Line {m}: Removed redundant {description}

{file2}:
  - Line {n}: Simplified nested ternary to if/else

Functionality: Preserved
```

## Integration

After simplification, suggest:

```text
Next steps:
1. Run /linters-local to validate
2. Review changes with git diff
3. Commit if satisfied
```
