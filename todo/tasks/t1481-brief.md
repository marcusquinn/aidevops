<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# t1481: Centralize Routing Taxonomy Tables

## Session Origin

Interactive session (2026-03-14). Follow-up from PR #4573 which added agent routing labels and model tier labels to three task creation commands. CodeRabbit review noted the duplication.

## What

Extract the duplicated domain-routing table (10 rows: seo, content, marketing, accounts, legal, research, sales, social-media, video, health) and model-tier classification table (2 rows: thinking, simple) from three command files into a single canonical reference file.

**Current state:** Each of `new-task.md`, `save-todo.md`, and `define.md` contains its own copy of both tables with slightly different column structures and wording.

**Target state:** One reference file (`reference/task-taxonomy.md` or similar) defines both tables authoritatively. Each command file references it with a one-line pointer.

## Why

- Three copies of the same data means three places to update when a domain or tier is added/changed
- The tables already have minor wording differences across files (e.g., "Architecture decisions, novel design with no existing patterns" vs "Architecture, novel design, complex trade-offs")
- CodeRabbit flagged this in PR #4573 review

## How

1. Create `reference/task-taxonomy.md` (or `.agents/reference/task-taxonomy.md`) with:
   - Domain routing table: domain keyword indicators, GitHub label, agent name
   - Model tier table: tier name, label, criteria
   - Brief usage instructions for task creation commands
2. In `new-task.md`, `save-todo.md`, `define.md`: replace inline tables with a reference pointer (e.g., "See `reference/task-taxonomy.md` for domain and tier classification tables")
3. Ensure pulse.md's label consumption docs cross-reference the same file

## Acceptance Criteria

- [ ] Single canonical file contains both taxonomy tables
- [ ] All three command files reference the canonical file instead of inline tables
- [ ] No information lost — canonical tables are a superset of all three versions
- [ ] ShellCheck clean (no shell files changed, but verify)
- [ ] Markdown lint clean on all modified files
