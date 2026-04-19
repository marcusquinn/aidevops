# t2376: fix(biome-gate): arithmetic parse error from `grep -c || echo 0` double-output

## Origin

- **Created:** 2026-04-19
- **Session:** Claude Code interactive (session shared with t2372)
- **Created by:** marcusquinn (ai-interactive)
- **Parent task:** none
- **Conversation context:** While merging PR #19838 (t2372) the Biome CI job failed on a markdown-only change with `0\n0: syntax error in expression (error token is "0")`. Investigation showed the same bug pattern in `markdownlint-diff-helper.sh` at two sites, blocking Biome CI on every markdown-touching PR framework-wide.

## What

Fix two buggy `grep -c '^::error' 2>/dev/null || echo "0"` constructs in `.agents/scripts/markdownlint-diff-helper.sh` (lines 310 and 328 pre-fix). The `|| echo "0"` fallback appends a second "0" on no-match because `grep -c` already outputs "0" when it exits non-zero with no matches. The captured value becomes `"0\n0"`, which crashes the arithmetic `local _delta=$((_head_count - _base_count))` at line 331 with `syntax error in expression (error token is "0")`.

Replace `|| echo "0"` with `|| true` plus a default-if-empty expansion (`"${var:-0}"`). `grep -c` always produces exactly one line of output (the count) so no second source of "0" is needed; the default handles the "grep not installed" edge case which `|| echo "0"` was trying to handle.

## Why

- Framework-wide CI blocker: Biome gate fails on every markdown-touching PR (confirmed on PR #19838's `CI / biome-gate (pull_request)` job, run 71985035860). Markdown-only PRs should not be failing arithmetic in a Biome helper.
- Silent false-negative risk: the `|| true` variant after this fix means the job still exits 0 even if `grep` fails completely (e.g. missing binary), matching previous behaviour.
- Blocks the auto-merge path for all markdown-heavy changes: TODO.md updates, brief files, reference docs, etc. Every such PR requires admin-merge intervention today.

## Tier

### Tier checklist (verify before assigning)

- [x] **2 or fewer files to modify?** (1 file, 2 hunks)
- [x] **Every target file under 500 lines?** (file is 451 lines)
- [x] **Exact `oldString`/`newString` for every edit?** (yes — see below)
- [x] **No judgment or design decisions?** (bug has a single obvious fix)
- [x] **No error handling or fallback logic to design?** (preserving existing `|| true` fallback behaviour)
- [x] **No cross-package or cross-module changes?** (single helper)
- [x] **Estimate 1h or less?** (10-minute fix + test)
- [x] **4 or fewer acceptance criteria?** (3)

**Selected tier:** `tier:simple`

**Tier rationale:** Single-file, two-hunk edit with verbatim oldString/newString replacements and no judgment required. The reproducer and fix both run in 3 bash lines. No downstream API changes.

## PR Conventions

Leaf (non-parent) issue. PR body will use `Resolves #NNN`.

## How

### Files to modify

- EDIT: `.agents/scripts/markdownlint-diff-helper.sh:305-311` — base_count capture
- EDIT: `.agents/scripts/markdownlint-diff-helper.sh:323-329` — head_count capture

### Reference pattern

Existing idiomatic variant elsewhere in the codebase: `shared-constants.sh` and other helpers use `|| true` (not `|| echo "0"`) and then `"${var:-0}"` expansion when the variable feeds arithmetic. See e.g. `pulse-issue-reconcile.sh:211` and `pulse-dispatch-core.sh:760` for `_avail_kb` handling where `awk`'s guaranteed-single-line output is relied on and defaulted before use.

### Exact replacement (already applied in worktree)

#### Hunk 1 (`_base_count`)

```bash
# oldString (lines 305-311):
	if [ -n "$_base_file_list" ]; then
		local _base_output
		# shellcheck disable=SC2086
		_base_output=$(cd "$BASE_WORKTREE" && npx --yes @biomejs/biome@2.4.12 lint \
			--reporter=github --max-diagnostics=9999 $_base_file_list 2>&1) || true
		_base_count=$(printf '%s' "$_base_output" | grep -c '^::error' 2>/dev/null || echo "0")
	fi
```

```bash
# newString:
	if [ -n "$_base_file_list" ]; then
		local _base_output
		# shellcheck disable=SC2086
		_base_output=$(cd "$BASE_WORKTREE" && npx --yes @biomejs/biome@2.4.12 lint \
			--reporter=github --max-diagnostics=9999 $_base_file_list 2>&1) || true
		# t2376: use `|| true` not `|| echo "0"` — grep -c always outputs a
		# count (including "0" for no matches) and exits 1 when no matches.
		# The old `|| echo "0"` appended a second "0" on no-match, producing
		# "0\n0" which broke the arithmetic at the _delta line below.
		_base_count=$(printf '%s' "$_base_output" | grep -c '^::error' 2>/dev/null || true)
		_base_count="${_base_count:-0}"
	fi
```

#### Hunk 2 (`_head_count`)

```bash
# oldString (lines 323-329):
	if [ -n "$_head_file_list" ]; then
		local _head_output
		# shellcheck disable=SC2086
		_head_output=$(npx --yes @biomejs/biome@2.4.12 lint \
			--reporter=github --max-diagnostics=9999 $_head_file_list 2>&1) || true
		_head_count=$(printf '%s' "$_head_output" | grep -c '^::error' 2>/dev/null || echo "0")
	fi
```

```bash
# newString:
	if [ -n "$_head_file_list" ]; then
		local _head_output
		# shellcheck disable=SC2086
		_head_output=$(npx --yes @biomejs/biome@2.4.12 lint \
			--reporter=github --max-diagnostics=9999 $_head_file_list 2>&1) || true
		# t2376: see matching comment on _base_count above.
		_head_count=$(printf '%s' "$_head_output" | grep -c '^::error' 2>/dev/null || true)
		_head_count="${_head_count:-0}"
	fi
```

### Verification

#### Reproducer (shows the bug)

```bash
v=$(printf '' | grep -c '^::error' 2>/dev/null || echo "0")
printf '%s' "$v" | od -c | head -1
# output: 0000000    0  \n   0   — the "0\n0" bug
d=$((v - 0))
# error: 0\n0: syntax error in expression (error token is "0")
```

#### Post-fix behaviour

```bash
v=$(printf '' | grep -c '^::error' 2>/dev/null || true)
v="${v:-0}"
printf '%s' "$v" | od -c | head -1
# output: 0000000    0   — single "0", no newline artefact
d=$((v - 0))
# d=0 — arithmetic succeeds
```

#### Multi-match case still works

```bash
v=$(printf '::error line 1\n::error line 2\n::error line 3\nother\n' | grep -c '^::error' 2>/dev/null || true)
v="${v:-0}"
# v=3
d=$((v - 0))
# d=3
```

## Acceptance criteria

1. Both buggy `grep -c ... || echo "0"` patterns in `.agents/scripts/markdownlint-diff-helper.sh` replaced with the `|| true` + default-expansion pattern.
2. Reproducer above (empty-input bug) no longer fails.
3. Biome gate CI job passes on markdown-only PRs (verified by a markdown-only PR immediately after merge).

## Context

- Symptom observed live: PR #19838 CI job `CI / biome-gate (pull_request)` failed with `.agents/scripts/markdownlint-diff-helper.sh: line 331: 0\n0: syntax error in expression (error token is "0")`.
- Root cause already isolated and fix already applied in this worktree (`bugfix/t2376-biome-grep-c-arithmetic`).
- Not related to t2372 (stale assignment cutoff) — discovered incidentally while merging t2372's PR.
