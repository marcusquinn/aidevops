---
mode: subagent
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->
# t2015: fix(pulse-dep-graph): parse markdown-formatted blocked-by bodies

## Origin

- **Created:** 2026-04-13
- **Session:** Claude:interactive
- **Created by:** marcusquinn (ai-interactive, triage of external bug report)
- **Parent task:** none
- **Conversation context:** External contributor @robstiles filed GH#18429 reporting that `pulse-dep-graph.sh:125`'s blocked-by regex fails to parse the markdown format (`**Blocked by:** \`t143\``) that the framework's own brief template (`templates/brief-template.md:172`) emits. In their private repo 22 of 24 blocked issues were invisible to the graph (92% miss rate). A second sub-bug drops comma-separated task IDs silently. Reviewed via `/review-issue-pr` workflow, confirmed reproducible with verified local repro, no duplicate issues, proposed fix is minimal and correct. Approved for dispatch.

## What

`pulse-dep-graph.sh:125-126` correctly parses blocked-by references in **both** formats currently in use across the codebase:

1. **Markdown format** (emitted by `brief-template.md:172`, used in every worker-created issue body): `**Blocked by:** \`t143\``, `**Blocked by:** \`t143\`, \`t200\``, `**Blocked by:** #18429`
2. **Bare TODO format** (used inline in some issue bodies): `blocked-by:t135`, `blocked-by:t135,t145`, `blocked-by:#18429,#18430`

And captures **all** task IDs / issue numbers from comma-separated lists — not just the first. After the fix, rebuilding the dep graph cache on a repo with N blocked issues must surface all N in `.repos[$slug].blocked_by`, not a subset.

## Why

The dependency graph feature (introduced in #17942/PR#17953, enhanced in #17871) exists so the pulse can reason about which tasks unblock which — enabling "blocked" → "queued" transitions when dependencies close. The current regex character class `[: ]*` on line 125 matches only `:` and space, so it cannot cross the `**` and backtick characters that sit between `by` and the task ID in the markdown format. Since the framework's own brief template emits that exact format for every issue that declares dependencies, the regex silently misses ~92% of real blocked-by data.

Impact is not theoretical: @robstiles observed 24 blocked issues in a private repo reduced to 2 entries in the graph — the dep graph feature is mostly non-functional in real use. A second sub-bug drops all but the first task ID on lines like `blocked-by:t135,t145`, risking premature unblocking (t135 closes, graph thinks issue is unblocked, t145 still open). Without the fix, the feature provides a false sense of dependency tracking.

## Tier

### Tier checklist (verify before assigning)

- [x] **2 or fewer files to modify?** — 2 files: `pulse-dep-graph.sh` (edit ~4 lines) and new test file
- [x] **Complete code blocks for every edit?** — yes, exact oldString/newString below, complete test script included
- [x] **No judgment or design decisions?** — reporter's proposed fix is correct and verified; test cases are enumerated
- [x] **No error handling or fallback logic to design?** — `|| true` already in place, preserved in fix
- [x] **Estimate 1h or less?** — 30 minutes (edit + test + verify cache rebuild)
- [x] **4 or fewer acceptance criteria?** — exactly 4 (see Acceptance Criteria section)

All checked = `tier:simple`. 

**Selected tier:** `tier:simple`

**Tier rationale:** Single-file edit + one new regression test. Verbatim fix provided by reporter, verified working locally. No judgment required — copy, paste, run the test, rebuild cache, confirm counts.

## How (Approach)

### Files to Modify

- `EDIT: .agents/scripts/pulse-dep-graph.sh:123-126` — replace single-match regex with two-step line-extraction approach that tolerates markdown and captures comma-separated IDs.
- `NEW: .agents/scripts/tests/test-pulse-dep-graph-parse.sh` — regression test covering markdown format (single ID), markdown format (comma-separated), TODO bare format (single + comma-separated), issue-number format (`#NNN`), mixed case, no-match baseline. Model on `.agents/scripts/tests/test-pulse-wrapper-schedule.sh` for harness style.

### Implementation Steps

**Step 1: Edit `.agents/scripts/pulse-dep-graph.sh:123-126`**

Replace this exact block (lines 123-126):

```bash
			# Extract blocked-by task IDs and issue numbers from body
			local blocker_tids blocker_nums
			blocker_tids=$(printf '%s' "$body" | grep -ioE '[Bb]locked[- ]by[: ]*t([0-9]+)' | grep -oE '[0-9]+' || true)
			blocker_nums=$(printf '%s' "$body" | grep -ioE '[Bb]locked[- ]by[: ]*#([0-9]+)' | grep -oE '[0-9]+' || true)
```

With this block (two-step: find blocked-by line tolerating markdown, then extract all IDs):

```bash
			# Extract blocked-by task IDs and issue numbers from body.
			# Two-step parse tolerates both the markdown format emitted by
			# brief-template.md (`**Blocked by:** ` + backtick-quoted IDs) and
			# the bare TODO.md format (`blocked-by:tNNN,tMMM`). The first step
			# locates every blocked-by line; the second step pulls every tNNN
			# and #NNN token from those lines. This captures comma-separated
			# IDs that the original single-match regex silently dropped.
			local blocker_lines blocker_tids blocker_nums
			blocker_lines=$(printf '%s' "$body" | grep -ioE '[Bb]locked[- ][Bb]y[^[:cntrl:]]*' || true)
			blocker_tids=$(printf '%s' "$blocker_lines" | grep -oE 't[0-9]+' | grep -oE '[0-9]+' || true)
			blocker_nums=$(printf '%s' "$blocker_lines" | grep -oE '#[0-9]+' | grep -oE '[0-9]+' || true)
```

**Rationale for `[^[:cntrl:]]*` over `[^\n]*`**: BSD grep on macOS does not interpret `\n` as a newline escape inside a bracket expression the way GNU grep does (cf. t1983's BSD awk compatibility bug). `[^[:cntrl:]]*` is a POSIX character class that excludes control characters including newlines, portable across BSD and GNU, and stops matching at end-of-line as intended. Verified locally:

```bash
$ printf '%s' '**Blocked by:** `t143`, `t200`' | grep -ioE '[Bb]locked[- ][Bb]y[^[:cntrl:]]*'
**Blocked by:** `t143`, `t200`
```

**Step 2: Create `.agents/scripts/tests/test-pulse-dep-graph-parse.sh`**

Complete file content (copy verbatim, then `chmod +x`):

```bash
#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# Regression test for pulse-dep-graph.sh blocked-by body-text parser.
# Exercises every format combination shipped by the framework to prevent
# format drift from silently re-breaking the dep graph (t2015 / GH#18429).
#
# Usage: bash test-pulse-dep-graph-parse.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
DEP_GRAPH="$REPO_ROOT/.agents/scripts/pulse-dep-graph.sh"

if [[ ! -f "$DEP_GRAPH" ]]; then
	echo "FAIL: cannot locate pulse-dep-graph.sh at $DEP_GRAPH" >&2
	exit 1
fi

# Replicate the parser block under test. Keep this in sync with
# pulse-dep-graph.sh lines 123-135 (the blocker extraction block).
parse_blockers() {
	local body="$1"
	local blocker_lines blocker_tids blocker_nums
	blocker_lines=$(printf '%s' "$body" | grep -ioE '[Bb]locked[- ][Bb]y[^[:cntrl:]]*' || true)
	blocker_tids=$(printf '%s' "$blocker_lines" | grep -oE 't[0-9]+' | grep -oE '[0-9]+' || true)
	blocker_nums=$(printf '%s' "$blocker_lines" | grep -oE '#[0-9]+' | grep -oE '[0-9]+' || true)
	printf 'tids=%s\nnums=%s\n' \
		"$(printf '%s' "$blocker_tids" | tr '\n' ',' | sed 's/,$//')" \
		"$(printf '%s' "$blocker_nums" | tr '\n' ',' | sed 's/,$//')"
}

assert_parse() {
	local label="$1" body="$2" want_tids="$3" want_nums="$4"
	local got
	got=$(parse_blockers "$body")
	local got_tids got_nums
	got_tids=$(printf '%s' "$got" | awk -F= '/^tids=/ {print $2}')
	got_nums=$(printf '%s' "$got" | awk -F= '/^nums=/ {print $2}')
	if [[ "$got_tids" == "$want_tids" && "$got_nums" == "$want_nums" ]]; then
		printf 'PASS: %s\n' "$label"
	else
		printf 'FAIL: %s\n  body:     %q\n  want_tids=%s got_tids=%s\n  want_nums=%s got_nums=%s\n' \
			"$label" "$body" "$want_tids" "$got_tids" "$want_nums" "$got_nums" >&2
		exit 1
	fi
}

# Markdown format (emitted by brief-template.md:172) — the 92% case
assert_parse 'markdown single tid'          '**Blocked by:** `t143`'                         '143'       ''
assert_parse 'markdown comma tids'          '**Blocked by:** `t143`, `t200`'                 '143,200'   ''
assert_parse 'markdown single issue'        '**Blocked by:** #18429'                         ''          '18429'
assert_parse 'markdown mixed tid and issue' '**Blocked by:** `t143`, #18429'                 '143'       '18429'
assert_parse 'markdown with backticks' '**Blocked by:** `t135`, `t145`, `t200`' '135,145,200' ''

# TODO.md bare format
assert_parse 'todo single tid'              'blocked-by:t135'                                '135'       ''
assert_parse 'todo comma tids'              'blocked-by:t135,t145'                           '135,145'   ''
assert_parse 'todo comma issues'            'blocked-by:#18429,#18430'                       ''          '18429,18430'

# Case variations
assert_parse 'Blocked By case'              'Blocked By: t143'                               '143'       ''
assert_parse 'BLOCKED-BY case'              'BLOCKED-BY: t200'                               '200'       ''

# No-match baselines (must produce empty strings, not match)
assert_parse 'no blocked-by'                'This task has no dependencies.'                 ''          ''
assert_parse 'task mentions t143 without keyword' 'References task t143 somewhere.'          ''          ''

# Multi-line body — blocked-by line is inside a longer body
assert_parse 'multiline body' "$(printf '## Dependencies\n\n**Blocked by:** `t143`\n\nOther text.')" '143' ''

echo
echo 'All pulse-dep-graph blocker parse tests passed.'
```

**Step 3: Verify the fix end-to-end**

```bash
# Syntax check
shellcheck .agents/scripts/pulse-dep-graph.sh
shellcheck .agents/scripts/tests/test-pulse-dep-graph-parse.sh

# Run the regression test
chmod +x .agents/scripts/tests/test-pulse-dep-graph-parse.sh
bash .agents/scripts/tests/test-pulse-dep-graph-parse.sh

# Rebuild dep graph cache and verify non-trivial blocked_by counts
rm -f ~/.aidevops/.agent-workspace/supervisor/dep-graph-cache.json
bash .agents/scripts/pulse-dep-graph.sh build
jq '.repos | to_entries[] | {repo: .key, blocked_by_count: (.value.blocked_by | length)}' \
  ~/.aidevops/.agent-workspace/supervisor/dep-graph-cache.json
# Expect: repos with known-blocked issues show non-zero counts (not just 1-2 entries across all repos)
```

### Verification

```bash
shellcheck .agents/scripts/pulse-dep-graph.sh \
  && shellcheck .agents/scripts/tests/test-pulse-dep-graph-parse.sh \
  && bash .agents/scripts/tests/test-pulse-dep-graph-parse.sh
```

## Acceptance Criteria

- [ ] `pulse-dep-graph.sh:123-135` parses both markdown (`**Blocked by:** \`t143\``) and bare TODO (`blocked-by:t135,t145`) formats without dropping task IDs.
  ```yaml
  verify:
    method: bash
    run: "bash .agents/scripts/tests/test-pulse-dep-graph-parse.sh"
  ```
- [ ] Regression test `test-pulse-dep-graph-parse.sh` exists, is executable, and covers markdown + TODO + issue-number + case + multi-line + no-match cases.
  ```yaml
  verify:
    method: bash
    run: "test -x .agents/scripts/tests/test-pulse-dep-graph-parse.sh"
  ```
- [ ] Both files pass `shellcheck` with zero violations.
  ```yaml
  verify:
    method: bash
    run: "shellcheck .agents/scripts/pulse-dep-graph.sh .agents/scripts/tests/test-pulse-dep-graph-parse.sh"
  ```
- [ ] Rebuilt dep graph cache contains non-trivial `blocked_by` entries for repos that have markdown-formatted blocked-by references in issue bodies.
  ```yaml
  verify:
    method: manual
    prompt: "Delete ~/.aidevops/.agent-workspace/supervisor/dep-graph-cache.json, run pulse-dep-graph.sh build, and confirm jq shows non-zero blocked_by counts for repos known to have blocked issues."
  ```

## Context & Decisions

- **Chose regex fix over GraphQL migration**: @robstiles's follow-up comment correctly notes that `issue-sync-helper.sh:1205` already sets native GitHub `blockedByIssues` relationships, and the dep graph could query `blockedByIssues` via GraphQL instead of parsing body text. This is strictly better long-term (format-independent, structured source). Chose the regex fix now because: (1) ships today, unblocks the 92% miss rate immediately; (2) GraphQL migration is 30-50 lines with batching for rate limits vs ~4 lines for the regex; (3) the regex path remains free at graph-build time. The GraphQL migration is a worthwhile follow-up enhancement if regex maintenance ever becomes a pain — not a prerequisite.
- **Chose `[^[:cntrl:]]*` over `[^\n]*`**: BSD grep on macOS does not interpret `\n` inside a bracket expression as a newline literal — only GNU grep does. This has bitten the framework before (t1983: BSD awk `-v pat` escaping). `[^[:cntrl:]]*` is POSIX-portable and excludes all control characters including newlines, producing the same "match to end of line" behaviour on both BSD and GNU grep.
- **Regression test is mandatory, not optional**: This bug shipped in PR#17953 because there was no parsing test. A fix without a test leaves the next format change one LLM-generated brief away from silently re-breaking the dep graph. The test enumerates every format the framework currently emits so drift is caught at CI time, not by an external contributor filing another bug.
- **Non-goals**: no GraphQL migration, no refactor of `build_dependency_graph_cache()`, no change to the cache JSON schema.

## Relevant Files

- `.agents/scripts/pulse-dep-graph.sh:123-126` — the broken regex block being replaced.
- `.agents/templates/brief-template.md:172` — upstream source of the markdown `**Blocked by:**` format. Every worker-created issue inherits this.
- `.agents/scripts/issue-sync-helper.sh:1205` — where native GraphQL `blockedByIssues` is set (context for the follow-up GraphQL option, NOT modified by this task).
- `.agents/scripts/tests/test-pulse-wrapper-schedule.sh` — reference harness style for the new regression test.

## Dependencies

- **Blocked by:** none
- **Blocks:** full dep-graph utility — while this regex is broken, all downstream consumers of `blocked_by` (blocked-status reconciliation, "ready to unblock" detection) operate on sparse data.
- **External:** none.

## Estimate Breakdown

| Phase | Time | Notes |
|-------|------|-------|
| Research/read | 5m | Re-read pulse-dep-graph.sh:100-165 context + issue body. |
| Implementation | 10m | Apply the 4-line diff + create the test file. |
| Testing | 10m | Shellcheck, run regression test, rebuild cache on a real repo, jq-check counts. |
| **Total** | **~25m** | |
