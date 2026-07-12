#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# brief-readiness-helper.sh — Detect worker-ready issue bodies and generate
# stub briefs linking to the canonical issue (t2417, GH#20015).
#
# Historical issue bodies retain heading-based readiness. Bodies carrying the
# brief schema-v2 marker must also contain substantive write-surface, hazard,
# verification, and positive/negative acceptance evidence.
#
# This helper provides:
#   1. A readiness detector (`check`) that scores an issue body against
#      known heading sets and returns a pass/fail verdict.
#   2. A stub-brief writer (`stub`) that creates a minimal brief linking
#      to the canonical issue instead of duplicating its content.
#   3. A similarity check (`similarity`) that compares an existing brief
#      file against an issue body and reports overlap percentage.
#
# Usage:
#   brief-readiness-helper.sh check   <issue-number> <slug>
#   brief-readiness-helper.sh check   --body <body-text>
#   brief-readiness-helper.sh stub    <task-id> <issue-number> <slug> [repo-path]
#   brief-readiness-helper.sh similarity <brief-path> --body <body-text>
#   brief-readiness-helper.sh help
#
# Exit codes:
#   0 — issue body IS worker-ready (check), or operation succeeded
#   1 — issue body is NOT worker-ready (check), or error
#   2 — usage error
#
# Environment:
#   BRIEF_READINESS_THRESHOLD — override the 4-of-7 heading threshold (default: 4)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)" || exit 1

# shellcheck source=/dev/null
if [[ -f "$SCRIPT_DIR/shared-constants.sh" ]]; then
	source "$SCRIPT_DIR/shared-constants.sh"
fi

# ---------------------------------------------------------------------------
# Logging (inline fallbacks if shared-constants not sourced)
# ---------------------------------------------------------------------------
if ! command -v log_info >/dev/null 2>&1; then
	log_info()  { printf '[INFO]  %s\n' "$*" >&2; return 0; }
	log_warn()  { printf '[WARN]  %s\n' "$*" >&2; return 0; }
	log_error() { printf '[ERROR] %s\n' "$*" >&2; return 0; }
fi

# ---------------------------------------------------------------------------
# Constants — the heading sets that signal worker-readiness.
#
# Two heading families exist in the wild:
#   Primary:   ## Task, ## Why, ## How, ## Acceptance
#   Alternate: ## What, ## Session Origin, ## Files to modify, ## Worker Guidance
#
# A body scoring >= THRESHOLD across both sets is worker-ready.
# ---------------------------------------------------------------------------
readonly DEFAULT_THRESHOLD=4
readonly BRIEF_SCHEMA_V2_MARKER='<!-- aidevops:brief-schema=v2 -->'
readonly BRIEF_BOOL_TRUE="true"

# Primary headings (the brief-template canonical set)
readonly -a PRIMARY_HEADINGS=(
	"## Task"
	"## Why"
	"## How"
	"## Acceptance"
)

# Alternate headings (common in enriched issue bodies)
readonly -a ALTERNATE_HEADINGS=(
	"## What"
	"## Session Origin"
	"## Files to modify"
)

# ---------------------------------------------------------------------------
# _score_body: count how many of the known headings appear in the body.
#
# Args: body_text
# Stdout: integer score (0-7)
# Returns: 0 always
# ---------------------------------------------------------------------------
_score_body() {
	local -a _sb_args=("$@")
	local body="${_sb_args[0]}"
	local score=0

	local heading
	for heading in "${PRIMARY_HEADINGS[@]}" "${ALTERNATE_HEADINGS[@]}"; do
		if printf '%s\n' "$body" | grep -qiF "$heading"; then
			score=$((score + 1))
		fi
	done

	printf '%d\n' "$score"
	return 0
}

_is_schema_v2_brief() {
	local -a _args=("$@")
	local body="${_args[0]}"

	if printf '%s\n' "$body" | grep -qF "$BRIEF_SCHEMA_V2_MARKER"; then
		return 0
	fi
	return 1
}

_visible_brief_text() {
	local -a _args=("$@")
	local body="${_args[0]}"

	printf '%s\n' "$body" | awk '
		{
			line = $0
			while (length(line) > 0) {
				if (in_comment) {
					if (match(line, /-->/)) {
						line = substr(line, RSTART + RLENGTH)
						in_comment = 0
						continue
					}
					line = ""
					break
				}
				if (match(line, /<!--/)) {
					prefix = substr(line, 1, RSTART - 1)
					rest = substr(line, RSTART + RLENGTH)
					if (match(rest, /-->/)) {
						line = prefix substr(rest, RSTART + RLENGTH)
						continue
					}
					line = prefix
					in_comment = 1
				}
				break
			}
			if (length(line) > 0) print line
		}'
	return 0
}

_extract_markdown_section() {
	local -a _args=("$@")
	local body="${_args[0]}"
	local heading="${_args[1]}"
	local include_fenced="${_args[2]:-false}"

	printf '%s\n' "$body" | awk -v target="$heading" -v include_fenced="$include_fenced" -v true_value="$BRIEF_BOOL_TRUE" '
		BEGIN {
			target = tolower(target)
			level = (target ~ /^### /) ? 3 : 2
		}
		{
			line = tolower($0)
			heading_line = line
			sub(/[[:space:]]+$/, "", heading_line)
			trimmed = line
			sub(/^[[:space:]]*/, "", trimmed)
			marker_char = substr(trimmed, 1, 1)
			marker_len = 0
			if (marker_char == "`" || marker_char == "~") {
				while (substr(trimmed, marker_len + 1, 1) == marker_char) marker_len++
			}
			if (!in_fence && marker_len >= 3) {
				in_fence = 1
				fence_char = marker_char
				fence_len = marker_len
				next
			}
			if (in_fence && marker_char == fence_char && marker_len >= fence_len) {
				remainder = substr(trimmed, marker_len + 1)
				if (remainder ~ /^[[:space:]]*$/) {
					in_fence = 0
					next
				}
			}
			if (!in_fence && !capture && heading_line == target) {
				capture = 1
				next
			}
			if (!in_fence && capture && ((level == 3 && line ~ /^###[[:space:]]/) || line ~ /^##[[:space:]]/)) {
				exit
			}
			if (capture && (!in_fence || include_fenced == true_value)) print
		}'
	return 0
}

_brief_prose_text() {
	local -a _args=("$@")
	local body="${_args[0]}"

	printf '%s\n' "$body" | awk '
		{
			trimmed = $0
			sub(/^[[:space:]]*/, "", trimmed)
			marker_char = substr(trimmed, 1, 1)
			marker_len = 0
			if (marker_char == "`" || marker_char == "~") {
				while (substr(trimmed, marker_len + 1, 1) == marker_char) marker_len++
			}
			if (!in_fence && marker_len >= 3) {
				in_fence = 1
				fence_char = marker_char
				fence_len = marker_len
				next
			}
			if (in_fence && marker_char == fence_char && marker_len >= fence_len) {
				remainder = substr(trimmed, marker_len + 1)
				if (remainder ~ /^[[:space:]]*$/) {
					in_fence = 0
					next
				}
			}
			if (in_fence) next
			line = $0
			gsub(/`[^`]*`/, "", line)
			print line
		}'
	return 0
}

_field_line() {
	local -a _args=("$@")
	local section="${_args[0]}"
	local field="${_args[1]}"

	printf '%s\n' "$section" | grep -iF -m 1 "**${field}:**" || true
	return 0
}

_field_is_substantive() {
	local -a _args=("$@")
	local section="${_args[0]}"
	local field="${_args[1]}"
	local line=""

	line=$(_field_line "$section" "$field")
	[[ -n "$line" ]] || return 1
	if printf '%s\n' "$line" | grep -qiE ':\*\*[[:space:]]*($|TBD$|TODO$|N/?A[[:space:]]*$|unknown[[:space:]]*$|\{|<)'; then
		return 1
	fi
	[[ ${#line} -ge $((${#field} + 18)) ]] || return 1
	return 0
}

_write_surface_field_is_valid() {
	local -a _args=("$@")
	local section="${_args[0]}"
	local field="${_args[1]}"
	local line=""

	_field_is_substantive "$section" "$field" || return 1
	line=$(_field_line "$section" "$field")
	if printf '%s\n' "$line" | grep -qE "\`[^\`]+\`|(^|[[:space:]])(EDIT|NEW):"; then
		return 0
	fi
	if printf '%s\n' "$line" | grep -qiE '(N/?A|not applicable|not yet knowable|unknown).*(because|evidence|searched|documentation-only|new-file-only|until|no existing)'; then
		return 0
	fi
	return 1
}

_has_unfilled_placeholder() {
	local -a _args=("$@")
	local body="${_args[0]}"
	local prose=""

	prose=$(_brief_prose_text "$body")
	if printf '%s\n' "$prose" | grep -qiE '<[[:alpha:]][^>]*>|\{[^{}]*(command|path|purpose|criterion|rationale|summary|deliverable|problem|evidence|task|title)[^{}]*\}'; then
		return 0
	fi
	return 1
}

_has_file_target() {
	local -a _args=("$@")
	local section="${_args[0]}"

	if printf '%s\n' "$section" | grep -qE "^[[:space:]]*-[[:space:]]+[\`]?(EDIT|NEW):[[:space:]]+[\`]?[^ \`{<]+"; then
		return 0
	fi
	return 1
}

_has_implementation_step() {
	local -a _args=("$@")
	local section="${_args[0]}"

	if printf '%s\n' "$section" | grep -qE '^[[:space:]]*[0-9]+\.[[:space:]]+[^<{][^{}]{8,}'; then
		return 0
	fi
	return 1
}

_has_executable_verification() {
	local -a _args=("$@")
	local section="${_args[0]}"

	if printf '%s\n' "$section" | grep -qE '^[[:space:]]*(\$[[:space:]]*)?(bash |shellcheck |pytest( |$)|python[0-9]* |node |npm |pnpm |yarn |go test( |$)|cargo test( |$)|make |bundle exec |composer |git diff( |$)|\./|[.][[:alnum:]_/-]+\.sh([[:space:]]|$))'; then
		return 0
	fi
	return 1
}

_validate_v2_body() {
	local -a _args=("$@")
	local body="${_args[0]}"
	local visible=""
	local files_to_modify=""
	local write_surface=""
	local implementation_steps=""
	local hazards=""
	local verification=""
	local acceptance=""
	local errors=""
	local field=""
	local checkbox_count=0
	local negative_pattern='regression|never|must not|does not|do not|without|rejects?|preserves?|no [[:alnum:]]'

	visible=$(_visible_brief_text "$body")
	files_to_modify=$(_extract_markdown_section "$visible" "### Files to Modify")
	write_surface=$(_extract_markdown_section "$visible" "### Complete Write Surface")
	implementation_steps=$(_extract_markdown_section "$visible" "### Implementation Steps")
	hazards=$(_extract_markdown_section "$visible" "### Hazards and Compatibility")
	verification=$(_extract_markdown_section "$visible" "### Verification Before Dispatch" "$BRIEF_BOOL_TRUE")
	acceptance=$(_extract_markdown_section "$visible" "## Acceptance Criteria")

	_has_file_target "$files_to_modify" || errors="${errors}files-to-modify:target;"
	_has_implementation_step "$implementation_steps" || errors="${errors}implementation-steps:substantive;"

	for field in "Callers/readers" "Writers/mutation paths" "Tests/fixtures" "Schemas/config" "Generated/deployed mirrors" "Migrations/backfills" "Cleanup/rollback paths"; do
		_write_surface_field_is_valid "$write_surface" "$field" || errors="${errors}write-surface:${field};"
	done

	for field in "Concurrency/atomicity" "Migration/rollback" "Mixed-version/backward compatibility" "Idempotency/retry" "Partial failure/recovery"; do
		_field_is_substantive "$hazards" "$field" || errors="${errors}hazard:${field};"
	done

	_field_is_substantive "$verification" "Surface mapping" || errors="${errors}verification:surface-mapping;"
	_has_executable_verification "$verification" || errors="${errors}verification:command;"

	checkbox_count=$(printf '%s\n' "$acceptance" | grep -cE '^[[:space:]]*-[[:space:]]+\[[ xX]\]' || true)
	[[ "$checkbox_count" -ge 2 ]] || errors="${errors}acceptance:multiple-observable-criteria;"
	printf '%s\n' "$acceptance" | grep -qiE "$negative_pattern" || errors="${errors}acceptance:negative-regression;"
	printf '%s\n' "$acceptance" | grep -viE "$negative_pattern" | grep -qE '^[[:space:]]*-[[:space:]]+\[[ xX]\]' || errors="${errors}acceptance:positive;"
	_has_unfilled_placeholder "$visible" && errors="${errors}placeholder:unfilled;"

	if [[ -n "$errors" ]]; then
		printf 'VALIDATION_ERRORS=%s\n' "$errors"
		return 1
	fi
	printf 'VALIDATION_ERRORS=none\n'
	return 0
}

# ---------------------------------------------------------------------------
# _is_worker_ready: check whether a body meets the readiness threshold.
#
# Args: body_text [threshold]
# Returns: 0 if worker-ready, 1 if not
# ---------------------------------------------------------------------------
_is_worker_ready() {
	local -a _iwr_args=("$@")
	local body="${_iwr_args[0]}"
	local threshold="${_iwr_args[1]:-${BRIEF_READINESS_THRESHOLD:-$DEFAULT_THRESHOLD}}"

	local score
	score=$(_score_body "$body")

	[[ "$score" -ge "$threshold" ]] || return 1
	if _is_schema_v2_brief "$body"; then
		_validate_v2_body "$body" >/dev/null || return 1
	fi
	return 0
}

# ---------------------------------------------------------------------------
# _fetch_issue_body: retrieve the body text of a GitHub issue.
#
# Args: issue_number slug
# Stdout: body text
# Returns: 0 on success, 1 on failure
# ---------------------------------------------------------------------------
_fetch_issue_body() {
	local -a _fib_args=("$@")
	local issue_number="${_fib_args[0]}"
	local slug="${_fib_args[1]}"

	local body
	body=$(gh_issue_view "$issue_number" --repo "$slug" --json body --jq '.body' 2>/dev/null) || {
		log_error "Failed to fetch issue #${issue_number} from ${slug}"
		return 1
	}

	printf '%s\n' "$body"
	return 0
}

# ---------------------------------------------------------------------------
# cmd_check: score an issue body and report worker-readiness.
#
# Args: <issue-number> <slug>  OR  --body <body-text>
# Stdout: WORKER_READY=true/false, SCORE=N, THRESHOLD=N
# Exit: 0 if worker-ready, 1 if not
# ---------------------------------------------------------------------------
cmd_check() {
	local body=""
	local issue_number=""
	local slug=""
	local threshold="${BRIEF_READINESS_THRESHOLD:-$DEFAULT_THRESHOLD}"

	# Capture all args into a local array to avoid direct $1/$2 references
	local -a _args=("$@")
	local _i=0 _len="${#_args[@]}" _cur=""

	while [[ $_i -lt $_len ]]; do
		_cur="${_args[$_i]}"
		case "$_cur" in
		--body)
			_i=$((_i + 1)); body="${_args[$_i]}" ;;
		--threshold)
			_i=$((_i + 1)); threshold="${_args[$_i]}" ;;
		*)
			if [[ -z "$issue_number" ]]; then
				issue_number="$_cur"
			elif [[ -z "$slug" ]]; then
				slug="$_cur"
			else
				log_error "Unexpected argument: $_cur"
				return 2
			fi
			;;
		esac
		_i=$((_i + 1))
	done

	# Fetch body from GitHub if not provided inline
	if [[ -z "$body" ]]; then
		if [[ -z "$issue_number" || -z "$slug" ]]; then
			log_error "Usage: brief-readiness-helper.sh check <issue-number> <slug>"
			log_error "       brief-readiness-helper.sh check --body <body-text>"
			return 2
		fi
		body=$(_fetch_issue_body "$issue_number" "$slug") || return 1
	fi

	local score
	score=$(_score_body "$body")
	local ready="false"
	local exit_code=1
	local schema="legacy"
	local validation="VALIDATION_ERRORS=not-applicable"

	if _is_schema_v2_brief "$body"; then
		schema="v2"
		if [[ "$score" -ge "$threshold" ]] && validation=$(_validate_v2_body "$body"); then
			ready="$BRIEF_BOOL_TRUE"
			exit_code=0
		fi
	elif [[ "$score" -ge "$threshold" ]]; then
		ready="true"
		exit_code=0
	fi

	printf 'WORKER_READY=%s\n' "$ready"
	printf 'SCORE=%d\n' "$score"
	printf 'THRESHOLD=%d\n' "$threshold"
	printf 'SCHEMA=%s\n' "$schema"
	printf '%s\n' "$validation"

	return "$exit_code"
}

# ---------------------------------------------------------------------------
# cmd_stub: write a minimal stub brief that links to the canonical issue.
#
# Args: <task-id> <issue-number> <slug> [repo-path]
# Creates: todo/tasks/{task_id}-brief.md (stub form)
# Exit: 0 on success
# ---------------------------------------------------------------------------
cmd_stub() {
	local -a _stub_args=("$@")
	local task_id="${_stub_args[0]:-}"
	local issue_number="${_stub_args[1]:-}"
	local slug="${_stub_args[2]:-}"
	local repo_path="${_stub_args[3]:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"

	if [[ -z "$task_id" || -z "$issue_number" || -z "$slug" ]]; then
		log_error "Usage: brief-readiness-helper.sh stub <task-id> <issue-number> <slug> [repo-path]"
		return 2
	fi

	local brief_dir="$repo_path/todo/tasks"
	local brief_path="$brief_dir/${task_id}-brief.md"
	local today
	today=$(date +%Y-%m-%d)

	mkdir -p "$brief_dir"

	if [[ -f "$brief_path" ]]; then
		log_warn "Brief already exists: $brief_path — skipping stub creation"
		return 0
	fi

	# Fetch issue title for the heading
	local issue_title=""
	issue_title=$(gh_issue_view "$issue_number" --repo "$slug" --json title --jq '.title' 2>/dev/null) || true
	issue_title="${issue_title:-${task_id}}"

	cat >"$brief_path" <<EOF
# ${task_id}: ${issue_title}

## Origin

- **Created:** ${today}
- **Session:** auto-detected worker-ready issue body
- **Created by:** brief-readiness-helper (stub — canonical brief lives in issue)

## Canonical Brief

**The authoritative brief for this task is the GitHub issue body:**

https://github.com/${slug}/issues/${issue_number}

The issue body contains all required sections (Task/What, Why, How,
Acceptance, Files to modify) and is the single source of truth.
This stub exists only to satisfy the brief-file-exists gate.

## Session-Specific Context

<!-- Add any session-specific context not captured in the issue body. -->
<!-- If empty, this section can be removed. -->
EOF

	log_info "Stub brief written to $brief_path (canonical: issue #${issue_number})"
	return 0
}

# ---------------------------------------------------------------------------
# cmd_similarity: compare a brief file against an issue body.
#
# Uses a line-level overlap heuristic: count lines in the brief that also
# appear (after whitespace normalisation) in the issue body. Report the
# percentage of brief lines that overlap.
#
# Args: <brief-path> --body <body-text>
# Stdout: SIMILARITY=NN (0-100)
# Exit: 0 always
# ---------------------------------------------------------------------------
cmd_similarity() {
	# Capture all args into a local array to avoid direct positional refs
	local -a _args=("$@")
	local brief_path="${_args[0]:-}"
	local body=""
	local _i=1 _len="${#_args[@]}" _cur=""

	while [[ $_i -lt $_len ]]; do
		_cur="${_args[$_i]}"
		case "$_cur" in
		--body)
			_i=$((_i + 1)); body="${_args[$_i]}" ;;
		*)
			log_error "Unknown option: $_cur"
			return 2
			;;
		esac
		_i=$((_i + 1))
	done

	if [[ -z "$brief_path" || -z "$body" ]]; then
		log_error "Usage: brief-readiness-helper.sh similarity <brief-path> --body <body-text>"
		return 2
	fi

	if [[ ! -f "$brief_path" ]]; then
		log_error "Brief file not found: $brief_path"
		return 1
	fi

	# Normalise both texts: collapse whitespace, lowercase, strip markdown
	# formatting markers (##, **, ```, - [ ]), then compare line-by-line.
	local norm_body norm_brief
	norm_body=$(printf '%s\n' "$body" | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//; s/[[:space:]]+/ /g' | tr '[:upper:]' '[:lower:]' | grep -v '^$' || true)
	norm_brief=$(sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//; s/[[:space:]]+/ /g' "$brief_path" | tr '[:upper:]' '[:lower:]' | grep -v '^$' || true)

	local total_lines=0
	local matching_lines=0

	while IFS= read -r line; do
		# Skip very short lines (headers, blank, markers) — they match too easily
		if [[ ${#line} -lt 10 ]]; then
			continue
		fi
		total_lines=$((total_lines + 1))
		if printf '%s\n' "$norm_body" | grep -qF "$line"; then
			matching_lines=$((matching_lines + 1))
		fi
	done <<<"$norm_brief"

	local similarity=0
	if [[ "$total_lines" -gt 0 ]]; then
		similarity=$(( (matching_lines * 100) / total_lines ))
	fi

	printf 'SIMILARITY=%d\n' "$similarity"
	return 0
}

# ---------------------------------------------------------------------------
# cmd_help
# ---------------------------------------------------------------------------
cmd_help() {
	cat <<'USAGE'
brief-readiness-helper.sh — Detect worker-ready issue bodies (t2417)

Usage:
  check <issue-number> <slug>           Score an issue body for worker-readiness
  check --body <body-text>              Score inline body text
  stub  <task-id> <issue> <slug> [path] Write a stub brief linking to the issue
  similarity <brief-path> --body <text> Compare brief vs issue body overlap (%)
  help                                  Show this help

Exit codes:
  0 — worker-ready (check), or operation succeeded
  1 — not worker-ready (check), or error
  2 — usage error

Environment:
  BRIEF_READINESS_THRESHOLD  Override the 4-of-7 heading threshold (default: 4)
USAGE
	return 0
}

# ---------------------------------------------------------------------------
# Main dispatch
# ---------------------------------------------------------------------------
main() {
	local -a _main_args=("$@")
	local cmd="${_main_args[0]:-help}"

	# Remove first element to pass remaining args
	local -a _rest=("${_main_args[@]:1}")

	case "$cmd" in
	check)      cmd_check "${_rest[@]}" ;;
	stub)       cmd_stub "${_rest[@]}" ;;
	similarity) cmd_similarity "${_rest[@]}" ;;
	help|--help|-h) cmd_help ;;
	*)
		log_error "Unknown command: $cmd"
		cmd_help
		return 2
		;;
	esac
}

main "$@"
