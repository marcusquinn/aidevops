# Projects Plane — Directory Contract

<!-- AI-CONTEXT-START -->

The `_projects/` plane is an opt-in user-data plane for structured project
lifecycle state. It captures the project-level context that is too durable for a
single TODO entry and too operational for `_knowledge/`: goals, plans,
milestones, decisions, risks, execution links, verification evidence, and
post-completion outcomes.

For cross-plane routing metadata, use `.agents/configs/data-planes.json` as the
canonical registry once `_projects/` is added there. This document owns the
`_projects/` directory contract; the registry owns shared facts such as default
sensitivity, ingress/egress surfaces, helper names, and retrieval behaviour.

## Purpose and Boundaries

`_projects/` is a context plane, not an execution queue.

- `TODO.md` remains the repo-local source of atomic work items and routine
  scheduling.
- `todo/tasks/` remains the worker-ready brief store for executable tasks.
- GitHub issues, PRs, commits, releases, and full-loop comments remain the audit
  trail for implementation.
- `_projects/` links those artefacts into a project-level narrative so multi-task
  work can survive across sessions, repos, and lifecycle phases.

Use `_projects/` when a goal spans more than one task, repo, worker run, or
delivery milestone. Do not use it for one-off issues that can be understood from
their TODO entry and GitHub thread alone.

## Directory Layout

```text
_projects/
├── .gitignore                   # Local-only working areas ignored by default
├── PROJECTS.md                  # User-facing plane overview (written at provision time)
├── _config/
│   └── projects.json            # Plane defaults and status/ID policy
├── active/                      # In-flight projects (versioned by default)
│   └── <project-id>/
│       ├── project.json         # Required machine-readable manifest
│       ├── README.md            # Required human overview and current state
│       ├── plan.md              # Required milestones, phases, and scope
│       ├── tasks.md             # Required TODO/GitHub/PR/release links
│       ├── decisions.md         # Required ADR-style decision log
│       ├── risks.md             # Required risk, blocker, and dependency log
│       ├── evidence/            # Verification logs, screenshots, release notes
│       └── notes/               # Local working notes; gitignored by default
├── archived/
│   └── <project-id>/            # Completed or abandoned projects
│       ├── project.json
│       ├── README.md
│       ├── plan.md
│       ├── tasks.md
│       ├── decisions.md
│       ├── risks.md
│       ├── outcomes.md          # Required when archived
│       └── evidence/
└── index/                       # Generated search/cache data; gitignored
```

Phase 1 defines the contract only. Provisioning commands, migrations, validators,
and registry integration are deferred to later phases.

## Required Files per Project

Every `_projects/active/<project-id>/` directory must contain these files before
it is considered a valid project record:

| File | Purpose |
|------|---------|
| `project.json` | Machine-readable manifest: ID, title, status, owning repo(s), sensitivity, creation timestamp, and cross-plane links. |
| `README.md` | Human-readable project summary, current state, next milestone, and navigation links. |
| `plan.md` | Scope, milestones, phase decomposition, acceptance criteria, and explicit out-of-scope items. |
| `tasks.md` | Durable links to TODO IDs, task briefs, GitHub issues, PRs, releases, and full-loop evidence comments. |
| `decisions.md` | Chronological decisions with date, context, decision, alternatives considered, and follow-up links. |
| `risks.md` | Open risks, blockers, dependencies, mitigations, owners, and review dates. |

`archived/<project-id>/` keeps the same required files and adds `outcomes.md` to
capture final status, verification evidence, shipped value, lessons learned, and
any revival criteria.

## Optional Files and Folders

| Path | When to use |
|------|-------------|
| `evidence/` | Store durable verification artefacts: command outputs, release notes, screenshots, metrics snapshots, and generated reports that are safe to version. |
| `notes/` | Local working notes, scratch plans, and private drafts. Gitignored by default because notes may contain sensitive context not ready for audit trails. |
| `requirements/` | Product, client, or stakeholder requirements promoted from `_feedback/`, `_cases/`, or discovery. |
| `research/` | Project-specific research that has not yet become reusable `_knowledge/`. Promote durable learnings to `_knowledge/insights/` when they generalise. |
| `assets/` | Project-specific non-code artefacts below the blob threshold. Large binaries should use the shared blob-store pattern from the knowledge plane. |
| `outcomes.md` | Required after archive; optional during active work for rolling outcome notes. |

Optional folders must not become hidden execution queues. If a note requires code
or operational work, create or link a TODO entry and GitHub issue in `tasks.md`.

## Project ID Rules

Project IDs are stable slugs scoped to one repo or personal workspace.

- Format: lowercase kebab-case, `^[a-z0-9][a-z0-9-]{2,79}$`.
- Allowed characters: `a-z`, `0-9`, and single hyphens between words.
- Forbidden: uppercase, spaces, underscores, path separators, leading/trailing
  hyphens, repeated hyphens, bare task IDs (`t3536`), and GitHub-only IDs
  (`gh-22537`) unless the external ID is followed by a descriptive slug.
- Recommended convention: `<domain>-<goal>` or `<yyyy>-<goal>`; examples:
  `billing-reconciliation`, `2026-projects-plane`, `client-onboarding-rework`.
- IDs are immutable after creation. Renames require creating a new directory,
  preserving the old directory as an archive stub, and recording the move in both
  manifests.
- IDs are not global. Cross-repo references must include the repo slug or
  workspace scope in `project.json` links.

## `project.json` Manifest

Minimum manifest:

```json
{
  "version": 1,
  "id": "2026-projects-plane",
  "title": "Projects plane contract",
  "status": "intake|planning|active|blocked|verifying|completed|archived|abandoned",
  "created_at": "2026-05-03T00:00:00Z",
  "updated_at": "2026-05-03T00:00:00Z",
  "sensitivity": "internal",
  "repos": ["owner/repo"],
  "todo_tasks": ["t3536"],
  "github_issues": [22537],
  "github_prs": [],
  "cross_plane": {
    "knowledge": [],
    "cases": [],
    "campaigns": [],
    "performance": [],
    "feedback": []
  }
}
```

Fields may grow in later lifecycle and CLI phases, but Phase 1 reserves these
names so future tooling has a stable base.

## TODO.md and `todo/` Relationship

`_projects/` aggregates execution records; it does not replace them.

| Existing artefact | Relationship to `_projects/` |
|-------------------|------------------------------|
| `TODO.md` | Canonical atomic work queue. Project records link to TODO IDs but do not duplicate TODO task text as an alternative backlog. |
| `todo/tasks/<task-id>-brief.md` | Canonical worker-ready implementation context for a task. Project `tasks.md` links briefs and summarises how each task advances a milestone. |
| GitHub issues | Canonical external work thread and dispatch target. Project `tasks.md` records issue numbers and current lifecycle state for navigation. |
| PRs and commits | Canonical code audit trail. Project `tasks.md` and `evidence/` link PRs, merge summaries, release notes, and verification commands. |
| Full-loop evidence | Canonical proof that a task completed. Project records link to merge summaries and closing comments rather than copying them wholesale. |

When a project milestone needs work, create a TODO entry and GitHub issue first,
then link the task in `_projects/<project-id>/tasks.md`. When a task completes,
update the project link state only if the project record is in scope for that
work; otherwise leave project state updates to a dedicated project-maintenance
task.

## Versioning and Sensitivity Defaults

Default policy for Phase 1:

| Path | Versioned | Default sensitivity | Notes |
|------|-----------|---------------------|-------|
| `_projects/_config/` | Yes | `internal` | Plane config and policy. |
| `_projects/active/<id>/` | Yes | `internal` | Project context and execution links. |
| `_projects/active/<id>/notes/` | No | `confidential` | Scratch notes; ignored by default. |
| `_projects/archived/<id>/` | Yes | `internal` | Completed/abandoned project record. |
| `_projects/index/` | No | `internal` | Generated search/cache data. |

Project-specific files can raise sensitivity, but tooling must never lower
sensitivity automatically. Private client, legal, credential, or personnel data
belongs in an appropriate private repo or local workspace, not in public
`_projects/` files.

## Deferred Phases

The following work is explicitly out of scope for this directory-contract phase:

- Lifecycle state transitions and status mapping to GitHub/TODO/full-loop.
- `aidevops project new|list|status|link|archive` CLI design or implementation.
- Automatic project registry updates, validators, migrations, or provisioners.
- Durable evidence-link normalisation across releases, merge summaries, and worker
  outcomes.
- Cross-plane promotion rules for `_knowledge/`, `_cases/`, `_campaigns/`,
  `_performance/`, and `_feedback/`.

<!-- AI-CONTEXT-END -->
