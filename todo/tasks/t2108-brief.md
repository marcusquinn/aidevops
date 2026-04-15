<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# t2108 — pulse-merge title fallback closes leaf issues despite `For #NNN`

**Issue:** GH#19051
**Tier:** `tier:simple` (Haiku)
**Origin:** interactive (Marcus, 2026-04-15, post-t2099 session)
**Estimate:** 30 min

## What

Make `_extract_linked_issue` in `.agents/scripts/pulse-merge.sh` body-keyword authoritative. The PR-title fallback (`GH#NNN: description`) must only return an issue number if the PR body **also** contains a closing keyword (`Closes`, `Closed`, `Fixes`, `Fixed`, `Resolves`, `Resolved`, case-insensitive, followed by `#NNN` referencing the same issue). The body keyword is the source of truth; the title is a tie-breaker for *which* of multiple body-matched issues is the primary one — never an override that creates a match where the body has none.

This is a regression closure — a 4-line behavioural change in a single function plus a 4-scenario test. The t2099 fix (parent-task label guard) covered parent issues; this fix covers the leaf-issue half of the same root cause.

## Why

Discovered live on 2026-04-15 across **three** consecutive sessions in a single evening:

| Session | PR | Issue closed prematurely | Recovery |
|---------|-----|--------------------------|----------|
| t2053.1 | #19028 (parent-task) | #18735 (parent roadmap) | Manual reopen + filed t2099 |
| t2099 | #19034 (the leaf-issue regression test wasn't enough) | — (covered) | — |
| t2105 planning | #19043 (planning-only brief PR) | #19042 (leaf bug) | Manual reopen + this brief |

The pattern: every PR in this repo follows the canonical title format `tNNN: description` or `GH#NNN: description` (per `.agents/AGENTS.md` "Git Workflow"). For PRs targeting an issue, the `GH#NNN:` form is dominant. `_extract_linked_issue` parses that title prefix as a fallback when the body has no closing keyword:

```bash
# pulse-merge.sh:984-991 (current behaviour)
# Match: GH#NNN prefix in PR title only (format: "GH#NNN: description").
issue_num=$(printf '%s' "$pr_title" | grep -oE 'GH#[0-9]+' | head -1 | grep -oE '[0-9]+')
if [[ -n "$issue_num" ]]; then
    printf '%s' "$issue_num"
    return 0
fi
```

Then `_handle_post_merge_actions` calls `gh issue close "$linked_issue"` unconditionally (modulo the t2099 `parent-task` label guard). The body keyword check that the PR author *wanted* to honour is silently overridden by the title fallback.

The t2046 parent-task-keyword-guard prevents `Closes/Resolves/Fixes` from appearing in the PR body for parent-task issues. The t2099 label guard prevents the close call for parent-task issues at the merge end. Neither covers the case where:

1. The PR is a planning-only brief, multi-PR roadmap, or other "ship something against an issue without closing it"
2. The body intentionally uses `For #NNN` or `Ref #NNN` to avoid auto-close
3. The title still contains `GH#NNN:` because the title format is the canonical convention

That case currently breaks. The brief PR for t2105 (#19043) hit this exact pattern 14 minutes after t2099 (#19034) merged — same evening, same maintainer, same failure mode. The lesson is that the bug class is general, not parent-specific.

## How

### File 1: `.agents/scripts/pulse-merge.sh` — make body keyword authoritative

Find the existing function `_extract_linked_issue` at **line 967**. The current body looks like (verbatim from line 967-994):

```bash
_extract_linked_issue() {
	local pr_number="$1"
	local repo_slug="$2"
	local pr_title pr_body
	pr_title=$(gh pr view "$pr_number" --repo "$repo_slug" --json title --jq '.title // empty' 2>/dev/null) || pr_title=""
	pr_body=$(gh pr view "$pr_number" --repo "$repo_slug" --json body --jq '.body // empty' 2>/dev/null) || pr_body=""

	# Match GitHub-native close keywords in the PR body only (case-insensitive).
	# Matches: close/closes/closed, fix/fixes/fixed, resolve/resolves/resolved.
	# Does NOT match bare GH#NNN, "Related #NNN", or other non-closing references. (GH#18098)
	local issue_num
	issue_num=$(printf '%s' "$pr_body" | grep -ioE '(close[ds]?|fix(es|ed)?|resolve[ds]?)\s+#[0-9]+' | head -1 | grep -oE '[0-9]+')
	if [[ -n "$issue_num" ]]; then
		printf '%s' "$issue_num"
		return 0
	fi

	# Match: GH#NNN prefix in PR title only (format: "GH#NNN: description").
	# Title-scoped: bare GH#NNN references anywhere in the PR body are intentionally
	# excluded to avoid closing unrelated issues mentioned in "Related" sections. (GH#18098)
	issue_num=$(printf '%s' "$pr_title" | grep -oE 'GH#[0-9]+' | head -1 | grep -oE '[0-9]+')
	if [[ -n "$issue_num" ]]; then
		printf '%s' "$issue_num"
		return 0
	fi

	return 0
}
```

**Replace the entire function body** with:

```bash
_extract_linked_issue() {
	local pr_number="$1"
	local repo_slug="$2"
	local pr_title pr_body
	pr_title=$(gh pr view "$pr_number" --repo "$repo_slug" --json title --jq '.title // empty' 2>/dev/null) || pr_title=""
	pr_body=$(gh pr view "$pr_number" --repo "$repo_slug" --json body --jq '.body // empty' 2>/dev/null) || pr_body=""

	# Match GitHub-native close keywords in the PR body only (case-insensitive).
	# Matches: close/closes/closed, fix/fixes/fixed, resolve/resolves/resolved.
	# Does NOT match bare GH#NNN, "Related #NNN", "For #NNN", "Ref #NNN", or other
	# non-closing references. (GH#18098 + t2108)
	#
	# The body keyword is AUTHORITATIVE. The title fallback below only fires when
	# the body has a closing keyword AND the title also names a number — it picks
	# WHICH issue from the body matches when there are multiple. It is NEVER an
	# override that creates a match where the body intentionally has none. (t2108)
	local body_issue title_issue
	body_issue=$(printf '%s' "$pr_body" | grep -ioE '(close[ds]?|fix(es|ed)?|resolve[ds]?)\s+#[0-9]+' | head -1 | grep -oE '[0-9]+')
	title_issue=$(printf '%s' "$pr_title" | grep -oE 'GH#[0-9]+' | head -1 | grep -oE '[0-9]+')

	# No closing keyword in the body → return empty. The PR is intentionally
	# not closing any issue (planning-only PR, multi-PR roadmap, "For #NNN"
	# reference, etc.). _handle_post_merge_actions will skip the close path
	# when this returns empty. (t2108)
	if [[ -z "$body_issue" ]]; then
		return 0
	fi

	# Body has a closing keyword. If the title also names a number, prefer the
	# title-named issue when it differs from body_issue (matches the historical
	# behaviour where the GH#NNN: title prefix is the primary identifier and
	# the body may reference additional issues). When they match or the title
	# has no number, return body_issue. (t2108)
	if [[ -n "$title_issue" ]]; then
		printf '%s' "$title_issue"
		return 0
	fi
	printf '%s' "$body_issue"
	return 0
}
```

The behavioural change in one sentence: **the body must contain a closing keyword for `_extract_linked_issue` to return any issue number.** If the body has no closing keyword, the function returns empty regardless of what's in the title, which causes `_handle_post_merge_actions` to skip the entire close path (the existing `if [[ -n "$linked_issue" ]]` guard handles this).

### File 2: `.agents/scripts/tests/test-pulse-merge-extract-linked-issue.sh` — new test (4 scenarios)

Create a new test file that extracts `_extract_linked_issue` from `pulse-merge.sh` via `awk`/`eval` (same pattern as the existing `test-pulse-merge-parent-task-close-guard.sh` and `test-pulse-merge-rebase-nudge.sh`). Mock `gh pr view` to return canned title + body fixtures and assert the four scenarios below.

**Reference test pattern**: `.agents/scripts/tests/test-pulse-merge-parent-task-close-guard.sh` (created in t2099 / PR #19034). Copy its structure: setup_test_env / teardown_test_env / define_function_under_test / four assertions / main loop. The mock-gh stub there is directly applicable — just change which JSON keys it serves.

**Four scenarios (all must pass):**

| # | PR title | PR body | Expected return |
|---|----------|---------|-----------------|
| 1 | `GH#19042: plan t2105` | `For #19042\n\nNo closing keyword.` | empty (regression guard for the t2105 incident) |
| 2 | `GH#19042: fix bug` | `Resolves #19042\n` | `19042` (normal leaf close path still works) |
| 3 | `GH#19042: cross-issue` | `Closes #99999\n\nAlso references #19042.` | `19042` (title disambiguates when body has multiple closing keywords; matches historical behaviour) |
| 4 | `t2108: planning brief` | `Ref #19051\n` | empty (no GH#NNN in title AND no closing keyword in body — both gates fail) |

Scenario 1 is the regression guard. Scenarios 2 and 3 are existing-behaviour preservation. Scenario 4 covers the `tNNN:` title format that this very PR uses (and which doesn't trigger the title regex anyway).

### Verification

Run from the worktree, in this exact order:

```bash
# 1. ShellCheck the modified file
shellcheck .agents/scripts/pulse-merge.sh

# 2. Run the new test
bash .agents/scripts/tests/test-pulse-merge-extract-linked-issue.sh
# Expected: "Ran 4 tests, 0 failed."

# 3. Run the t2099 parent-task close guard test to confirm no regression there
bash .agents/scripts/tests/test-pulse-merge-parent-task-close-guard.sh
# Expected: "Ran 7 tests, 0 failed."

# 4. Sanity check: confirm _extract_linked_issue still extracts via awk/eval
awk '/^_extract_linked_issue\(\) \{/,/^}$/ { print }' .agents/scripts/pulse-merge.sh | grep -c "body_issue"
# Expected: at least 3 (declaration, assignment, conditional)
```

## Acceptance criteria

1. `_extract_linked_issue` returns empty when the PR body contains no closing keyword, regardless of the title (scenario 1).
2. `_extract_linked_issue` still returns the title-matched issue when the body has at least one closing keyword (scenarios 2, 3) — no regression on the existing leaf-issue close path.
3. New test file `tests/test-pulse-merge-extract-linked-issue.sh` exists, is executable, and all 4 assertions pass.
4. Existing `tests/test-pulse-merge-parent-task-close-guard.sh` still passes all 7 assertions (no regression in the t2099 parent-task path, which is independent and operates at the close-call layer).
5. `shellcheck` clean on `.agents/scripts/pulse-merge.sh` and the new test file.

## Out of scope

- **Removing the t2099 parent-task label guard.** It's defense in depth — even after this fix, a PR body with `Closes #parent-task-issue` would still try to close the parent if the keyword guard at PR creation time was bypassed. Both layers stay.
- **Changing PR title conventions.** The `GH#NNN:` title format is canonical and stays. This fix is about how `pulse-merge.sh` *interprets* that title, not about changing what authors write.
- **Refactoring `_handle_post_merge_actions`.** It already short-circuits on empty `linked_issue`; no changes needed there.
- **Updating documentation.** `prompts/build.txt` and `AGENTS.md` already say "the body keyword is the source of truth" implicitly — the fix makes the code match the existing intent.

## PR conventions

This PR closes a leaf bug, so the PR body MUST use `Resolves #19051`. **Use the `tNNN:` title format**, not `GH#NNN:`, to avoid the very bug being fixed during this fix's own merge:

```text
Title: t2108: fix(pulse-merge) make body keyword authoritative for linked issue extraction
Body:  Resolves #19051
```

(After this PR merges, future PRs targeting leaf issues can safely use `GH#NNN:` titles again.)

## Tier checklist (tier:simple)

- [x] ≤2 files modified (`pulse-merge.sh` + 1 new test file)
- [x] Verbatim code blocks for both files
- [x] No skeleton — every line is copy-pasteable
- [x] Test scenarios defined as a 4-row table with exact expected outputs
- [x] Estimate ≤1h (30 min)
- [x] 5 acceptance criteria (right at the limit; the 5th is a regression guard, not new behaviour)
- [x] No judgment keywords (no "consider", "decide", "evaluate")
- [x] Reference pattern explicitly named (`test-pulse-merge-parent-task-close-guard.sh` from t2099)

## Related

- **Root cause discovered in:** t2053.1 (PR #19028) → exposed parent-task case → fixed by t2099 (PR #19034)
- **Generalised in:** t2105 planning (PR #19043) → exposed leaf-issue case → this brief
- **Adjacent fix this complements:** t2099 / `_handle_post_merge_actions` parent-task label guard at line ~828 of `pulse-merge.sh`
- **PR title convention:** `.agents/AGENTS.md` Git Workflow section
- **Body keyword convention:** `.agents/templates/brief-template.md` "PR Conventions"
- **Related historical fix:** GH#18098 (the original fix that scoped title matching to `GH#NNN` only and excluded bare body references) — this PR is its second-order correction
