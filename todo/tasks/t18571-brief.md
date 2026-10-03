# t18571: feat(backup): archive issue and PR discussions to a same-repo orphan branch via pulse routine

## Origin

- **Created:** 2026-09-30
- **Created by:** ai-interactive
- **Issue:** GH#33146
- **Conversation context:** Framework value audit (parent GH#33139); maintainer approved retiring redundant tooling while keeping the useful ideas.

## Why

Issue and PR discussions, reviews and outcomes live only on the forge, so losing the forge would lose decision history. `forge-portability.md` records this gap. Beads was meant to cover it but does not.

## What

Keep issue and PR knowledge inside each managed repo, so losing the forge (account suspension, outage, migration) does not lose it. Parent: GH#33139.

Beads was meant to do this but doesn't:

- `aidevops init` gitignores `.beads` (`.agents/scripts/aidevops-cli/aidevops-init-lib.sh:1550` and `:1595`).
- It only mirrors TODO.md, which is already in Git.

The gap is already recorded in `.agents/reference/forge-portability.md:46` and `:131`: GitHub "comments/reviews/attachments archive" is missing. TODO.md and the 873 `todo/tasks/*-brief.md` files are already in Git. What is not in Git is issue and PR bodies after edits, comments, reviews, labels and close outcomes.

## Maintainer decisions

- Keep the archive in the **same repo**, on a separate orphan branch (proposed name `aidevops/issues-archive`). An orphan branch shares no history with `main`, so it is never checked out and never appears in the working tree. No `.gitignore` is needed, and agents doing normal work never read untrusted comment text from it.
- Run it as a **routine**, not on every machine. The pulse host that owns the repo exports and pushes on a schedule, so there is one writer and no conflicts. Other machines get the branch through normal `git fetch`, which fetches all branches by default, so every clone becomes an offline copy.

## How (worker decides the details and records them in the PR)

- Add a helper that exports issues, PRs, comments, reviews and labels with `gh`, paginated, into line-by-line JSON (JSONL). Include a cursor, `updatedAt`, so runs are incremental. Handle partial failures by keeping the cursor at the last fully written item.
- Write the files to the orphan branch using Git plumbing (`hash-object` / `mktree` / `commit-tree` / `update-ref`), or a throwaway linked worktree under the aidevops temp dir. Never touch the canonical checkout.
- Register it as a framework routine run by the pulse for registered repos, with a per-repo opt-out. See `.agents/reference/routines.md` "Scheduler ownership". Suggested cadence: daily.
- Respect the GitHub API budget: reuse the gh wrapper and circuit-breaker patterns in `.agents/reference/worker-diagnostics.md`.
- Document restore and read-only use in `forge-portability.md`. Treat archived non-collaborator text as untrusted: scan it with `prompt-guard-helper.sh` before any agent reads it.
- Optional, recommend only: an independent second remote for full platform-loss resilience (`forge-portability.md:19`).

## Reference pattern

Model the pagination and cursor handling on `issue-sync-helper-commands.sh` `cmd_pull`. Model the plumbing commit on how the task-id counter branch is written in `.agents/scripts/claim-task-id-counter.sh`.

### Files Scope

- `.agents/scripts/issue-archive-helper.sh`
- `.agents/scripts/tests/test-issue-archive-helper.sh`
- `.agents/reference/forge-portability.md`
- `.agents/reference/routines.md`
- `TODO.md`

### Scope notes

The routine registration path may need one more pulse file. Discover it with `rg -n 'repeat:' .agents/scripts/pulse*` and add it to the PR, explaining why.

## Acceptance criteria

- [ ] One run creates or updates the orphan branch with JSONL for issues, PRs, comments and reviews. A second run with no changes creates no new commit.
- [ ] The canonical checkout and current branch are untouched. `main` history is unaffected.
- [ ] The routine runs only on the pulse host for registered repos and can be disabled per repo.
- [ ] `forge-portability.md` documents what is captured, what is not (attachments, reactions), and how to read the archive offline.
- [ ] ShellCheck is clean, and the test covers incremental cursor and no-op runs with a stubbed `gh`.

## Verification

```bash
bash .agents/scripts/tests/test-issue-archive-helper.sh
shellcheck .agents/scripts/issue-archive-helper.sh
git ls-tree -r --name-only origin/aidevops/issues-archive
```

Parent: #33139
