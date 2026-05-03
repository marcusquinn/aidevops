<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->
# t3536: Define `_projects/` directory contract

## Pre-flight

- [x] Memory recall: `issue 22537 full-loop` → 0 hits — no relevant lessons found.
- [x] Discovery pass: no recent commits, merged PRs, or open PRs touched `.agents/aidevops/projects.md` or `todo/tasks/t3536-brief.md`.
- [x] File refs verified: `.agents/aidevops/knowledge-plane.md`, `.agents/aidevops/campaigns-plane.md`, and parent brief `todo/tasks/t3476-brief.md` present at HEAD.
- [x] Tier: `tier:thinking` — initial plane contract requires design judgment but no dispatch-path files.
- [x] Seeded draft PR decision recorded: skipped — the worker issue body already contains implementation context and this run is the implementing PR.

## Origin

- **Created:** 2026-05-03
- **Session:** Headless worker for GH#22537 / t3536
- **Created by:** ai-worker
- **Parent task:** t3476 / GH#22371
- **Conversation context:** Parent GH#22371 decomposes `_projects/` into five phases. This child implements Phase 1 only: the directory contract for `_projects/<project-id>/` and its relationship to existing TODO/full-loop artefacts.

## What

Create the initial `_projects/` plane contract in `.agents/aidevops/projects.md`, defining directory layout, required files, optional files, project ID rules, manifest fields, versioning/sensitivity defaults, and the relationship to repo-local `TODO.md` / `todo/` planning files.

## Why

Project state spans multiple TODO tasks, GitHub issues, PRs, releases, and verification records. Without a directory contract, later lifecycle, CLI, task-linking, and cross-plane integration phases would invent incompatible layouts or turn `_projects/` into a duplicate execution queue.

## Tier

**Selected tier:** `tier:thinking`

**Tier rationale:** The task modifies two Markdown files and follows existing plane-document patterns, but the contract itself requires schema and lifecycle boundary decisions.

## PR Conventions

This is a leaf child of parent GH#22371. The PR for this task should use `Resolves #22537` for the child issue only. Parent GH#22371 stays open until all planned phases are complete.

## Seeded Draft PR

- **Decision:** Skipped
- **Rationale:** The issue body, parent issue, and referenced plane contracts are sufficient implementation context; a draft PR would add no value.
- **Status:** `not-created`
- **Freshness evidence:** `prework-discovery-helper.sh --keywords "_projects directory contract t3536" --files ".agents/aidevops/projects.md,todo/tasks/t3536-brief.md" --repo "marcusquinn/aidevops"` found no collisions.
- **Verification run:** Pending implementation verification in this task.
- **Stale-assumption warning:** If another PR lands `.agents/aidevops/projects.md` before merge, rebase and reconcile this contract rather than creating a competing plane definition.

## How (Approach)

### Files to Modify

- `NEW: .agents/aidevops/projects.md` — initial `_projects/` plane directory contract, modelled on `.agents/aidevops/knowledge-plane.md` and `.agents/aidevops/campaigns-plane.md`.
- `NEW: todo/tasks/t3536-brief.md` — this worker-ready child brief; the issue expected an edit, but the brief was absent at HEAD.

### Implementation Steps

1. Add `.agents/aidevops/projects.md` with:
   - `_projects/active/<project-id>/` and `_projects/archived/<project-id>/` layout.
   - Required project files and optional folders.
   - Project ID rules and examples.
   - Minimal `project.json` manifest fields.
   - Clear boundary with `TODO.md`, `todo/tasks/`, GitHub issues, PRs, and full-loop evidence.
   - Explicit deferred phases for lifecycle mapping, CLI design, task/evidence link automation, and cross-plane integration.
2. Add this brief because `todo/tasks/t3536-brief.md` did not exist when implementation started.
3. Verify Markdown lint and content checks.

### Verification

```bash
npx --yes markdownlint-cli2 .agents/aidevops/projects.md todo/tasks/t3536-brief.md
test -f .agents/aidevops/projects.md
test -f todo/tasks/t3536-brief.md
gh issue view 22371 --repo marcusquinn/aidevops --json body,state --jq 'select(.state == "OPEN") | .body' | grep -q 't3536 / #22537'
```

### Files Scope

- `.agents/aidevops/projects.md`
- `todo/tasks/t3536-brief.md`

## Acceptance Criteria

- [x] `_projects/<project-id>/` directory layout documented.
- [x] Required files and optional files documented.
- [x] Project ID rules documented.
- [x] Relationship to `TODO.md` and `todo/` planning files documented.
- [x] Out-of-scope phases explicitly deferred.
- [x] Parent GH#22371 remains open and references t3536 / #22537 under `## Children`.

## Relevant Files

- `.agents/aidevops/projects.md` — new contract.
- `.agents/aidevops/knowledge-plane.md` — source-plane contract pattern.
- `.agents/aidevops/campaigns-plane.md` — peer plane contract pattern.
- `todo/tasks/t3476-brief.md` — parent decomposition context.

## Notes

- Existing `_projects/README.md` is a lightweight placeholder for the user-data plane root. This task deliberately defines the framework contract in `.agents/aidevops/projects.md` without implementing provisioners or CLI commands.
