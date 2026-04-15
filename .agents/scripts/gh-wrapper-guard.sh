#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# gh-wrapper-guard.sh — static check for bare `gh issue create` / `gh pr create`
# calls in framework scripts and hooks. Enforces the "Origin labelling
# (MANDATORY)" rule in prompts/build.txt by making the rule a CI gate and
# an optional local pre-push hook instead of relying on session-prompt
# discipline.
#
# The `gh_create_issue` / `gh_create_pr` wrappers in shared-constants.sh
# apply:
#   - origin labels (session_origin_label → origin:worker / origin:interactive)
#   - auto-assignee for the current gh user (t2028)
#   - automatic sub-issue linking (_gh_auto_link_sub_issue, GH#18735)
#   - auto-creation of origin labels on the target repo (cached per-process)
#
# Calling bare `gh issue create` / `gh pr create` skips all of that, producing
# unlabelled / unassigned / unlinked issues and PRs. This is the root cause
# of t2112 (pulse backfill pass) — this script prevents the class of bug at
# the source.
#
# Subcommands:
#   check [--base REF]  — PR/CI mode. Scans added lines in the diff between
#                         the base ref and HEAD. Default base: origin/main.
#                         Also accepts --head HEAD_REF explicitly.
#   check-staged        — Local pre-commit mode. Scans currently-staged changes.
#   check-full          — One-shot audit of the whole tree under
#                         .agents/scripts/ and .agents/hooks/. Use for
#                         migration sweeps.
#
# Rules:
#   - Scans only `.agents/scripts/**.sh` and `.agents/hooks/**.sh` files.
#   - Matches lines containing a command substring of `gh issue create` or
#     `gh pr create` where the character immediately before `gh` is not a
#     word character (so `gh_create_issue` is NOT flagged).
#   - File-level exclusions: shared-constants.sh (definition site),
#     github-cli-helper.sh (canonical wrapper support), anything under
#     .agents/scripts/tests/ (test fixtures may legitimately stub gh).
#   - Line-level allowlist: any line ending in the marker
#     `# aidevops-allow: raw-gh-wrapper` is accepted.
#
# Exit codes:
#   0 — clean (no violations, or only allowlisted/excluded hits)
#   1 — violations found; helper prints `file:line: <line>` per violation
#       plus a link to the wrapper rule.
#   2 — usage error (unknown subcommand, bad flag, git failure).

set -u

readonly RULE_LINK='prompts/build.txt → "Origin labelling (MANDATORY)"'
readonly ALLOWLIST_MARKER='# aidevops-allow: raw-gh-wrapper'
# The leader character before `gh` must be one of:
#   - whitespace (indented command line)
#   - `(` or `$(` (command substitution / subshell / array element)
#   - `=` (command substitution assignment: `x=$(gh ...)` or `arr=(gh ...)`)
#   - `&`, `|`, `;` (command separators / pipelines)
# This excludes string-literal contexts (preceded by `"`, `'`, `` ` ``, `:`)
# and raw start-of-line (heredoc mentorship text). Real command calls
# virtually always have leading whitespace in shell scripts; the rare col-0
# case can use the allowlist marker.
readonly FORBIDDEN_REGEX='([[:space:]]|[(=&|;])gh[[:space:]]+(issue|pr)[[:space:]]+create\b'

# File-level exclusions (path suffix match — `git diff --name-only` returns
# repo-relative paths so both the bare suffix and `*/suffix` forms are tried).
_is_excluded_file() {
	local f="$1"
	case "$f" in
	.agents/scripts/shared-constants.sh) return 0 ;;
	*/.agents/scripts/shared-constants.sh) return 0 ;;
	.agents/scripts/github-cli-helper.sh) return 0 ;;
	*/.agents/scripts/github-cli-helper.sh) return 0 ;;
	.agents/scripts/tests/*) return 0 ;;
	*/.agents/scripts/tests/*) return 0 ;;
	.agents/scripts/gh-wrapper-guard.sh) return 0 ;;
	*/.agents/scripts/gh-wrapper-guard.sh) return 0 ;;
	.agents/hooks/gh-wrapper-guard-pre-push.sh) return 0 ;;
	*/.agents/hooks/gh-wrapper-guard-pre-push.sh) return 0 ;;
	esac
	return 1
}

_usage() {
	cat <<EOF
gh-wrapper-guard.sh — enforce gh_create_issue / gh_create_pr wrapper usage.

Usage:
  gh-wrapper-guard.sh check [--base REF] [--head REF]
  gh-wrapper-guard.sh check-staged
  gh-wrapper-guard.sh check-full [--root PATH]

Exit codes:
  0 — clean
  1 — violations found
  2 — usage/git error

Rule: ${RULE_LINK}
Allowlist: append '${ALLOWLIST_MARKER}' to a line to accept it.
EOF
}

# Check if a line is allowlisted — the marker must appear as an end-of-line
# comment on the same line as the forbidden call. "End-of-line" means every
# character after the marker is whitespace; unrelated content after the
# marker would let an early inline fragment suppress a live call on the
# same logical line.
_is_allowlisted_line() {
	local line="$1"
	case "$line" in
	*"$ALLOWLIST_MARKER"*) ;;
	*) return 1 ;;
	esac
	# Strip everything up to and including the first occurrence of the
	# marker; reject the line unless what remains is only whitespace.
	local tail="${line#*"$ALLOWLIST_MARKER"}"
	local stripped="${tail//[[:space:]]/}"
	[[ -z "$stripped" ]]
}

# Check if a line matches the forbidden pattern (uses grep -E for portability).
_line_is_violation() {
	local line="$1"
	# Strip leading `+` from diff context if present (caller passes both diff
	# hunks and raw lines).
	line="${line#+}"
	# Skip comment lines — a `# gh issue create` in a comment is not a call.
	local trimmed="${line#"${line%%[![:space:]]*}"}"
	case "$trimmed" in
	\#*) return 1 ;;
	esac
	printf '%s' "$line" | grep -Eq "$FORBIDDEN_REGEX"
}

# Report a violation — path, optional line number, and offending line text.
_report_violation() {
	local path="$1" lineno="$2" line="$3"
	if [[ -n "$lineno" ]]; then
		printf '%s:%s: %s\n' "$path" "$lineno" "${line#+}"
	else
		printf '%s: %s\n' "$path" "${line#+}"
	fi
}

# check subcommand: scan added lines in a diff range.
# Extracts `+` hunk lines per file via `git diff -U0` and flags violations
# that aren't already allowlisted.
cmd_check() {
	local base="origin/main" head="HEAD"
	while [[ $# -gt 0 ]]; do
		case "$1" in
		--base)
			base="$2"
			shift 2
			;;
		--base=*)
			base="${1#--base=}"
			shift
			;;
		--head)
			head="$2"
			shift 2
			;;
		--head=*)
			head="${1#--head=}"
			shift
			;;
		*)
			printf 'gh-wrapper-guard: unknown flag: %s\n' "$1" >&2
			_usage >&2
			return 2
			;;
		esac
	done

	# List candidate files touched in the range.
	local files
	files=$(git diff --name-only "${base}...${head}" -- \
		'.agents/scripts/*.sh' '.agents/hooks/*.sh' 2>/dev/null) || {
		printf 'gh-wrapper-guard: git diff failed for %s...%s\n' "$base" "$head" >&2
		return 2
	}
	[[ -z "$files" ]] && return 0

	local total_violations=0
	local file
	while IFS= read -r file; do
		[[ -z "$file" ]] && continue
		_is_excluded_file "$file" && continue

		# Scan the diff hunks for added lines in this file. `git diff -U0`
		# emits hunks with `@@` headers and `+` prefixes on new lines.
		local hunk_state="" current_lineno=0
		while IFS= read -r line; do
			# Parse the hunk header to reset the line counter.
			if [[ "$line" == @@* ]]; then
				# Format: @@ -A,B +C,D @@ ... — we want C.
				local head_part="${line#*+}"
				current_lineno="${head_part%%,*}"
				current_lineno="${current_lineno%% *}"
				hunk_state="in-hunk"
				continue
			fi
			[[ "$hunk_state" != "in-hunk" ]] && continue
			# Only scan added lines (start with +, not ++ which is file header).
			case "$line" in
			+++*) continue ;;
			-*) continue ;;
			\ *) # context line — only exists if -U was not 0; advance anyway
				current_lineno=$((current_lineno + 1))
				continue
				;;
			+*)
				local raw="${line#+}"
				if _line_is_violation "$line" && ! _is_allowlisted_line "$raw"; then
					_report_violation "$file" "$current_lineno" "$raw"
					total_violations=$((total_violations + 1))
				fi
				current_lineno=$((current_lineno + 1))
				;;
			esac
		done < <(git diff -U0 "${base}...${head}" -- "$file" 2>/dev/null || true)
	done <<<"$files"

	if [[ "$total_violations" -gt 0 ]]; then
		printf '\n'
		printf '%s violation(s) found — use gh_create_issue / gh_create_pr\n' "$total_violations" >&2
		printf 'Rule: %s\n' "$RULE_LINK" >&2
		printf 'Allowlist: append "%s" to the line for an audited exception.\n' "$ALLOWLIST_MARKER" >&2
		return 1
	fi
	return 0
}

# check-staged: scan the currently-staged working-tree changes.
cmd_check_staged() {
	local files
	files=$(git diff --cached --name-only -- \
		'.agents/scripts/*.sh' '.agents/hooks/*.sh' 2>/dev/null) || return 2
	[[ -z "$files" ]] && return 0

	local total=0
	local file
	while IFS= read -r file; do
		[[ -z "$file" ]] && continue
		_is_excluded_file "$file" && continue
		local hunk_state="" current_lineno=0
		while IFS= read -r line; do
			if [[ "$line" == @@* ]]; then
				local head_part="${line#*+}"
				current_lineno="${head_part%%,*}"
				current_lineno="${current_lineno%% *}"
				hunk_state="in-hunk"
				continue
			fi
			[[ "$hunk_state" != "in-hunk" ]] && continue
			case "$line" in
			+++*) continue ;;
			-*) continue ;;
			+*)
				local raw="${line#+}"
				if _line_is_violation "$line" && ! _is_allowlisted_line "$raw"; then
					_report_violation "$file" "$current_lineno" "$raw"
					total=$((total + 1))
				fi
				current_lineno=$((current_lineno + 1))
				;;
			esac
		done < <(git diff --cached -U0 -- "$file" 2>/dev/null || true)
	done <<<"$files"

	if [[ "$total" -gt 0 ]]; then
		printf '\n%s staged violation(s). Rule: %s\n' "$total" "$RULE_LINK" >&2
		return 1
	fi
	return 0
}

# check-full: grep the whole tree under .agents/scripts and .agents/hooks.
# Used for baseline audits and migration sweeps.
cmd_check_full() {
	local root="."
	while [[ $# -gt 0 ]]; do
		case "$1" in
		--root)
			root="$2"
			shift 2
			;;
		--root=*)
			root="${1#--root=}"
			shift
			;;
		*)
			printf 'gh-wrapper-guard: unknown flag: %s\n' "$1" >&2
			return 2
			;;
		esac
	done

	local total=0
	local path
	while IFS= read -r path; do
		[[ -z "$path" ]] && continue
		_is_excluded_file "$path" && continue
		local lineno content
		while IFS=: read -r lineno content; do
			[[ -z "$lineno" ]] && continue
			_is_allowlisted_line "$content" && continue
			# Skip comment lines (leading '#' after optional whitespace).
			local trimmed="${content#"${content%%[![:space:]]*}"}"
			case "$trimmed" in
			\#*) continue ;;
			esac
			_report_violation "$path" "$lineno" "$content"
			total=$((total + 1))
		done < <(grep -nE "$FORBIDDEN_REGEX" "$path" 2>/dev/null || true)
	done < <(find "$root/.agents/scripts" "$root/.agents/hooks" \
		-type f -name '*.sh' 2>/dev/null | sort || true)

	if [[ "$total" -gt 0 ]]; then
		printf '\n%s total violation(s) in-tree. Rule: %s\n' "$total" "$RULE_LINK" >&2
		return 1
	fi
	return 0
}

main() {
	local cmd="${1:-}"
	[[ -n "$cmd" ]] && shift
	case "$cmd" in
	check) cmd_check "$@" ;;
	check-staged) cmd_check_staged "$@" ;;
	check-full) cmd_check_full "$@" ;;
	-h | --help | help | '')
		_usage
		return 0
		;;
	*)
		printf 'gh-wrapper-guard: unknown subcommand: %s\n' "$cmd" >&2
		_usage >&2
		return 2
		;;
	esac
}

main "$@"
