<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Task Identity Parser Inventory

Snapshot for issue #27148. The shared lexical contract is
`.agents/scripts/task-identity-lib.sh`. This inventory prevents broad regex
replacement in the codec PR; issue #27149 owns consumer migration and must
re-scan before changing each group.

| Consumer group | Representative production files | Migration concern |
|---|---|---|
| Allocation and counters | `claim-task-id.sh`, `claim-task-id-counter.sh`, `claim-task-id-issue.sh` | Preserve legacy emission until the coordinator gate enables namespaced IDs |
| TODO parsing and issue sync | `issue-sync-lib-parse.sh`, `issue-sync-lib-ref.sh`, `issue-sync-helper-commands.sh`, `issue-sync-helper-enrich.sh`, `issue-sync-helper-close.sh` | Parse tokens through the codec and require explicit repository context for legacy resolution |
| Dependency resolution | `pulse-dep-graph.sh`, `issue-sync-relationships.sh`, `parent-status-helper.sh` | Do not strip the `t` prefix or assume the identity body is numeric |
| Brief and plan lookup | `task-brief-helper.sh`, `verify-brief.sh`, `list-todo-helper.sh`, `todo-ready.sh`, `show-plan-helper.sh` | Use canonical tokens as opaque filename and lookup keys after validation |
| Worktree and session routing | `worktree-helper-add.sh`, `pre-edit-check.sh`, `interactive-session-helper.sh` | Avoid partial numeric extraction from namespaced branch tokens |
| PR and dispatch identity | `full-loop-helper-commit.sh`, `dispatch-dedup-helper.sh`, `pulse-dispatch-core.sh`, `pulse-merge-conflict.sh`, `shared-gh-wrappers-create.sh`, `gh` | Preserve complete tokens in titles, markers, dedup keys, and provenance checks |
| Release and completion | `version-manager-git.sh`, `task-complete-helper.sh`, `pre-commit-hook.sh` | Extract complete validated tokens and retain legacy behavior |
| Collision guards and CI | `.agents/hooks/task-id-collision-guard.sh`, `install-task-id-guard.sh`, `.github/workflows/task-id-collision-check.yml` | Scope legacy collisions by verified home repository and namespaced collisions globally |
| Secondary integrations | `beads-sync-helper.sh`, `email-triage-helper.sh`, `self-evolution-helper-todo.sh`, `memory-graduate-helper.sh`, `session_time_common.py` | Replace display-oriented numeric matching only when the integration accepts both forms |

The migration must inventory tests with each production consumer, retain
numeric-only fixtures, and add namespaced and malformed fixtures. Matches in
examples, generated patches, vendored content, or unrelated words such as
`timeout` are not production parsers and must not be mechanically rewritten.
