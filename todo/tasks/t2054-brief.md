<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Task Brief - t2054: review-followup scanner — GraphQL reviewThreads + diffHunk + refresh backfill

## Context

- **Session Origin**: Interactive (continues GH#18538, PR #18607, supersedes closed GH#18733)
- **Task ID**: t2054
- **Files**:
  - `.agents/scripts/post-merge-review-scanner.sh`
  - `.agents/scripts/tests/test-post-merge-review-scanner.sh` (new)

## Background

PR #18607 improved `post-merge-review-scanner.sh` issue bodies to include full
comment bodies, file:line refs, and a Worker Guidance section. But running the
new scanner against PR #18343 revealed two remaining problems:

1. **Spurious issues**: every CodeRabbit finding on PR #18343 was already
   marked `Addressed in commit 0d8fe9a` by CodeRabbit itself. The scanner
   currently has no way to detect resolved threads and files issues for
   findings that are already fixed. Issue #18621 (now closed) was the canonical
   example — it listed 5 findings, all of which CodeRabbit had resolved in the
   same PR before merge. A worker dispatched against it would burn tokens
   "fixing" code that is already correct.
2. **No code context**: the issue body points at `file.mjs:495` but does not
   include any of the surrounding code. Workers have to open the file and
   scroll to the target line before they can assess the finding.

Additionally: stale review-followup issues from the pre-#18607 scanner have
truncated 200-char bodies. These need a one-off backfill so workers stop
picking them up with inadequate context.

## What

1. **Rewrite `fetch_inline_comments_md()` to use GraphQL `reviewThreads`**
   instead of the REST `/comments` endpoint. GraphQL returns `isResolved` and
   `isOutdated` — canonical, bot-agnostic resolution signals that work for
   CodeRabbit, Gemini, claude-review, gpt-review, and human reviewers alike.
   Filter out threads where either flag is true.

2. **Include the tail of the `diffHunk` field** (last 12 lines by default,
   via `SCANNER_DIFFHUNK_LINES`) in each inline comment block as a ```diff
   fenced code block, so the worker sees the code context the bot was
   flagging without opening the file.

3. **Tighten `fetch_review_summaries_md()`** to skip CodeRabbit's
   `**Actionable comments posted: N**` metadata reviews. Gemini's
   `## Code Review` summary reviews are substantive findings and must be
   preserved.

4. **Add a `refresh` subcommand** that:
   - Lists open `review-followup` issues.
   - Extracts the source PR number from each issue title.
   - Recomputes the body via `build_pr_followup_body()`.
   - If the new body is non-empty, rewrites the issue body.
   - If the new body is empty (all findings resolved or outdated after
     filters), closes the issue with a comment explaining why.
   - Self-heals future regressions where the scanner's output format changes.
   - Has a `refresh-dry-run` variant that logs planned actions without executing.

5. **Add stub-based test coverage** at
   `.agents/scripts/tests/test-post-merge-review-scanner.sh` covering:
   - All-resolved threads → `build_pr_followup_body` returns exit 1.
   - All-outdated threads → `build_pr_followup_body` returns exit 1.
   - Mixed resolved/unresolved → only unresolved threads appear.
   - diffHunk tail is rendered as a ```diff fence and correctly trimmed to the
     last N lines.
   - CodeRabbit `Actionable comments posted: N` review filtered out.
   - Gemini `## Code Review` review preserved.
   - Non-bot inline comments and non-bot review summaries filtered.
   - File refs deduped across multiple threads on the same file.
   - `do_refresh` empty-list no-op, update path, close path, and malformed-title skip.

## Why

- **Spurious issues waste tokens and dispatch cycles.** The worst case was
  an issue listing 5 findings, all already resolved. Every dispatched worker
  on that issue would either time out or file a duplicate "nothing to do" PR.
- **Code context inline** eliminates one full file-read per finding, which
  is the single biggest token cost of the current workflow.
- **The `refresh` subcommand** fixes the stale backlog without manual
  close-and-recreate, and acts as a self-heal mechanism for the next time
  the output format changes.
- **GraphQL `isResolved`/`isOutdated`** is the canonical signal from GitHub.
  Per-bot markers (like CodeRabbit's `Addressed in commit X`) are brittle
  and don't cover Gemini, which never self-marks. Using GraphQL means the
  filter works uniformly across all bots now and in the future.

## How

1. In `.agents/scripts/post-merge-review-scanner.sh`:
   - Add `fetch_review_threads_json()` helper that runs `gh api graphql`
     with a parameterised query against `reviewThreads(first: 100)` on the
     PR. Both `fetch_inline_comments_md()` and `fetch_file_refs_md()` now
     source from this helper so they share the same unresolved-thread set.
   - In `fetch_inline_comments_md()`, filter threads with
     `select((.isResolved // false) == false)` and
     `select((.isOutdated // false) == false)`, then render each as a
     markdown block with author, path:line, view link, a ```diff fence with
     the tail of `diffHunk` (split on newlines, take last
     `SCANNER_DIFFHUNK_LINES` lines), and the body (2000-char cap) as a
     blockquote.
   - Drop the `ACT_RE` regex filter for inline comments (redundant: all
     unresolved review threads are findings by definition).
   - In `fetch_review_summaries_md()` add
     `select((.body // "") | test("^\\*\\*Actionable comments posted:|^Actionable comments posted:"; "i") | not)`
     before the `ACT_RE` keyword check.
   - Add `do_refresh()` function and wire `refresh` / `refresh-dry-run`
     subcommands into `main()`. The body-change detection strips the
     signature footer before comparing (the footer embeds a timestamp that
     changes every run, so it would always report "changed").
   - Replace the source guard with `(return 0 2>/dev/null) || main "$@"`
     so the test harness can source the scanner without executing `main()`.
   - Use `${BASH_SOURCE[0]:-$0}` for `SCRIPT_DIR` computation so sourcing
     from a subshell / `bash -c` under `set -u` doesn't error.

2. In `.agents/scripts/tests/test-post-merge-review-scanner.sh` (new):
   - Stub `gh` via a `PATH` override that reads canned JSON from fixture
     files (env vars `FIX_GRAPHQL`, `FIX_REVIEWS`, `FIX_COMMENTS`,
     `FIX_ISSUE_LIST`). Each test writes its own fixture before invoking
     the scanner function under test.
   - Provide `write_graphql_fixture` and `write_reviews_fixture` helpers
     that build JSON via `jq -n --argjson / --arg`.
   - Source the scanner (its source guard prevents `main` from running).
   - Cover all scenarios listed in "What / 5" above.

## Acceptance Criteria

- [ ] `build_pr_followup_body` returns exit 1 when all threads are resolved or outdated.
- [ ] `build_pr_followup_body` output contains a ```diff block with the diffHunk tail under each inline comment.
- [ ] CodeRabbit `Actionable comments posted: N` review bodies are filtered out of the output.
- [ ] Gemini `## Code Review` review bodies are preserved in the output.
- [ ] `post-merge-review-scanner.sh refresh-dry-run marcusquinn/aidevops` runs cleanly and reports planned edits/closes without errors.
- [ ] Test harness at `.agents/scripts/tests/test-post-merge-review-scanner.sh` passes (27 assertions).
- [ ] `shellcheck --rcfile=.shellcheckrc .agents/scripts/post-merge-review-scanner.sh .agents/scripts/tests/test-post-merge-review-scanner.sh` clean.
- [ ] After merge: one-off `refresh` run against `marcusquinn/aidevops` updates/closes the stale open review-followup backlog.

## Verification

```bash
# Lint
shellcheck --rcfile=.shellcheckrc .agents/scripts/post-merge-review-scanner.sh \
  .agents/scripts/tests/test-post-merge-review-scanner.sh

# Tests
bash .agents/scripts/tests/test-post-merge-review-scanner.sh

# Live smoke test against PR #18343 (all 5 CodeRabbit threads resolved — should return exit 1)
bash -c '
  source .agents/scripts/post-merge-review-scanner.sh
  build_pr_followup_body marcusquinn/aidevops 18343 && echo UNEXPECTED || echo "OK (no unresolved findings)"
'

# Dry-run refresh against aidevops
.agents/scripts/post-merge-review-scanner.sh refresh-dry-run marcusquinn/aidevops
```

## Tier

`tier:standard` — narrative brief with explicit file references, two
functions to rewrite, one new subcommand, one new test file with 27
assertions, new GraphQL integration. Not trivially copy-pasteable (Haiku),
not novel design (Opus). Sonnet.

## Notes

- Supersedes closed issue GH#18733 (same work, re-IDed from t2052 to t2054
  after discovering a pre-existing t2052 collision in TODO.md from an
  unrelated completed task on 2026-04-03).
- The pulse scanner routine (r-entry in TODO.md) already calls
  `post-merge-review-scanner.sh scan`; adding `refresh` as a scheduled call
  is deferred — the one-off post-merge refresh handles the current backlog,
  and future runs of `scan` use the new template from the start.
