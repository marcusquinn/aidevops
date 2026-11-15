---
description: Retire a project or sub-project safely - inventory, verified archive, transfer, removal, owner-gated destruction
mode: subagent
tools:
  read: true
  write: false
  edit: false
  bash: true
  glob: true
  grep: true
  webfetch: false
  task: true
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Retire a Project

The shutdown counterpart to `workflows/public-launch-checklist.md`. Use when
retiring, decommissioning, sunsetting or archiving a project or sub-project:
its code, scheduled jobs, databases or schemas, saved credentials, and open
issues, PRs and TODO rows.

Order matters: inventory, archive, prove the archive restores, transfer what
is kept, then destroy. Never destroy anything that is not in a verified
archive.

**Owner approval gates**: steps 5–8 change or delete live state. Before each
one, show the owner exactly what will be removed and get explicit approval
for that step. Approval for one step does not cover the next.

## 1. Inventory

Read-only. Record everything in a retirement note (for example
`todo/research/retire-<project>.md`); later steps check against it.

- Code: tracked files (`git ls-files <path>`), and ignored-but-local files
  and run outputs (`git status --ignored <path>`, `fd -HI . <path>`).
- Schedulers: launchd, cron, systemd units and timers, including dangling
  symlinks into removed worktrees, plus CI schedules and hosted cron.
- Data: databases, schemas inside shared databases, buckets, queues, caches.
- Credentials: saved secret names (`aidevops secret list`), API keys, webhooks
  and OAuth apps that exist only for this project.
- Work tracking: open issues, PRs and TODO rows, and links from other repos.
- External services: hosting projects, DNS records, domains, paid plans.

## 2. Archive

- Tag the final commit (`git tag retired/<project>-<date>`) and push the tag.
- Dump each database or schema separately, with role definitions and
  per-table row counts (see "PostgreSQL example" below).
- Tarball untracked run outputs that are worth keeping.
- Write a SHA-256 manifest (`shasum -a 256`) covering every archive file.
- Upload the archive and manifest to object storage with the provider's own
  tooling. Confirm the objects with `object-storage-helper.sh object-info`
  and `list-objects` (`services/hosting/idrive-e2.md`); its `copy` and
  `download` commands are still dry-run only, so they cannot be the upload or
  restore path.

## 3. Restore check

- Download the archive from object storage, not from the local copy, and
  check it against the SHA-256 manifest.
- Restore into a scratch database on the same major version as the source
  server, then compare per-table row counts with the counts from step 2.
- Repeat this check right before each destructive step (6–8). An archive
  verified hours ago does not cover data written since.

## 4. Transfer

- Move material worth keeping (docs, data, reusable code) to its new home and
  link to it from the retirement note.
- Close or decline leftover issues, PRs and TODO rows with a short pointer to
  the retirement note or the new home. Use the GitHub wrappers in
  `workflows/git-workflow.md`.

## 5. Remove the code (owner gate)

- Stop and disable schedulers from step 1 before removing code they call.
- Remove the code in one PR through the normal full-loop
  (`workflows/git-workflow.md`), from a linked worktree. The PR body links the
  retirement note and the archive tag.

## 6. Drop a schema in a shared database (owner gate)

Applies only when the project used a schema inside a database that other
projects still use. Classify the drop with
`verify-operation-helper.sh check` and complete
`verify-operation-helper.sh verify` before running it
(`reference/high-stakes-operations.md`).

1. Read-only dependency audit: find every object outside the schema that
   depends on it (catalog dependencies, views, foreign keys, triggers,
   functions whose source names it, column types, publications, role
   settings such as `search_path`, and API layers that expose it).
2. Write the drop as one transaction that fingerprints every object outside
   the schema before and after the drop and raises an error, and so rolls
   back, on any difference.
3. Rehearse on the scratch restore with a planted dependent view: the
   transaction must roll back.
4. Run it live ending in `ROLLBACK`; then, with approval, run it again ending
   in `COMMIT`.
5. Compare row counts in the other schemas before and after, and exercise the
   remaining apps through their own code paths.

## 7. Owner-only deletions (owner gate)

Whole-project deletion in a provider dashboard (database host, hosting,
domains, paid plans) stays with the owner. Give plain-language steps: where to
click, what to type to confirm, and what the screen should show afterwards.
Confirm the restore check in step 3 is fresh first.

## 8. Credentials (owner gate)

- For each saved credential, run `aidevops secret dependents NAME`. It also
  reports matches in stale linked worktrees; narrow the evidence to the
  default branch (`git grep NAME origin/<default>`) plus config, cron and
  systemd.
- Show the owner the list of credentials with no live dependents; remove
  entries only after approval (`reference/secret-handling.md`). Revoke the
  key at the provider too, not only the local entry.

## Audit trail

Log each destructive step without credentials:
`audit-log-helper.sh log operation.verify "<what was removed>" --detail ref=<archive-tag>`
(event types are allowlisted; see the header of `scripts/audit-log-helper.sh`).
Add the archive location, manifest hash and dates to the retirement note.

## PostgreSQL example

Other engines need the same pieces: per-object dumps, a verified restore, a
dependency audit, and a transactional drop with a rollback rehearsal.

```bash
pg_dump -Fc --schema=<schema> -f <schema>.dump "$DATABASE_URL"
pg_dumpall --roles-only -f roles.sql --dbname="$DATABASE_URL"
psql "$DATABASE_URL" -Atc "select schemaname||'.'||relname, n_live_tup from pg_stat_user_tables where schemaname = '<schema>' order by 1"
pg_restore --no-owner -d "$SCRATCH_URL" <schema>.dump
```

`n_live_tup` is an estimate; for the restore comparison use exact
`count(*)` per table on both sides. Find dependents in `pg_depend` joined to
`pg_class`/`pg_proc` where the referenced object is in the schema and the
dependent object is not. Wrap `DROP SCHEMA <schema> CASCADE` between two
fingerprint queries over objects outside the schema in a `DO` block or
transaction that raises on any difference.

## Related workflows

- `workflows/public-launch-checklist.md` — the launch counterpart.
- `reference/high-stakes-operations.md` — risk tiers and verification gates.
- `reference/secret-handling.md` — credential storage and removal.
- `workflows/git-workflow.md` — worktree, PR and issue-closing rules.
