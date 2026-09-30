#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# Pre-commit hook for multi-platform quality validation
# Install with: cp .agents/scripts/pre-commit-hook.sh .git/hooks/pre-commit && chmod +x .git/hooks/pre-commit

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
# shellcheck disable=SC1091  # shared-constants.sh is deployed alongside at runtime
source "${SCRIPT_DIR}/shared-constants.sh"

set -euo pipefail

# Color codes for output

# --- Ratchet helpers (t2230) --------------------------------------------------
# Quality validators compare the staged file's violation count against its HEAD
# count and only block on INCREASE. This mirrors the pattern used by
# qlty-regression-helper.sh (t2065) and qlty-new-file-gate-helper.sh (t2068):
# blocks new debt without trapping authors on pre-existing legacy violations.
#
# SECURITY EXCEPTION: check_secrets remains absolute-count — a newly introduced
# hardcoded credential is a CVE-class event regardless of pre-existing state.
# Per AGENTS.md "Gate design — ratchet, not absolute (t2228 class)":
# "security/credentials checks are absolute — a new violation is P1 regardless."

# Staged-diff wrapper. AIDEVOPS_PRE_COMMIT_BASE (optional) overrides the
# comparison base, so a temporary index built from a commit other than HEAD
# (planning publisher) only validates what it changed relative to that base.
staged_diff() {
	if [[ -n "${AIDEVOPS_PRE_COMMIT_BASE:-}" ]]; then
		git diff --cached "$AIDEVOPS_PRE_COMMIT_BASE" "$@"
	else
		git diff --cached "$@"
	fi
	return $?
}

# Return file content at HEAD for a given path. Prints empty output for new
# files or when HEAD does not yet exist (first commit). Always exits 0 so the
# callers can `head_content=$(_get_head_content "$file")` without tripping
# `set -e`.
_get_head_content() {
	local _file="$1"
	git show "${AIDEVOPS_PRE_COMMIT_BASE:-HEAD}:$_file" 2>/dev/null || true
	return 0
}

# Materialize HEAD content of a file into a temp file with the same basename
# (so shellcheck can pick up shebang + extension cues). Prints the temp path
# on stdout; caller is responsible for removing the containing directory.
# Returns 1 with empty stdout when there is no HEAD version (new file).
_make_head_temp() {
	local _file="$1"
	local _head_content
	_head_content=$(_get_head_content "$_file")
	if [[ -z "$_head_content" ]]; then
		return 1
	fi
	local _tmpdir _tmpfile _base
	_tmpdir=$(mktemp -d) || return 1
	_base=$(basename "$_file")
	_tmpfile="$_tmpdir/$_base"
	printf '%s\n' "$_head_content" >"$_tmpfile"
	printf '%s\n' "$_tmpfile"
	return 0
}

# Get list of modified shell files
get_modified_shell_files() {
	staged_diff --name-only --diff-filter=ACM | grep '\.sh$' || true
	return 0
}

# Validate that this commit does not INTRODUCE new duplicate task IDs in TODO.md.
#
# Design (t2209):
#   1. Task IDs are extracted only from real task-list entries — lines that
#      start (after optional leading whitespace) with "- [ ] tNNN",
#      "- [x] tNNN", or "- [-] tNNN" (declined). Routine IDs (rNNN) under
#      ## Routines are also matched. This excludes doc examples
#      ("- `t001` - Top-level task") and prose mentions that embed
#      "- [ ] tNNN" inside backticks or parentheses.
#      Subtask IDs like t123.1.2 are captured by (\.[0-9]+)*.
#   2. The check is DIFF-AWARE. TODO.md on main has historical duplicate
#      IDs (e.g. t131 and t1056 were both claimed twice under old
#      workflows). Those cannot be renamed without breaking issue and PR
#      back-references. We compare staged-state duplicates against
#      HEAD-state duplicates and only fail on IDs that are NEW duplicates
#      introduced by the current commit.
#
# Behaviour:
#   - Historical duplicate present in HEAD, still present in staged → pass.
#   - New task-list entry whose ID already appears elsewhere → fail.
#   - Two new task-list entries with the same ID in one commit → fail.
#   - TODO.md doesn't exist in HEAD (first commit) → any duplicate fails.
validate_duplicate_task_ids() {
	# Only check if TODO.md is staged
	if ! staged_diff --name-only | grep -q '^TODO\.md$'; then
		return 0
	fi

	local staged_todo
	staged_todo=$(git show :TODO.md 2>/dev/null || true)
	if [[ -z "$staged_todo" ]]; then
		return 0
	fi

	local head_todo
	head_todo=$(git show HEAD:TODO.md 2>/dev/null || true)

	local staged_dupes head_dupes new_dupes
	staged_dupes=$(printf '%s\n' "$staged_todo" \
		| sed -nE 's/^[[:space:]]*- \[[ x-]\][[:space:]]+([tr][0-9]+(\.[0-9]+)*).*/\1/p' \
		| sort | uniq -d)
	head_dupes=$(printf '%s\n' "$head_todo" \
		| sed -nE 's/^[[:space:]]*- \[[ x-]\][[:space:]]+([tr][0-9]+(\.[0-9]+)*).*/\1/p' \
		| sort | uniq -d)

	# IDs duplicated in staged that were NOT already duplicated in HEAD =
	# newly introduced collisions. `comm -23` emits lines unique to the
	# first sorted input — exactly what we want.
	new_dupes=$(comm -23 \
		<(printf '%s\n' "$staged_dupes") \
		<(printf '%s\n' "$head_dupes") \
		| grep -v '^$' || true)

	if [[ -n "$new_dupes" ]]; then
		print_error "New duplicate task IDs introduced in TODO.md:"
		while read -r dup; do
			[[ -n "$dup" ]] && print_error "  - $dup"
		done <<< "$new_dupes"
		print_error "Historical duplicates in main are tolerated; this commit adds a NEW collision."
		return 1
	fi

	return 0
}

# Validate that a staged .task-counter is not regressing compared to HEAD.
#
# Scenarios:
#   - .task-counter not staged        -> skip (pass)
#   - Staged value == HEAD value      -> pass (no-op / merge)
#   - Staged value >  HEAD value      -> pass (new claim)
#   - Staged value <  HEAD value      -> FAIL (stale worktree regression)
#   - Non-numeric in either           -> skip (first-commit or legacy)
validate_task_counter_monotonic() {
	if ! staged_diff --name-only | grep -q '^\.task-counter$'; then
		return 0
	fi

	local staged_value head_value
	staged_value=$(git show :.task-counter 2>/dev/null | tr -d '[:space:]')
	head_value=$(git show HEAD:.task-counter 2>/dev/null | tr -d '[:space:]')

	[[ "$staged_value" =~ ^[0-9]+$ ]] || return 0
	[[ "$head_value" =~ ^[0-9]+$ ]] || return 0

	if (( staged_value < head_value )); then
		print_error ".task-counter regression detected:"
		print_error "  HEAD value:   $head_value"
		print_error "  Staged value: $staged_value"
		print_error ""
		print_error "This is almost always a stale worktree overwriting main's counter."
		print_error "Fix: git checkout origin/main -- .task-counter"
		return 1
	fi
	return 0
}

validate_return_statements() {
	local violations=0

	print_info "Validating return statements (ratchet)..."

	for file in "$@"; do
		if [[ -f "$file" ]]; then
			# Count missing-return functions in staged version.
			local staged_funcs staged_returns staged_missing=0
			staged_funcs=$(grep -c "^[a-zA-Z_][a-zA-Z0-9_]*() {" "$file" || true)
			staged_returns=$(grep -c "return [01]" "$file" || true)
			if ((staged_funcs > 0 && staged_returns < staged_funcs)); then
				staged_missing=$((staged_funcs - staged_returns))
			fi

			# Count missing-return functions in HEAD version (if file exists).
			local head_content head_funcs head_returns head_missing=0
			head_content=$(_get_head_content "$file")
			if [[ -n "$head_content" ]]; then
				head_funcs=$(grep -c "^[a-zA-Z_][a-zA-Z0-9_]*() {" <<< "$head_content" || true)
				head_returns=$(grep -c "return [01]" <<< "$head_content" || true)
				if ((head_funcs > 0 && head_returns < head_funcs)); then
					head_missing=$((head_funcs - head_returns))
				fi
			fi

			if ((staged_missing > head_missing)); then
				print_error "NEW missing return statements in $file (new: $((staged_missing - head_missing)), pre-existing: $head_missing)"
				((++violations))
			elif ((staged_missing > 0)); then
				print_warning "Pre-existing missing returns in $file: $staged_missing (not blocking)"
			fi
		fi
	done

	return $violations
}

validate_positional_parameters() {
	local violations=0

	print_info "Validating positional parameters (ratchet)..."

	# Shared awk script — extracted so we can run it over both staged content
	# (the on-disk file) and HEAD content (piped from git show).
	# shellcheck disable=SC2016  # $1, $[1-9] etc. are awk regex literals, not shell expansions
	local _awk_script='
	{
		line = $0
		# Strip single-quoted segments — shell does not expand $ inside single quotes,
		# so awk field refs like awk '"'"'$1 >= 3'"'"' are not positional params.
		# \047 is octal for single-quote (avoids shell quoting issues).
		gsub(/\047[^\047]*\047/, "", line)
		# Skip pure comment lines (after stripping quoted content)
		if (line ~ /^[[:space:]]*#/) next
		# Strip inline comments
		sub(/[[:space:]]+#.*/, "", line)
		# Skip lines with local var assignments (proper usage pattern)
		if (line ~ /local[[:space:]].*=.*\$[1-9]/) next
		# Skip currency/pricing patterns: $N followed by digit, decimal, comma, slash
		if (line ~ /\$[1-9][0-9.,\/]/) next
		# Skip markdown table cells: $N followed by pipe
		if (line ~ /\$[1-9][[:space:]]*\|/) next
		# Skip pricing unit words
		if (line ~ /\$[1-9][[:space:]]+(per|mo(nth)?|year|yr|day|week|hr|hour|flat|each|off|fee|plan|tier|user|seat|unit|addon|setup|trial|credit|annual|quarterly|monthly)/) next
		# After stripping, if $[1-9] is still present, flag as violation
		if (line ~ /\$[1-9]/) print NR ": " $0
	}'

	for file in "$@"; do
		# Skip test files — fixtures deliberately inject bare positional
		# parameter usage to exercise the validator. See validate_string_literals
		# for the same rationale.
		if [[ "$file" == *"/tests/"* ]] || [[ "$(basename "$file")" == test-*.sh ]]; then
			continue
		fi

		if [[ -f "$file" ]]; then
			local staged_output head_output
			local staged_count=0 head_count=0
			staged_output=$(awk "$_awk_script" "$file" 2>/dev/null || true)
			if [[ -n "$staged_output" ]]; then
				staged_count=$(printf '%s\n' "$staged_output" | wc -l | tr -d ' ')
			fi

			local head_content
			head_content=$(_get_head_content "$file")
			if [[ -n "$head_content" ]]; then
				head_output=$(printf '%s\n' "$head_content" | awk "$_awk_script" 2>/dev/null || true)
				if [[ -n "$head_output" ]]; then
					head_count=$(printf '%s\n' "$head_output" | wc -l | tr -d ' ')
				fi
			fi

			if ((staged_count > head_count)); then
				print_error "NEW direct positional parameter usage in $file (new: $((staged_count - head_count)), pre-existing: $head_count)"
				echo "$staged_output" | head -3
				((++violations))
			elif ((staged_count > 0)); then
				print_warning "Pre-existing positional parameter usage in $file: $staged_count (not blocking)"
			fi
		fi
	done

	return $violations
}

# Extract the distinct-repeated-literal detection pipeline into a single helper
# so the patterns are defined once. Keeps validate_string_literals from
# dogfooding itself (4× repeated literal regexes in-source).
# Reads content on stdin, prints "<count>" of distinct literals repeated ≥3×.
#
# The sed pre-strip pass removes shell variable references before the literal
# extraction regex runs. Without it, the span between two adjacent quoted
# shell-argument tokens — e.g. the " repo=" in `local tid="$1" repo="$2"` —
# is captured as a 6-char "literal" using the closing " of "$1" and the
# opening " of "$2" as outer quotes. The existing `^"\$` exclusion only
# rejects literals that START with "$", not inter-argument spans. (GH#20505)
#
# Sed patterns (ERE, -E works on both BSD and GNU sed):
#   "\$[A-Za-z_][A-Za-z0-9_]*"   → "$var", "$name", "$_private"
#   "\$\{[^}]*\}"                 → "${var}", "${var:-default}", "${#var}"
#   "\$@"                         → special array-expansion token
#   "\$[0-9*#?$!-]"               → "$1", "$*", "$#", "$?", "$$", "$!", "$-"
#
# POSIX note: [[:space:]] replaces \s in grep to ensure BSD grep compatibility.
_count_repeated_literals() {
	local _ext_literal='"[^"]{4,}"'
	local _ext_numeric='^"[0-9]+\.?[0-9]*"$'
	local _ext_varref='^"\$'
	grep -v '^[[:space:]]*#' |
		sed -E '
			s/"\$[A-Za-z_][A-Za-z0-9_]*"//g
			s/"\$\{[^}]*\}"//g
			s/"\$@"//g
			s/"\$[0-9*#?$!-]"//g
		' |
		grep -oE "$_ext_literal" |
		grep -vE "$_ext_numeric" |
		grep -vE "$_ext_varref" |
		sort | uniq -c | awk '$1 >= 3' | wc -l | tr -d ' '
	return 0
}

# Same pipeline but prints the top-3 "count: literal" display form.
# Applies the same sed pre-strip as _count_repeated_literals so that display
# output matches the counter — no phantom truncated literals like `4x: "`.
_show_repeated_literals() {
	local _ext_literal='"[^"]{4,}"'
	local _ext_numeric='^"[0-9]+\.?[0-9]*"$'
	local _ext_varref='^"\$'
	grep -v '^[[:space:]]*#' |
		sed -E '
			s/"\$[A-Za-z_][A-Za-z0-9_]*"//g
			s/"\$\{[^}]*\}"//g
			s/"\$@"//g
			s/"\$[0-9*#?$!-]"//g
		' |
		grep -oE "$_ext_literal" |
		grep -vE "$_ext_numeric" |
		grep -vE "$_ext_varref" |
		sort | uniq -c | awk '$1 >= 3 {print "  " $1 "x: " $2}' | head -3
	return 0
}

validate_string_literals() {
	local violations=0

	print_info "Validating string literals (ratchet)..."

	for file in "$@"; do
		# Skip test files — fixtures legitimately repeat assertion strings
		# and sample inputs to exercise the patterns they verify. Blocking
		# these produces false positives that force test authors to obscure
		# their fixtures.
		if [[ "$file" == *"/tests/"* ]] || [[ "$(basename "$file")" == test-*.sh ]]; then
			continue
		fi

		if [[ -f "$file" ]]; then
			# Count DISTINCT literals repeated >= 3 times in code lines.
			# Exclusions (false-positive classes):
			#   - Comment-only lines (^\s*#) — documentation, not code
			#   - Numeric strings ("123", "3.14") — version numbers, counts
			#   - Shell variable references ("$var", "${var}") — interpolations, not literals
			#   - Strings shorter than 4 chars — covers "", "$1", "$@", "$?" etc.
			local staged_repeated head_repeated=0
			staged_repeated=$(<"$file" _count_repeated_literals)
			[[ -z "$staged_repeated" ]] && staged_repeated=0

			local head_content
			head_content=$(_get_head_content "$file")
			if [[ -n "$head_content" ]]; then
				head_repeated=$(printf '%s\n' "$head_content" | _count_repeated_literals)
				[[ -z "$head_repeated" ]] && head_repeated=0
			fi

			if ((staged_repeated > head_repeated)); then
				# NEW repeated literals introduced by this commit — ratchet blocks.
				print_error "NEW repeated string literals in $file (new: $((staged_repeated - head_repeated)), pre-existing: $head_repeated)"
				<"$file" _show_repeated_literals
				((++violations))
			elif ((staged_repeated > 0)); then
				# Pre-existing debt — advisory only, never blocks. Test fixtures
				# legitimately repeat assertion strings; maintenance commits must
				# not be trapped by legacy files they merely touch.
				print_warning "Pre-existing repeated string literals in $file: $staged_repeated distinct literal(s) (not blocking)"
				<"$file" _show_repeated_literals
			fi
		fi
	done

	return $violations
}

# ABSOLUTE gate (not ratchet): raw stat -c / stat -f in .agents/scripts/ is
# always wrong after the portable-stat.sh migration (GH#21742). Use
# _file_mtime_epoch, _file_size_bytes, _file_perms, _file_owner, _stat_batch,
# or _stat_translate_fmt instead.
# Allowlist: portable-stat.sh (defines the wrappers), lint-shell-portability.sh
# (detects raw stat in other repos), and test files.
validate_portable_stat() {
	local violations=0

	print_info "Validating portable-stat usage (absolute)..."

	for file in "$@"; do
		[[ ! -f "$file" ]] && continue
		local base
		base=$(basename "$file")
		# Allowlisted files that legitimately reference raw stat
		case "$base" in
			portable-stat.sh|lint-shell-portability.sh|test-*) continue ;;
		esac

		local raw_count
		# Match stat -c or stat -f in code lines (skip comments)
		raw_count=$(grep -cE '(^|[[:space:]])stat[[:space:]]+-[cf][[:space:]%]' "$file" 2>/dev/null || true)
		# Subtract comment lines
		local comment_count
		comment_count=$(grep -cE '^[[:space:]]*#.*stat[[:space:]]+-[cf]' "$file" 2>/dev/null || true)
		[[ -z "$raw_count" ]] && raw_count=0
		[[ -z "$comment_count" ]] && comment_count=0
		local code_count=$((raw_count - comment_count))
		[[ "$code_count" =~ ^[0-9]+$ ]] || code_count=0

		if ((code_count > 0)); then
			print_error "Raw stat -c/-f in $file ($code_count call(s)). Use portable-stat.sh wrappers instead."
			grep -nE '(^|[[:space:]])stat[[:space:]]+-[cf][[:space:]%]' "$file" | grep -v '^[[:space:]]*#' >&2 || true
			((++violations))
		fi
	done

	return $violations
}

run_shellcheck() {
	local violations=0

	if ! command -v shellcheck &>/dev/null; then
		print_warning "shellcheck not found — skipping ShellCheck validation"
		return 0
	fi

	print_info "Running ShellCheck validation (ratchet)..."

	# ShellCheck regressions are quality debt, not CVE-class — ratchet applies.
	# New files with ANY findings still block (head_count=0 → staged_count > 0
	# is a strict increase). Files that already carried findings on main can be
	# touched without paying down their legacy debt in the same commit.
	for file in "$@"; do
		if [[ ! -f "$file" ]]; then
			continue
		fi

		# Count staged-file findings (gcc format: one finding per line).
		local staged_count head_count=0
		staged_count=$(shellcheck -f gcc "$file" 2>/dev/null | grep -c ':[[:space:]]' || true)
		[[ -z "$staged_count" ]] && staged_count=0

		# Count HEAD findings by materializing the content into a temp file
		# that preserves the basename (so shellcheck uses shebang/ext heuristics).
		local head_tmp head_dir
		if head_tmp=$(_make_head_temp "$file"); then
			head_dir=$(dirname "$head_tmp")
			head_count=$(shellcheck -f gcc "$head_tmp" 2>/dev/null | grep -c ':[[:space:]]' || true)
			[[ -z "$head_count" ]] && head_count=0
			rm -rf "$head_dir"
		fi

		if ((staged_count > head_count)); then
			print_error "NEW ShellCheck violations in $file (new: $((staged_count - head_count)), pre-existing: $head_count)"
			# Re-run for full-detail output so the author can fix the new findings.
			shellcheck "$file" || true
			((++violations))
		elif ((staged_count > 0)); then
			print_warning "Pre-existing ShellCheck violations in $file: $staged_count (not blocking)"
		fi
	done

	return $violations
}

check_secrets() {
	# SECURITY EXCEPTION (t2230, AGENTS.md "Gate design — ratchet, not absolute"):
	# Credential/secret detection is ABSOLUTE-COUNT by design. A newly exposed
	# secret is a CVE-class event regardless of pre-existing state. Do NOT
	# convert this validator to ratchet semantics.
	local violations=0
	local secrets_clean_msg="No secrets detected in staged files"
	local secrets_found_msg="Potential secrets detected in staged files!"

	print_info "Checking for exposed secrets (Secretlint, absolute-count security gate)..."

	# Get staged files
	local staged_files
	staged_files=$(staged_diff --name-only --diff-filter=ACMR | tr '\n' ' ')

	if [[ -z "$staged_files" ]]; then
		print_info "No files to check for secrets"
		return 0
	fi

	# Check if secretlint is available
	if command -v secretlint &>/dev/null; then
		if echo "$staged_files" | xargs secretlint --format compact 2>/dev/null; then
			print_success "$secrets_clean_msg"
		else
			print_error "$secrets_found_msg"
			print_info "Review the findings and either:"
			print_info "  1. Remove the secrets from your code"
			print_info "  2. Add to .secretlintignore if false positive"
			print_info "  3. Use // secretlint-disable-line comment"
			((++violations))
		fi
	elif [[ -f "node_modules/.bin/secretlint" ]]; then
		if echo "$staged_files" | xargs ./node_modules/.bin/secretlint --format compact 2>/dev/null; then
			print_success "$secrets_clean_msg"
		else
			print_error "$secrets_found_msg"
			((++violations))
		fi
	elif command -v npx &>/dev/null && [[ -f ".secretlintrc.json" ]]; then
		if echo "$staged_files" | xargs npx secretlint --format compact 2>/dev/null; then
			print_success "$secrets_clean_msg"
		else
			print_error "$secrets_found_msg"
			((++violations))
		fi
	else
		print_warning "Secretlint not available (install: npm install secretlint --save-dev)"
	fi

	return $violations
}

check_quality_standards() {
	print_info "Checking current quality standards..."

	# Check SonarCloud status if curl is available
	if command -v curl &>/dev/null && command -v jq &>/dev/null; then
		local response
		if response=$(curl -s --max-time 10 "https://sonarcloud.io/api/issues/search?componentKeys=marcusquinn_aidevops&impactSoftwareQualities=MAINTAINABILITY&resolved=false&ps=1" 2>/dev/null); then
			local total_issues
			total_issues=$(echo "$response" | jq -r '.total // 0' 2>/dev/null || echo "unknown")

			if [[ "$total_issues" != "unknown" ]]; then
				print_info "Current SonarCloud issues: $total_issues"

				if [[ $total_issues -gt 200 ]]; then
					print_warning "High issue count detected. Consider running quality fixes."
				fi
			fi
		fi
	fi
	return 0
}

# Validate TODO.md task completion transitions (t317.1)
# When [ ] -> [x], require pr:# or verified: field for proof-log
validate_todo_completions() {
	# Only check if TODO.md is staged
	if ! staged_diff --name-only | grep -q '^TODO\.md$'; then
		return 0
	fi

	print_info "Validating TODO.md task completions (proof-log check)..."

	# Find ALL tasks (including subtasks) that changed from [ ] to [x] in this commit
	# We need to check both top-level and subtasks
	local newly_completed
	newly_completed=$(staged_diff -U0 -- TODO.md | grep -E '^\+.*- \[x\] t[0-9]+' | sed 's/^\+//' || true)

	if [[ -z "$newly_completed" ]]; then
		return 0
	fi

	# Also get lines that were already [x] (to skip them - not a transition)
	local already_completed
	already_completed=$(staged_diff -U0 -- TODO.md | grep -E '^\-.*- \[x\] t[0-9]+' | sed 's/^\-//' || true)

	local task_count=0
	local fail_count=0
	local failed_tasks=()

	while IFS= read -r line; do
		local task_id
		task_id=$(echo "$line" | grep -oE 't[0-9]+(\.[0-9]+)*' | head -1 || echo "")
		if [[ -z "$task_id" ]]; then
			continue
		fi

		# Skip if this task was already [x] in the previous version (not a transition)
		if echo "$already_completed" | grep -q "$task_id"; then
			continue
		fi

		task_count=$((task_count + 1))

		# Check for required evidence: pr:# or verified: field
		local has_evidence=false

		# Check for pr:# field (e.g., pr:123 or pr:#123)
		if echo "$line" | grep -qE 'pr:#?[0-9]+'; then
			has_evidence=true
		fi

		# Check for verified: field (e.g., verified:2026-02-12)
		if echo "$line" | grep -qE 'verified:[0-9]{4}-[0-9]{2}-[0-9]{2}'; then
			has_evidence=true
		fi

		if [[ "$has_evidence" == "false" ]]; then
			failed_tasks+=("$task_id")
			((++fail_count))
		fi
	done <<<"$newly_completed"

	if [[ "$fail_count" -gt 0 ]]; then
		print_error "TODO.md completion proof-log check FAILED"
		print_error ""
		print_error "The following tasks were marked [x] without proof-log evidence:"
		for task in "${failed_tasks[@]}"; do
			print_error "  - $task"
		done
		print_error ""
		print_error "Required: Each completed task must have either:"
		print_error "  1. pr:#NNN field (e.g., pr:#1229)"
		print_error "  2. verified:YYYY-MM-DD field (e.g., verified:$(date +%Y-%m-%d))"
		print_error ""
		print_error "This ensures the issue-sync pipeline can verify deliverables"
		print_error "before auto-closing GitHub issues."
		print_error ""
		print_info "To fix: Add pr:# or verified: to each task line, then retry commit"
		return 1
	fi

	if [[ "$task_count" -gt 0 ]]; then
		print_success "All $task_count completed tasks have proof-log evidence"
	fi

	return 0
}

# t1003: Validate that parent tasks with open subtasks are not marked complete

# Check for open subtasks using explicit ID pattern (e.g., t123.1, t123.2)
# Arguments: $1=staged_todo, $2=task_id
# Output: count of open subtasks (0 if none)
_check_explicit_subtasks() {
	local staged_todo="$1"
	local task_id="$2"

	local explicit_subtasks
	explicit_subtasks=$(echo "$staged_todo" | grep -E "^[[:space:]]*- \[ \] ${task_id}\.[0-9]+( |$)" || true)

	if [[ -n "$explicit_subtasks" ]]; then
		echo "$explicit_subtasks" | wc -l | tr -d ' '
		return 0
	fi

	echo "0"
	return 0
}

# Check for open subtasks using indentation hierarchy
# Arguments: $1=staged_todo, $2=task_id
# Output: count of open subtasks (0 if none)
_check_indentation_subtasks() {
	local staged_todo="$1"
	local task_id="$2"

	local task_line
	task_line=$(echo "$staged_todo" | grep -E "^[[:space:]]*- \[x\] ${task_id}( |$)" | head -1 || true)
	if [[ -z "$task_line" ]]; then
		echo "0"
		return 0
	fi

	local task_indent
	task_indent=$(echo "$task_line" | sed -E 's/^([[:space:]]*).*/\1/' | wc -c)
	task_indent=$((task_indent - 1))

	local open_subtasks
	open_subtasks=$(echo "$staged_todo" | awk -v tid="$task_id" -v tindent="$task_indent" '
		BEGIN { found=0 }
		/- \[x\] '"$task_id"'( |$)/ { found=1; next }
		found && /^[[:space:]]*- \[/ {
			match($0, /^[[:space:]]*/);
			line_indent = RLENGTH;
			if (line_indent > tindent) {
				if ($0 ~ /- \[ \]/) { print $0 }
			} else { found=0 }
		}
		found && /^[[:space:]]*$/ { next }
		found && !/^[[:space:]]*- / && !/^[[:space:]]*$/ { found=0 }
	')

	if [[ -n "$open_subtasks" ]]; then
		echo "$open_subtasks" | wc -l | tr -d ' '
		return 0
	fi

	echo "0"
	return 0
}

# Report parent-subtask blocking failures
# Arguments: failed_tasks array passed via positional args
_report_parent_subtask_failures() {
	print_error "Parent task completion check FAILED"
	print_error ""
	print_error "The following parent tasks were marked [x] with open subtasks:"
	for task in "$@"; do
		print_error "  - $task"
	done
	print_error ""
	print_error "Parent tasks should only be completed when ALL subtasks are done."
	print_error ""
	print_info "To fix: Complete all subtasks first, then retry commit"
	return 0
}

validate_parent_subtask_blocking() {
	# Only check if TODO.md is staged
	if ! staged_diff --name-only | grep -q '^TODO\.md$'; then
		return 0
	fi

	print_info "Validating parent task completion (subtask blocking check)..."

	# Get the staged version of TODO.md
	local staged_todo
	staged_todo=$(git show :TODO.md 2>/dev/null || true)
	if [[ -z "$staged_todo" ]]; then
		return 0
	fi

	# Find tasks that changed from [ ] to [x]
	local newly_completed
	newly_completed=$(staged_diff -U0 -- TODO.md | grep -E '^\+.*- \[x\] t[0-9]+' | sed 's/^\+//' || true)

	if [[ -z "$newly_completed" ]]; then
		return 0
	fi

	# Also get lines that were already [x] (to skip them)
	local already_completed
	already_completed=$(staged_diff -U0 -- TODO.md | grep -E '^\-.*- \[x\] t[0-9]+' | sed 's/^\-//' || true)

	local fail_count=0
	local failed_tasks=()

	while IFS= read -r line; do
		local task_id
		task_id=$(echo "$line" | grep -oE 't[0-9]+(\.[0-9]+)*' | head -1 || echo "")
		if [[ -z "$task_id" ]]; then
			continue
		fi

		# Skip if this task was already [x] (not a transition)
		if echo "$already_completed" | grep -q "$task_id"; then
			continue
		fi

		# Skip subtasks (tNNN.M format) — only check parent tasks
		if [[ "$task_id" =~ \.[0-9]+$ ]]; then
			continue
		fi

		# Check for explicit subtask IDs (e.g., t123.1, t123.2 are children of t123)
		local open_count
		open_count=$(_check_explicit_subtasks "$staged_todo" "$task_id")
		if [[ "$open_count" -gt 0 ]]; then
			failed_tasks+=("$task_id (has $open_count open subtask(s) by ID)")
			((++fail_count))
			continue
		fi

		# Check for indentation-based subtasks
		open_count=$(_check_indentation_subtasks "$staged_todo" "$task_id")
		if [[ "$open_count" -gt 0 ]]; then
			failed_tasks+=("$task_id (has $open_count open subtask(s) by indentation)")
			((++fail_count))
		fi
	done <<<"$newly_completed"

	if [[ "$fail_count" -gt 0 ]]; then
		_report_parent_subtask_failures "${failed_tasks[@]}"
		return 1
	fi

	return 0
}

# t1039 / GH#32805: Validate new files in the repo root.
# Prevents workers from committing ephemeral artifacts (TEST-REPORT.md, VERIFY-*.md, etc.)
#   - aidevops framework repo: strict exact-name allowlist (_init_root_file_allowlist).
#   - consumer repos (default "artifact-guard"): block only report/scratch-like
#     names; standard toolchain files (tsconfig.json, Dockerfile, ...) pass.
#   - .aidevops.json {"root_files": {"mode": "artifact-guard"|"strict",
#     "allow": [names], "deny": [globs]}} overrides consumer behaviour.

# Whole-word report/scratch terms (matched on the lowercased file name).
_ROOT_ARTIFACT_WORD_RE='(^|[-_.])(test|tests|report|reports|verify|verification|result|results|output|summary|debug|scratch|notes)([-_.]|$)'
# Standard lowercased base names (extension removed) for root .md / .txt files.
_ROOT_STANDARD_MD_BASES=" readme changelog contributing license security code_of_conduct support governance maintainers authors notice roadmap upgrading migration architecture glossary agents agent claude gemini design todo models terms "
_ROOT_STANDARD_TXT_BASES=" license notice cmakelists llms runtime "
_ROOT_MODE_GUARD="artifact-guard"
_ROOT_MODE_FRAMEWORK="framework"
# jq prefix yielding the root_files object, or {} when absent or not an object.
_ROOT_FILES_JQ_SECTION='(.root_files // {}) | (objects // {})'
ROOT_FILES_MODE="$_ROOT_MODE_GUARD"
ROOT_FILES_ALLOW=""
ROOT_FILES_DENY=""

# Populate the ROOT_FILE_ALLOWLIST array with permitted root-level filenames.
# Framework repo and strict mode use it exclusively; artifact-guard mode also
# accepts every name on it, so the guard never rejects a previously valid file.
# Call once, then reference ${ROOT_FILE_ALLOWLIST[@]} in checks.
_init_root_file_allowlist() {
	ROOT_FILE_ALLOWLIST=(
		# Documentation
		"README.md" "TODO.md" "AGENTS.md" "AGENT.md" "CLAUDE.md" "GEMINI.md"
		"CHANGELOG.md" "DESIGN.md" "LICENSE" "CODE_OF_CONDUCT.md" "CONTRIBUTING.md"
		"SECURITY.md" "TERMS.md" "MODELS.md" "VERSION"
		# Config files (dotfiles)
		".aidevops.json" ".bandit" ".gitattributes" ".gitignore" ".nvmrc"
		".codacy.yml" ".codefactor.yml" ".coderabbit.yaml"
		".markdownlint-cli2.jsonc" ".markdownlint.json" ".markdownlintignore"
		".qlty/qlty.toml" ".qlty.toml" ".qltyignore"
		".secretlintignore" ".secretlintrc.json"
		# Tool configs (non-dotfile)
		"biome.json"
		"eslint.config.js" "eslint.config.mjs" "eslint.config.cjs"
		"eslint.config.ts" "eslint.config.mts" "eslint.config.cts"
		# Vitest resolves vitest.config.{ts,mts,cts,js,mjs,cjs}; Vitest 4
		# test.projects lives here (GH#32799).
		"vitest.config.js" "vitest.config.mjs" "vitest.config.cjs"
		"vitest.config.ts" "vitest.config.mts" "vitest.config.cts"
		# Build/package files
		"package.json" "package-lock.json" "npm-shrinkwrap.json"
		"pnpm-lock.yaml" "yarn.lock" "bun.lock" "bun.lockb"
		"requirements.txt" "requirements-lock.txt"
		# Scripts
		"setup.sh" "aidevops.sh"
		# Public shell entrypoints. Implementation modules belong under
		# .agents/scripts/aidevops-cli/ or .agents/scripts/setup/modules/.
		# Tool configs
		"sonar-project.properties"
		# Test scripts (temporary - should be moved to .agents/scripts/)
		"test-proof-log-final.sh"
	)
	return 0
}

# Check if a filename is in the root file allowlist.
# Arguments: $1=filename
# Returns: 0 if allowed, 1 if not
_is_root_file_allowed() {
	local filename="$1"
	local allowed_file

	for allowed_file in "${ROOT_FILE_ALLOWLIST[@]}"; do
		if [[ "$filename" == "$allowed_file" ]]; then
			return 0
		fi
	done
	return 1
}

# Lowercase a string portably (Bash 3.2 has no ${var,,}).
_root_lower() {
	local value="$1"
	printf '%s' "$value" | tr '[:upper:]' '[:lower:]'
	return 0
}

# Arguments: $1=repo root. Returns 0 for the aidevops framework repo.
_is_aidevops_framework_repo() {
	local repo_root="$1"
	if [[ -f "${repo_root}/aidevops.sh" && -f "${repo_root}/.agents/scripts/pre-commit-hook.sh" ]]; then
		return 0
	fi
	return 1
}

# Read one root_files list (allow|deny) from .aidevops.json as newline-separated strings.
# Arguments: $1=config file, $2=key
_root_files_config_list() {
	local config_file="$1"
	local key="$2"
	jq -r --arg key "$key" "${_ROOT_FILES_JQ_SECTION} | (.[\$key] // []) | (arrays // []) | .[] | strings" \
		"$config_file" 2>/dev/null || true
	return 0
}

# Resolve ROOT_FILES_MODE (framework|strict|artifact-guard), ROOT_FILES_ALLOW and
# ROOT_FILES_DENY. Config problems warn and fall back to artifact-guard.
# Arguments: $1=repo root
_root_files_mode() {
	local repo_root="$1"
	local config_file="${repo_root}/.aidevops.json"
	ROOT_FILES_MODE="$_ROOT_MODE_GUARD"
	ROOT_FILES_ALLOW=""
	ROOT_FILES_DENY=""

	if _is_aidevops_framework_repo "$repo_root"; then
		ROOT_FILES_MODE="$_ROOT_MODE_FRAMEWORK"
		return 0
	fi
	if [[ ! -f "$config_file" ]]; then
		return 0
	fi
	if ! command -v jq >/dev/null 2>&1; then
		print_warning "jq not found; ignoring root_files in .aidevops.json (using artifact-guard)"
		return 0
	fi
	if ! jq -e 'objects' "$config_file" >/dev/null 2>&1; then
		print_warning ".aidevops.json is not a valid JSON object; using artifact-guard root file mode"
		return 0
	fi

	local mode
	mode=$(jq -r --arg def "$_ROOT_MODE_GUARD" "${_ROOT_FILES_JQ_SECTION} | (.mode // \$def) | tostring" \
		"$config_file" 2>/dev/null) || mode="$_ROOT_MODE_GUARD"
	case "$mode" in
	artifact-guard | strict) ROOT_FILES_MODE="$mode" ;;
	*) print_warning "Unknown root_files.mode '${mode}' in .aidevops.json; using artifact-guard" ;;
	esac
	ROOT_FILES_ALLOW=$(_root_files_config_list "$config_file" allow)
	ROOT_FILES_DENY=$(_root_files_config_list "$config_file" deny)
	return 0
}

# Arguments: $1=lowercased name, $2=newline list, $3=exact|glob
# Returns: 0 if the name matches an entry (case-insensitive)
_root_name_in_list() {
	local name_lc="$1"
	local list="$2"
	local match_kind="$3"
	local entry entry_lc
	while IFS= read -r entry; do
		[[ -z "$entry" ]] && continue
		entry_lc=$(_root_lower "$entry")
		if [[ "$match_kind" == "glob" ]]; then
			# shellcheck disable=SC2053 # deny entries are intentional glob patterns
			if [[ "$name_lc" == $entry_lc ]]; then
				return 0
			fi
		elif [[ "$name_lc" == "$entry_lc" ]]; then
			return 0
		fi
	done <<<"$list"
	return 1
}

# Arguments: $1=lowercased .md/.txt/.toon name. Returns 0 for standard doc names.
_is_standard_doc_name() {
	local name_lc="$1"
	local ext="${name_lc##*.}"
	local base="${name_lc%.*}"
	case "$ext" in
	md)
		[[ "$_ROOT_STANDARD_MD_BASES" == *" ${base} "* ]] && return 0
		;;
	txt)
		case "$base" in
		requirements* | constraints*) return 0 ;;
		esac
		[[ "$_ROOT_STANDARD_TXT_BASES" == *" ${base} "* ]] && return 0
		;;
	esac
	return 1
}

# Arguments: $1=lowercased name. Returns 0 when the name looks like a work artifact.
_is_root_artifact_name() {
	local name_lc="$1"
	if [[ "$name_lc" =~ $_ROOT_ARTIFACT_WORD_RE ]]; then
		return 0
	fi
	case "$name_lc" in
	*.md | *.txt | *.toon)
		_is_standard_doc_name "$name_lc" || return 0
		;;
	*.log | *.patch | *.diff | *.orig | *.rej | *.bak | *.tmp | *.out | junit*.xml | coverage*)
		return 0
		;;
	esac
	return 1
}

# Arguments: $1=filename, $2=mode. Returns 0 if the new root file is permitted.
_is_root_file_permitted() {
	local filename="$1"
	local mode="$2"
	local name_lc
	name_lc=$(_root_lower "$filename")

	if [[ "$mode" == "$_ROOT_MODE_FRAMEWORK" ]]; then
		_is_root_file_allowed "$filename" && return 0
		return 1
	fi
	if _root_name_in_list "$name_lc" "$ROOT_FILES_ALLOW" exact; then
		return 0
	fi
	if [[ "$mode" == "strict" ]]; then
		_is_root_file_allowed "$filename" && return 0
		return 1
	fi
	if _root_name_in_list "$name_lc" "$ROOT_FILES_DENY" glob; then
		return 1
	fi
	if _is_root_file_allowed "$filename"; then
		return 0
	fi
	if _is_root_artifact_name "$name_lc"; then
		return 1
	fi
	return 0
}

# Report root file violations with remediation guidance.
# Arguments: $1=mode, then rejected filenames
_report_root_file_violations() {
	local mode="$1"
	shift
	local file
	print_error "Repo root file validation FAILED (mode: ${mode})"
	print_error ""
	print_error "The following new repo root files look like work artifacts or are not allowed:"
	for file in "$@"; do
		print_error "  - $file"
	done
	print_error ""
	print_error "Do not commit reports, verification output or scratch notes to the repo root:"
	print_error "  - Temporary notes → \${AIDEVOPS_TEMP_DIR:-~/.aidevops/.agent-workspace/tmp} (never committed)"
	print_error "  - Work notes that should be committed → todo/research/"
	print_error ""
	if [[ "$mode" == "$_ROOT_MODE_FRAMEWORK" ]]; then
		print_error "If this file is a legitimate new root-level file, add it to the"
		print_error "allowlist in .agents/scripts/pre-commit-hook.sh (_init_root_file_allowlist)"
	else
		print_error "If this file is a legitimate root-level file, add its name to"
		print_error "root_files.allow in .aidevops.json"
	fi
	print_error ""
	return 0
}

validate_repo_root_files() {
	print_info "Validating repo root files..."

	_init_root_file_allowlist

	# Get newly added root-level files (not in subdirectories)
	local new_root_files
	new_root_files=$(staged_diff --name-only --diff-filter=A | grep -E '^[^/]+$' || true)

	if [[ -z "$new_root_files" ]]; then
		return 0
	fi

	local repo_root
	repo_root=$(git rev-parse --show-toplevel 2>/dev/null) || repo_root="."
	_root_files_mode "$repo_root"
	local mode="$ROOT_FILES_MODE"

	local violations=0
	local -a rejected_files=()

	while IFS= read -r file; do
		if [[ -z "$file" ]]; then
			continue
		fi

		if ! _is_root_file_permitted "$file" "$mode"; then
			rejected_files+=("$file")
			((++violations))
		fi
	done <<<"$new_root_files"

	if [[ "$violations" -gt 0 ]]; then
		_report_root_file_violations "$mode" "${rejected_files[@]}"
		return 1
	fi

	return 0
}

# --- Workflow YAML validation (GH#20489) ---
# Run lint-workflows-helper.sh on staged .github/workflows/*.yml files.
# Catches YAML parse errors and actionlint semantic errors before they ship
# and silently break framework-wide CI gates (root cause: t2691 / PR #20311).
#
# Tool priority (handled inside the helper): actionlint > yamllint > python3 yaml.
# Missing binary: helper warns and exits 0 (degrade gracefully, never block).

check_workflow_files() {
	# Detect staged workflow files without shelling into the helper first —
	# avoids an extra process when no workflow files are staged.
	local staged_workflows
	staged_workflows=$(staged_diff --name-only --diff-filter=ACM \
		| grep -E '^\.github/workflows/[^/]+\.ya?ml$' || true)

	if [[ -z "$staged_workflows" ]]; then
		return 0
	fi

	print_info "Checking staged GitHub Actions workflow files..."

	# Locate the helper: prefer repo source (worktree), fall back to deployed copy.
	local helper_path="${SCRIPT_DIR}/lint-workflows-helper.sh"
	if [[ ! -f "$helper_path" ]]; then
		helper_path="$HOME/.aidevops/agents/scripts/lint-workflows-helper.sh"
	fi

	if [[ ! -f "$helper_path" ]]; then
		print_warning "lint-workflows-helper.sh not found — skipping workflow YAML check"
		return 0
	fi

	# Pass --staged so the helper reads exactly the same staged file list.
	if bash "$helper_path" --staged; then
		return 0
	fi

	# Helper returned non-zero: YAML errors found.
	print_error "Commit blocked: workflow YAML error(s) detected."
	print_info "Fix the issues above, then retry commit."
	print_info "Bypass (not recommended): git commit --no-verify"
	return 1
}

# --- Split hook entry points (t2207) ---
# pre-commit: fast local checks only (target <5s)
# pre-push:   slower network-dependent checks (secretlint, SonarCloud, CodeRabbit)
# Single script, mode selected by HOOK_MODE env var or $(basename "$0").

main_pre_commit() {
	echo -e "${BLUE}Pre-commit Quality Validation${NC}" >&2
	echo -e "${BLUE}================================${NC}" >&2

	# Always run TODO.md validation (even if no shell files changed)
	validate_duplicate_task_ids || {
		print_error "Commit rejected: duplicate task IDs"
		exit 1
	}
	echo "" >&2

	validate_task_counter_monotonic || {
		print_error "Commit rejected: .task-counter regression"
		exit 1
	}
	echo "" >&2

	validate_todo_completions || true
	echo "" >&2

	validate_parent_subtask_blocking || {
		print_error "Commit rejected: parent tasks with open subtasks"
		exit 1
	}
	echo "" >&2

	validate_repo_root_files || {
		print_error "Commit rejected: new repo root files not permitted"
		exit 1
	}
	echo "" >&2

	check_workflow_files || {
		exit 1
	}
	echo "" >&2

	# Get modified shell files
	local modified_files=()
	while IFS= read -r file; do
		[[ -n "$file" ]] && modified_files+=("$file")
	done < <(get_modified_shell_files)

	if [[ ${#modified_files[@]} -eq 0 ]]; then
		print_info "No shell files modified, skipping shell quality checks"
		print_success "Pre-commit checks passed."
		return 0
	fi

	print_info "Checking ${#modified_files[@]} modified shell files:"
	printf '  %s\n' "${modified_files[@]}" >&2
	echo "" >&2

	local total_violations=0

	# Run local validation checks (fast — no network calls)
	validate_return_statements "${modified_files[@]}" || ((total_violations += $?))
	echo "" >&2

	validate_positional_parameters "${modified_files[@]}" || ((total_violations += $?))
	echo "" >&2

	validate_string_literals "${modified_files[@]}" || ((total_violations += $?))
	echo "" >&2

	run_shellcheck "${modified_files[@]}" || ((total_violations += $?))
	echo "" >&2

	validate_portable_stat "${modified_files[@]}" || ((total_violations += $?))
	echo "" >&2

	# Final decision
	if [[ $total_violations -eq 0 ]]; then
		print_success "Pre-commit checks passed."
		return 0
	else
		print_error "Quality violations detected ($total_violations total)"
		echo "" >&2
		print_info "To fix issues automatically, run:"
		print_info "  ./.agents/scripts/quality-fix.sh"
		echo "" >&2
		print_info "To check current status, run:"
		print_info "  ./.agents/scripts/linters-local.sh"
		echo "" >&2
		print_info "To bypass this check (not recommended), use:"
		print_info "  git commit --no-verify"

		return 1
	fi
}

_coderabbit_cli_review_timeout() {
	local review_timeout="${AIDEVOPS_CODERABBIT_CLI_REVIEW_TIMEOUT:-45}"
	if ! [[ "$review_timeout" =~ ^[0-9]+$ ]] || ((review_timeout < 1)); then
		print_warning "Invalid AIDEVOPS_CODERABBIT_CLI_REVIEW_TIMEOUT='${review_timeout}'; using 45s"
		review_timeout=45
	fi
	printf '%s\n' "$review_timeout"
	return 0
}

run_optional_coderabbit_cli_review() {
	if [[ "${AIDEVOPS_SKIP_CODERABBIT_CLI_REVIEW:-0}" == "1" ]]; then
		print_info "CodeRabbit CLI review skipped (AIDEVOPS_SKIP_CODERABBIT_CLI_REVIEW=1)"
		return 0
	fi

	if [[ ! -f ".agents/scripts/coderabbit-cli.sh" ]] || ! command -v coderabbit &>/dev/null; then
		return 0
	fi

	local review_timeout
	review_timeout=$(_coderabbit_cli_review_timeout)
	local review_status=0
	print_info "Running CodeRabbit CLI review (timeout ${review_timeout}s)..."
	if timeout_sec "$review_timeout" bash .agents/scripts/coderabbit-cli.sh review >/dev/null 2>&1; then
		print_success "CodeRabbit CLI review completed"
	else
		review_status=$?
		if [[ $review_status -eq 124 ]]; then
			print_info "CodeRabbit CLI review skipped (timed out after ${review_timeout}s)"
		else
			print_info "CodeRabbit CLI review skipped (setup required)"
		fi
	fi
	return 0
}

main_pre_push() {
	echo -e "${BLUE}Pre-push Quality Validation${NC}" >&2
	echo -e "${BLUE}================================${NC}" >&2

	local total_violations=0

	check_secrets || ((total_violations += $?))
	echo "" >&2

	check_quality_standards
	echo "" >&2

	# Optional CodeRabbit CLI review (advisory; fail-open and bounded)
	run_optional_coderabbit_cli_review
	echo "" >&2

	# Final decision
	if [[ $total_violations -eq 0 ]]; then
		print_success "Pre-push checks passed."
		return 0
	else
		print_error "Quality violations detected ($total_violations total)"
		echo "" >&2
		print_info "To bypass this check (not recommended), use:"
		print_info "  git push --no-verify"

		return 1
	fi
}

main() {
	local mode="${HOOK_MODE:-}"
	if [[ -z "$mode" ]]; then
		case "$(basename "$0")" in
		pre-commit) mode="pre-commit" ;;
		pre-push) mode="pre-push" ;;
		*) mode="pre-commit" ;; # default for direct CLI invocation
		esac
	fi
	case "$mode" in
	pre-commit) main_pre_commit "$@" ;;
	pre-push) main_pre_push "$@" ;;
	all) main_pre_commit "$@" && main_pre_push "$@" ;;
	*)
		print_error "Unknown HOOK_MODE: $mode"
		return 1
		;;
	esac
}

main "$@"
