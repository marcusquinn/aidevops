<!-- aidevops:brief-schema=v2 -->

# fix(pulse): stop footprint extraction turning EDIT/NEW prose and template placeholders into shared file claims

## Pre-flight (auto-populated by briefing workflow)

- [x] Memory recall: `footprint extract paths false overlap release intent claim-task-id interactive brief` → 0 hits — no relevant lessons
- [x] Discovery pass: `prework-discovery-helper.sh` found no open or recently merged related PR. Related history: GH#27787 (intent-aware extraction), GH#28861 (`File:` needs its colon), GH#32977 (Files Scope list items), GH#33522 (low-information root files), t18668 (defer suppression)
- [x] File refs verified at origin/main d3afddd46d: `_footprint_extract_paths` (`.agents/scripts/dispatch-dedup-footprint.sh:744`); consolidation instruction text (`.agents/scripts/pulse-triage-dispatch.sh:86`, `:103`); defer hashes built from extracted paths (`.agents/scripts/dispatch-dedup-footprint.sh:314`, `:357`)
- [x] Tier: `tier:standard` — one extraction pipeline in one dispatch-dedup module; no dispatch, claim or trust gate weakened
- [x] Seeded draft PR decision recorded: skipped — implemented interactively in the same session

## Origin

- **Created:** 2026-10-11
- **Session:** opencode:interactive
- **Created by:** ai-interactive
- **Conversation context:** Pulse throughput investigation after t18668 restored footprint defer suppression. Defer records showed unrelated issues deferring each other on paths such as `wildcard` and `regressions.`.

## What

`_footprint_extract_paths` stops reading two kinds of text as file claims:

- An `EDIT` or `NEW` marker without its colon, followed by a bare word. Without the colon, a marker now declares only a backtick- or quote-wrapped path, as in ``- NEW `tests/x.mjs` ``.
- Template placeholders: tokens containing `<`, `>`, `{` or `}`, or starting `path/to/`.

Every other declaration is extracted exactly as before, including colon declarations anywhere on a line.

## Why

- The extractor matched an `EDIT`/`NEW` marker with an optional colon anywhere in the body, so prose became a claim: "Inherited NEW wildcard lines" gave `wildcard`, "EDIT-to-NEW regressions." gave `regressions.`, "NEW JSON parts under" gave `JSON`, "EDIT only" gave `only`. Quoted examples gave `path/to/file` and `todo/<area>/log/*/*/<slug>-*.jsonl`.
- Pulse inlines the consolidation instructions (`pulse-triage-dispatch.sh:86`, `:103`) into every consolidated issue. Every consolidated issue therefore claimed `regressions.`, `path/to/file` and the `<area>` path, and one in flight deferred the others.
- Defer records on this runner (243 since 2026-08-24): 28 deferrals rested only on such tokens, and 6 more included one. 21 of the 28 are in a managed private repo. There, one in-review issue with an open PR is the recorded blocker of 6 deferrals through `wildcard`. In 4 of them `wildcard` was the candidate's only overlap with any in-flight issue; the other 2 also share real paths with other in-flight issues, because `_footprint_find_overlap` lists every overlapping path but names only the owner of the last match. At 14:35Z, 2 of the 4 live deferrals in that repo were `wildcard`-only, with about 5.5 h of their 6 h TTL left. The other 7 are in this repo (`only`, `if`, `the`, `declarations`, `(conditional)`).

## How

### Files to Modify

- `EDIT: .agents/scripts/dispatch-dedup-footprint.sh:744-777` — `_footprint_extract_paths`: a colon marker keeps its optional opening backtick or quote; a colon-less `EDIT`/`NEW` must be followed by one. A new `grep -vE` stage drops tokens with `<`, `>`, `{` or `}`, or starting `path/to/`.
- `EDIT: .agents/scripts/tests/test-dispatch-footprint-overlap.sh` — Test 6b: consolidation prose, quoted examples and placeholders yield nothing. Combined (`NEW/EDIT:`), repeated, bold, numbered, `### File:` heading, glob and colon-less backticked declarations are kept.

### Complexity Impact

- `_footprint_extract_paths`: one more pipeline stage and a longer comment. No new functions or branches.

### Complete Write Surface

- **Callers/readers:** `_footprint_check_overlap` (candidate side), `_footprint_refresh_inflight_cache` (in-flight side), `_footprint_defer_should_suppress` and `_footprint_defer_blocker_wake_reason` (defer hashes). Both overlap sides use the same parser, so the check stays symmetric.
- **Writers/mutation paths:** none new. A defer record whose candidate or blocker footprint loses a dropped token no longer matches its stored hash, so it gets the live check on the next reconsideration instead of waiting out its TTL.
- **Schemas/config:** none. `footprint_low_info_paths` and the low-information basenames are unchanged.
- **Generated/deployed mirrors:** `setup.sh` deploys `.agents/scripts/*.sh` into the runtime bundle.
- **Migrations/backfills:** none.
- **Cleanup/rollback paths:** revert the PR.

### Hazards and Compatibility

- **Missed declarations:** a colon-less marker before an unquoted path (`- NEW todo/x.md`) is no longer read; none of the 928 task briefs in this repo has one. A real path containing `<`, `>`, `{` or `}`, or starting `path/to/`, would be dropped; none exists in that corpus. A missed overlap can at worst let two workers edit one file, which merge-conflict handling covers.
- **Glob declarations:** real glob lines such as `- NEW: todo/research/log/*/*/name-*.jsonl` are kept; only `<>{}` mark a placeholder.
- **Bash 3.2:** no new constructs; the suite passes on `/bin/bash` 3.2.57.

### Verification Before Dispatch

```bash
shellcheck -x .agents/scripts/dispatch-dedup-footprint.sh .agents/scripts/tests/test-dispatch-footprint-overlap.sh
bash .agents/scripts/tests/test-dispatch-footprint-overlap.sh
/bin/bash .agents/scripts/tests/test-dispatch-footprint-overlap.sh
.agents/scripts/complexity-regression-helper.sh check --base origin/main --working-tree --metric function-complexity
```

- **Negative control:** the origin/main extractor returns the 9 real Test 6b paths plus `wildcard`, `regressions.`, `JSON`, `path/to/file`, `{path/to/new-file}` and two `<area>` paths.
- **Corpus:** over all 928 `todo/tasks/*-brief.md` files, origin/main yields 3131 brief/path pairs and the fix 3075: 56 dropped, 0 added. Every dropped token is a prose word, a placeholder or a brace-expansion prefix the old regex cut at its comma (`extraction-schemas/{invoice`).
- **Live issues:** 28 of 446 open issues in the private repo change, and 1 of 50 across 8 other managed repos. Every removed token is prose or a placeholder; nothing is added.
- **Runtime:** after deploy, `[footprint-defer] event=deferred` records should stop listing word or placeholder tokens, and the candidates they held should get a live check and dispatch or defer on real paths.
- **Broad verification trigger:** Not required — no shared config, root tooling or release infrastructure change.

### Files Scope

- `.agents/scripts/dispatch-dedup-footprint.sh`
- `.agents/scripts/tests/test-dispatch-footprint-overlap.sh`
- `TODO.md`
- `todo/tasks/t18669-brief.md`

## Acceptance Criteria

- [ ] A colon-less `EDIT`/`NEW` before a bare word produces no footprint path.
- [ ] Tokens containing `<`, `>`, `{` or `}`, or starting `path/to/`, produce no footprint path.
- [ ] Colon declarations anywhere on a line, combined, bold, numbered and heading markers, globs, line qualifiers and colon-less markers before a backticked path are extracted as before.
- [ ] Over the repo's task briefs the change only drops tokens, and every dropped token is prose or a placeholder.
- [ ] ShellCheck, the footprint suite on Bash 5 and 3.2, and the complexity gate pass.

## Context & Decisions

- **Reject junk shapes, not unanchored declarations:** a first attempt only read declarations at the start of a line. The brief corpus showed it dropped real ones (combined markers, several per line, bold, `### File:` headings, colon-less backticked paths), so the fix keeps the original match and rejects only the two observed junk shapes.
- **Keep glob paths:** declared globs are real ownership claims in repositories that log per-run files, and the overlap check compares them as exact strings.
- **Not in scope:** rewording the consolidation instructions, which are correct prose; and quoted examples with realistic paths, such as a test-fixture body cited in a brief, which remain claims as before.
