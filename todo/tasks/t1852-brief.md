<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Task Brief: Simplify Screaming Frog SEO Spider agent (t1852)

## Summary
Review and simplify the `.agents/seo/screaming-frog.md` subagent file to be more concise while retaining essential information.

## Context
- **Session Origin**: User request to review and simplify the agent file.
- **What**: Reduce the line count of `.agents/seo/screaming-frog.md` from 62 to ~41 lines.
- **Why**: Improve instruction efficiency and follow the "Instruction budget" principle.
- **How**: 
    - Merge "Setup" into "Quick Reference".
    - Consolidate "Usage" sections.
    - Simplify "Integration" descriptions.
    - Remove non-essential platform-specific notes (Linux/Windows) and obvious GUI instructions.

## Acceptance Criteria
- [ ] File `.agents/seo/screaming-frog.md` is ~41 lines.
- [ ] Retains Purpose, License, Command, Setup, Usage, and Integration.
- [ ] Follows aidevops agent formatting (frontmatter, AI-CONTEXT blocks).
- [ ] Passes `linters-local.sh`.

## Contextual References
- Original file: `.agents/seo/screaming-frog.md` (62 lines)
- Proposed content: Provided in session.
