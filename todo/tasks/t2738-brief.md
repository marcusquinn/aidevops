# t2738 brief

## Session Origin

Follow-up from the t2721/t2722 auto-dispatch inventory session (parent #20402, Phase 1 PR #20415). While filing the Phase 1 child issue (#20410, t2722), the framework's create-time parent-child auto-linkage did not fire — the sub-issue graph between #20402 (parent) and #20410 (child) remained empty. Root cause: `_gh_auto_link_sub_issue` only matches dot-notation titles (`tNNN.M:`); non-dot-notation phase children are invisible to it. Backfill path (`_detect_parent_from_gh_state`) is richer but only runs periodically and silently skipped on the GraphQL rate-limit window active in that session.

Four framework gaps were identified (A/B/C/D). This task implements Gap A — the highest-leverage of the four because it closes the linkage gap for every future issue without relying on backfill recovery.

## What

Extend `_gh_auto_link_sub_issue` in `.agents/scripts/shared-gh-wrappers.sh` so it detects a `Parent: <ref>` line in the child issue body at create-time. Supports three ref forms (`#NNN`, `GH#NNN`, `tNNN`) and three markup variants (plain, bold-markdown `**Parent:**`, backtick-quoted). Mirrors method 2 of the existing backfill-time `_detect_parent_from_gh_state` so the detection shape stays consistent across create-time and backfill-time paths.

## Why

Parent-child auto-linkage has two entry points in the framework:

1. **Create-time** — `_gh_auto_link_sub_issue` (shared-gh-wrappers.sh), called by `gh_create_issue` immediately after a new issue is returned. Runs once per creation. Previously detected only dot-notation titles.
2. **Backfill-time** — `_detect_parent_from_gh_state` (issue-sync-relationships.sh), called by `backfill-sub-issues`. Runs periodically. Detects dot-notation + `Parent:` line + `Blocked by:` + parent-task label.

The create-time path is structurally narrower. Phase-style children with titles like `t2722: Phase 1 inventory` never get linked at creation. The backfill path recovers them — *unless* GraphQL budget is exhausted, in which case node-ID resolution silently fails (Gap B, separate issue). Net effect: sub-issue graph populated non-deterministically.

Adding `Parent:` line detection at create-time makes the behaviour deterministic: any brief that declares `Parent: #NNN` gets linked immediately, no backfill dependency, no rate-limit window hole.

## How

### Files Scope

- .agents/scripts/shared-gh-wrappers.sh
- .agents/scripts/tests/test-gh-auto-link-parent-line.sh
- todo/tasks/t2738-brief.md

### Design

- Refactor `_gh_auto_link_sub_issue` arg-parse loop to also capture `--body` / `--body=VAL` / `--body-file PATH` / `--body-file=PATH`. When `--body-file` is supplied, read the file (if readable) into the same `body` variable.
- Move `child_num` extraction and repo resolution above the detection branches — both methods need them.
- Restructure the body of the function:
  - Method 1 (unchanged semantics): title dot-notation (`^tNNN.M[a-z]?`) → resolve parent via `gh issue list --search`.
  - Method 2 (new): body `Parent: <ref>` line. Use the same sed pattern as `_detect_parent_from_gh_state` method 2. Resolve the ref to a parent issue number — `#NNN` / `GH#NNN` are direct, `tNNN` needs a `gh issue list --search` round-trip.
  - Both converge on a single `parent_num` variable, then the existing GraphQL node-resolve + `addSubIssue` mutation block.
- Non-blocking throughout. Any failure in detection or resolution returns 0 silently — issue creation never affected.
- Bash 3.2 compat preserved (no associative arrays, no process substitution in the new paths).

### Test Coverage

New `test-gh-auto-link-parent-line.sh` following the stub pattern from `test-backfill-sub-issues.sh`:

1. Title dot-notation fires method 1 (regression: existing behaviour).
2. Body `Parent: #500` fires method 2 with raw number.
3. Body `Parent: GH#501` fires method 2 with raw number.
4. Body `Parent: t1873` fires method 2, resolves via `gh issue list`.
5. Body `**Parent:** \`t1873\`` (bold-markdown + backtick) resolves.
6. `--body-file` with a file containing `Parent: #502` fires method 2.
7. Neither title dot-notation nor body `Parent:` line → no mutation (negative).
8. Both title dot-notation AND body `Parent:` → title wins (method 1 short-circuits method 2).

## Acceptance

- `shellcheck .agents/scripts/shared-gh-wrappers.sh` exits 0.
- `bash .agents/scripts/tests/test-gh-auto-link-parent-line.sh` exits 0 with all 8 tests passing.
- `bash .agents/scripts/tests/test-backfill-sub-issues.sh` still exits 0 (no regression to backfill path).
- Manual smoke test: create an issue with `--body "Parent: #20402"` and confirm the child appears in `gh api repos/marcusquinn/aidevops/issues/20402/sub_issues`.

## Not In Scope

- Narrative-prose detection (`Phase N of ... #NNNN`, `(child of tNNN)`, `Ref #NNNN` requiring parent-task label verification). Follow-up task — requires additional API call per creation and a false-positive mitigation design.
- REST fallback for rate-limit-exhausted node-ID resolution. Separate issue (Gap B).
- Post-merge sequential-phase filing automation. Separate issue (Gap C).
- `aidevops parent-status <N>` CLI helper for inspecting decomposition state. Separate issue (Gap D).
- Convention change to require `Parent:` lines in all phase-child briefs. This PR is necessary-but-not-sufficient for that convention — the detection must work before the convention can be relied on.

## Tier

`tier:standard` — narrative brief, ~60 LOC of bash inside one function, regression test mirrors an existing stub pattern, no novel architecture.
