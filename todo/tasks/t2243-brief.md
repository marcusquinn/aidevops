<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# t2243: parent-task-keyword-guard — strip markdown code spans before regex scan

**Session origin:** interactive (maintainer, Marcus Quinn)
**GitHub:** GH#19761
**Tier:** simple (auto-dispatch)

## What

`parent-task-keyword-guard.sh::_extract_closing_refs` (line 63) uses a plain grep regex (`_CLOSE_KEYWORD_PATTERN` at line 54) that matches `Closes|Resolves|Fixes` anywhere in the PR body — including inside markdown inline code spans (`` `Resolves #N` ``) and fenced code blocks.

GitHub's own close-on-merge parser correctly ignores code spans, so these matches are false positives: the guard rejects PRs that will not actually close their linked issue.

## Why

Hit during PR #19758 — retrospective prose line explained `"helper correctly refused \`Resolves #19734\` per t2046"`. The phrase is explanatory (inside backticks, will not auto-close on merge), but the guard's regex matched the raw text and failed CI. Fix required a prose rewrite and a second CI round-trip.

Every parent-task retrospective, post-mortem, or historical reference to closing keywords is vulnerable to this false positive.

## How

### Files to modify

- **EDIT:** `.agents/scripts/parent-task-keyword-guard.sh:54-71` (add `_strip_code_spans()`, pipe through in `_extract_closing_refs`)
- **EXTEND or NEW:** `.agents/scripts/tests/test-parent-task-keyword-guard.sh` (add fixture cases)

### Implementation

Strip fenced code blocks (` ``` ... ``` ` across lines) and inline code spans (`` `...` ``) before the keyword regex runs. Bash 3.2 compatible.

```bash
# _strip_code_spans: read stdin, strip markdown code blocks and spans, write stdout.
# Fenced blocks: awk state machine on ```  lines.
# Inline spans: sed replacement.
_strip_code_spans() {
    awk 'BEGIN{in_fence=0} /^[[:space:]]*```/{in_fence = !in_fence; next} !in_fence' |
        sed 's/`[^`]*`//g'
    return 0
}

_extract_closing_refs() {
    _strip_code_spans |
        grep -oiE "(Closes|Resolves|Fixes)[[:space:]]+(([a-zA-Z0-9_.-]+/[a-zA-Z0-9_.-]+)?#[0-9]+)" |
        grep -oE '#[0-9]+' | tr -d '#' | sort -un
    return 0
}
```

### Verification

- NEW test: body `"prose \`Resolves #123\` more prose"` → no match (PASS)
- NEW test: body with fenced block containing `Resolves #123` → no match (PASS)
- Existing test: body with plain `Resolves #123` at line start → match (keeps flagging, no regression)
- Existing test: body with `Resolves owner/repo#123` → match (keeps flagging)
- `shellcheck .agents/scripts/parent-task-keyword-guard.sh` clean

## Acceptance Criteria

- [ ] `_extract_closing_refs` ignores keywords inside inline code spans (single backticks)
- [ ] `_extract_closing_refs` ignores keywords inside fenced code blocks (triple backticks)
- [ ] Plain-text keywords still detected (no regression)
- [ ] Three new test cases (inline, fenced, regression)
- [ ] ShellCheck clean

## Context

Discovered during PR #19758 (t2228 v3.8.71 lifecycle retrospective) — bonus find #2 of 4. Low severity individually but hits every retrospective that discusses the keyword rule.
