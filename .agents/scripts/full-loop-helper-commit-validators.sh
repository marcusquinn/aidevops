#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# =============================================================================
# Full-Loop Commit Validators -- project auto-fix and typecheck execution
# =============================================================================
# Focused sub-library for full-loop-helper-commit.sh. The parent library owns
# project detection and changed-file classification; this module executes the
# selected validators and preserves the parent library's function API.
#
# Usage: source "${SCRIPT_DIR}/full-loop-helper-commit-validators.sh"
#
# Dependencies:
#   - full-loop-helper-commit.sh validator detection helpers
#   - shared-constants.sh (print_error, print_info)
#
# Part of aidevops framework: https://aidevops.sh

# Apply strict mode only when executed directly (not when sourced)
[[ "${BASH_SOURCE[0]}" == "${0}" ]] && set -euo pipefail

# Include guard
[[ -n "${_FULL_LOOP_COMMIT_VALIDATORS_LIB_LOADED:-}" ]] && return 0
_FULL_LOOP_COMMIT_VALIDATORS_LIB_LOADED=1
# shellcheck source=./project-node-runtime.sh
source "${SCRIPT_DIR:-${BASH_SOURCE[0]%/*}}/project-node-runtime.sh"

_restore_validator_repo_root() {
	local repo_root="$1"
	local phase="$2"

	if [[ -z "$repo_root" || ! -d "$repo_root" ]]; then
		print_error "[validators] repository root disappeared during ${phase}: ${repo_root:-<unknown>}"
		print_error "[validators] refusing to run git amend from a missing working directory"
		return 1
	fi
	if ! cd "$repo_root" 2>/dev/null; then
		print_error "[validators] failed to restore repository root after ${phase}: $repo_root"
		return 1
	fi
	return 0
}

_validator_file_is_node_related() {
	local changed_file="$1"
	case "$changed_file" in
	package.json | package-lock.json | npm-shrinkwrap.json | pnpm-lock.yaml | pnpm-workspace.yaml | yarn.lock | bun.lock | bun.lockb | \
		*.js | *.jsx | *.mjs | *.cjs | *.ts | *.tsx | *.mts | *.cts | \
		*.eslintrc.* | eslint.config.* | tsconfig*.json | jsconfig*.json | prettier.config.* | .prettierrc*) return 0 ;;
	esac
	return 1
}

_validator_workspace_patterns() {
	# pnpm keeps its authoritative workspace declaration outside package.json.
	# Parse the standard block-list form without executing a package-manager script.
	if [[ -f pnpm-workspace.yaml ]]; then
		local line="" pattern="" in_packages=0 count=0
		while IFS= read -r line || [[ -n "$line" ]]; do
			if [[ "$line" =~ ^packages:[[:space:]]*(#.*)?$ ]]; then
				in_packages=1
				continue
			fi
			[[ "$in_packages" -eq 1 ]] || continue
			[[ "$line" =~ ^[[:space:]]*(#.*)?$ ]] && continue
			if [[ "$line" =~ ^[[:space:]]+-[[:space:]]+(.+)$ ]]; then
				pattern="${BASH_REMATCH[1]}"
				pattern="${pattern%% #*}"
				pattern="${pattern%\"}"
				pattern="${pattern#\"}"
				pattern="${pattern%\'}"
				pattern="${pattern#\'}"
				[[ -n "$pattern" ]] || return 1
				printf '%s\n' "$pattern"
				count=$((count + 1))
			elif [[ "$line" != [[:space:]]* ]]; then
				break
			else
				print_error "[validators] unsupported pnpm workspace packages declaration"
				return 1
			fi
		done <pnpm-workspace.yaml
		if [[ "$count" -eq 0 ]]; then
			print_error "[validators] pnpm-workspace.yaml has no supported package patterns"
			return 1
		fi
		return 0
	fi
	jq -r '.workspaces // empty | if type == "array" then .[] elif type == "object" then (.packages // [])[] else empty end' package.json 2>/dev/null
}

_validator_workspace_matches() {
	local scope="$1"
	local workspace_patterns="$2"
	local pattern="" included=1
	while IFS= read -r pattern; do
		# Workspace declarations are glob patterns (for example packages/*).
		# shellcheck disable=SC2053
		if [[ "$pattern" == '!'* ]]; then
			pattern=${pattern#!}
			# shellcheck disable=SC2053
			[[ "$scope" == $pattern ]] && return 1
		else
			# shellcheck disable=SC2053
			[[ -n "$pattern" && "$scope" == $pattern ]] && included=0
		fi
	done <<<"$workspace_patterns"
	return "$included"
}

_validator_all_workspace_scopes() {
	local workspace_patterns="$1"
	local manifest="" scope="" scopes=""
	# Root checks own shared changes and may already fan out across workspaces.
	# Do not repeat them per package or reject scriptless grouping packages.
	if _validator_package_has_check package.json; then
		printf '.\n'
		return 0
	fi
	while IFS= read -r manifest; do
		[[ "$manifest" == "package.json" ]] && continue
		scope=${manifest%/package.json}
		_validator_workspace_matches "$scope" "$workspace_patterns" || continue
		_validator_package_has_check "$manifest" || continue
		case $'\n'"$scopes"$'\n' in
		*$'\n'"$scope"$'\n'*) ;;
		*) scopes="${scopes}${scopes:+$'\n'}${scope}" ;;
		esac
	done < <(git ls-files '*package.json')
	if [[ -z "$scopes" ]]; then
		print_error "[validators] root/shared change requires broader checks, but no check-only workspace scripts are available"
		return 1
	fi
	printf '%s\n' "$scopes"
	return 0
}

# Print the package roots that own Node-related files in the complete PR range.
# A root/shared change selects root checks, or check-capable workspaces as fallback.
_validator_scopes() {
	local changed_files="" workspace_patterns="" changed_file=""
	local scope=""
	changed_files=$(_validator_changed_files) || return 1
	workspace_patterns=$(_validator_workspace_patterns) || return 1
	if [[ -z "$workspace_patterns" ]]; then
		printf '.\n'
		return 0
	fi
	local scopes=""
	while IFS= read -r changed_file; do
		_validator_file_is_node_related "$changed_file" || continue
		scope=${changed_file%/*}
		[[ "$scope" == "$changed_file" ]] && scope="."
		# Runtime-generated, ignored manifests do not own repository checks.
		while [[ "$scope" != "." ]] && { [[ ! -f "$scope/package.json" ]] || git check-ignore -q -- "$scope/package.json"; }; do
			if [[ "$scope" == */* ]]; then
				scope=${scope%/*}
			else
				scope="."
			fi
		done
		if [[ "$scope" == "." ]]; then
			_validator_all_workspace_scopes "$workspace_patterns"
			return $?
		fi
		if ! _validator_workspace_matches "$scope" "$workspace_patterns" && ! _validator_package_has_check "$scope/package.json"; then
			print_error "[validators] cannot map changed Node file to a declared workspace: $changed_file"
			print_error "[validators] add a package-level check script or correct package.json workspaces before publication"
			return 1
		fi
		case $'\n'"$scopes"$'\n' in
		*$'\n'"$scope"$'\n'*) ;;
		*) scopes="${scopes}${scopes:+$'\n'}${scope}" ;;
		esac
	done <<<"$changed_files"
	[[ -n "$scopes" ]] || return 1
	printf '%s\n' "$scopes"
	return 0
}

_validator_script_is_npm_placeholder() {
	local package_json="$1" script_name="$2" script_command=""
	script_command=$(jq -r --arg s "$script_name" '.scripts[$s] // empty' "$package_json" 2>/dev/null) || return 1
	[[ "$script_command" == 'echo "Error: no test specified" && exit 1' ]]
}

_validator_select_script() {
	local package_json="$1" phase="$2" script_name=""
	local candidates=""
	case "$phase" in
	format) candidates=$'format:check\ncheck:format\nprettier:check' ;;
	lint) candidates=$'lint:check\nlint' ;;
	typecheck) candidates=$'typecheck\ncheck:types\ntsc' ;;
	test) candidates='test' ;;
	esac
	while IFS= read -r script_name; do
		if jq -e --arg s "$script_name" '.scripts[$s] // empty' "$package_json" >/dev/null 2>&1; then
			_validator_script_is_npm_placeholder "$package_json" "$script_name" && continue
			printf '%s\n' "$script_name"
			return 0
		fi
	done <<<"$candidates"
	return 1
}

_validator_package_has_check() {
	local package_json="$1" phase=""
	for phase in format lint typecheck test; do
		_validator_select_script "$package_json" "$phase" >/dev/null && return 0
	done
	return 1
}

_validator_snapshot() {
	local prefix="$1"
	git diff --binary --no-ext-diff >"${prefix}.worktree" || return 1
	git diff --cached --binary --no-ext-diff >"${prefix}.index" || return 1
	return 0
}

_validator_state_unchanged() {
	local before="$1" after="$2" command_label="$3"
	if cmp -s "${before}.worktree" "${after}.worktree" && cmp -s "${before}.index" "${after}.index"; then
		return 0
	fi
	print_error "[validators] check-only command modified tracked files or index state: $command_label"
	print_error "[validators] changes were preserved but will not be staged or amended; inspect git status and configure a non-mutating check"
	git status --short >&2
	return 1
}

# GH#40064: a validator TIMEOUT is an environment outcome, not a check result.
# When the PR base branch already requires a status check for the same phase,
# that merge gate decides instead of a saturated local host. Set per run by
# _run_project_validators; read by commit-and-pr PR metadata.
FULL_LOOP_VALIDATOR_DEFERRALS=""
# GH#40322: plugin tests that failed in the full suite and then passed on a
# serialized rerun. Set and read the same way as the deferrals above.
FULL_LOOP_VALIDATOR_FLAKY=""

# Print the PR base branch's required status-check contexts, one per line.
# One lookup per validator run, shared by scope subshells via snapshot_dir.
# Rulesets and classic protection are unioned: a context from either source is
# genuine merge-gate evidence. Returns 1 when neither source can be read.
_validator_required_contexts() {
	local snapshot_dir="$1"
	local cache="${snapshot_dir}/required-contexts" failed="${snapshot_dir}/required-contexts.failed"
	local slug="${repo:-}" base="" origin_url="" rules="" classic="" sources=0 line=""
	if [[ -f "$cache" ]]; then
		while IFS= read -r line; do printf '%s\n' "$line"; done <"$cache"
		return 0
	fi
	[[ -f "$failed" ]] && return 1
	if [[ "$slug" != */* ]]; then
		origin_url=$(git remote get-url origin 2>/dev/null) || origin_url=""
		slug=$(printf '%s\n' "$origin_url" | sed -E 's#\.git$##; s#^.*[:/]([^/:]+/[^/]+)$#\1#')
	fi
	base=$(_resolve_pr_base_branch origin 2>/dev/null) || base=""
	if [[ "$slug" != */* || -z "$base" ]] || ! command -v gh >/dev/null 2>&1; then
		: >"$failed"
		return 1
	fi
	if rules=$(gh api "repos/${slug}/rules/branches/${base}" \
		--jq '.[] | select(.type == "required_status_checks") | (.parameters.required_status_checks // [])[] | (.context // empty)' 2>/dev/null); then
		sources=$((sources + 1))
	fi
	if classic=$(gh api "repos/${slug}/branches/${base}" \
		--jq '(.protection.required_status_checks.contexts // [])[]' 2>/dev/null); then
		sources=$((sources + 1))
	fi
	if [[ "$sources" -eq 0 ]]; then
		: >"$failed"
		return 1
	fi
	printf '%s\n%s\n' "$rules" "$classic" | awk 'NF && !seen[$0]++' >"$cache" || return 1
	printf '%s\n' "$base" >"${snapshot_dir}/required-base"
	while IFS= read -r line; do printf '%s\n' "$line"; done <"$cache"
	return 0
}

# Print the first required context that names a validator phase. Contexts are
# split into lowercase words; a deny-word marks checks for other languages or
# test classes (Markdown Lint, E2E Tests, Commit Lint), which never match.
_validator_phase_required_context() {
	local phase="$1" contexts="$2" context="" words="" word="" matched=0 denied=0
	while IFS= read -r context; do
		[[ -n "$context" ]] || continue
		words=$(printf '%s' "$context" | tr '[:upper:]' '[:lower:]' | tr -cs '[:alnum:]' ' ')
		matched=0
		denied=0
		for word in $words; do
			case "$word" in
			markdown | md | shell | shellcheck | yaml | yml | docs | commit | commitlint | e2e | playwright | smoke) denied=1 ;;
			esac
			case "${phase}:${word}" in
			format:format | format:formatting | format:prettier | format:fmt | \
				lint:lint | lint:linting | lint:eslint | lint:biome | \
				typecheck:typecheck | typecheck:types | typecheck:type | typecheck:tsc | typecheck:typescript | \
				test:test | test:tests | test:unit | test:vitest | test:jest) matched=1 ;;
			esac
		done
		if [[ "$matched" -eq 1 && "$denied" -eq 0 ]]; then
			printf '%s\n' "$context"
			return 0
		fi
	done <<<"$contexts"
	return 1
}

# Defer one phase to its required CI check. Returns 1 (caller keeps blocking)
# when no required context can be read or none names the phase.
_validator_defer_to_required_ci() {
	local phase="$1" command_label="$2" snapshot_dir="$3" why="$4"
	local contexts="" context="" base=""
	contexts=$(_validator_required_contexts "$snapshot_dir") || return 1
	context=$(_validator_phase_required_context "$phase" "$contexts") || return 1
	base=$(<"${snapshot_dir}/required-base") || base="the PR base"
	print_warning "[validators] DEFERRED ${command_label}: ${why}; required CI check '${context}' on ${base} gates the merge"
	printf '%s → %s\n' "$command_label" "$context" >>"${snapshot_dir}/deferred" || return 1
	return 0
}

_run_scoped_node_checks() {
	local pm="$1" scope="$2" t="$3" snapshot_dir="$4"
	local package_json="package.json" scope_label="repository root"
	local node_bin="" node_rc=0
	node_bin=$(_project_node_bin "$PWD" "$scope") || node_rc=$?
	[[ "$node_rc" -eq 1 ]] && return 1
	# The selected bin takes precedence over package-manager shims that may
	# dispatch through /usr/bin/env node; keep it local to this scoped check.
	[[ -n "$node_bin" ]] && export PATH="${node_bin}:$PATH"
	if [[ "$scope" != "." ]]; then
		package_json="$scope/package.json"
		scope_label="$scope"
	fi
	# A linked worktree has no ignored dependencies. Only npm lockfile scopes can
	# be safely bootstrapped with npm ci; other managers retain their own policy.
	if [[ "$pm" == "npm" && -f "$scope/package-lock.json" ]] &&
		{ [[ ! -d "$scope/node_modules" || ! -f "$scope/node_modules/.package-lock.json" ]] ||
			[[ "$scope/package-lock.json" -nt "$scope/node_modules/.package-lock.json" ]]; }; then
		print_info "[validators] installing locked dependencies for ${scope_label}"
		local install_rc=0
		(
			cd "$scope" || exit 1
			timeout_sec "$t" npm ci --ignore-scripts --no-audit --no-fund
		) >"${snapshot_dir}/install.log" 2>&1 || install_rc=$?
		if [[ "$install_rc" -ne 0 ]]; then
			print_error "[validators] ENVIRONMENT FAILURE (exit ${install_rc}): npm ci (${scope_label})"
			[[ "$install_rc" -eq 124 ]] && _validator_timeout_remedy
			tail -20 "${snapshot_dir}/install.log" >&2
			return 1
		fi
	fi
	local phase="" script_name="" check_count=0 command_rc=0 check_index=0 deferring=0 phase_timeout="" plugin_tests=0
	for phase in format lint typecheck test; do
		script_name=$(_validator_select_script "$package_json" "$phase") || continue
		check_count=$((check_count + 1))
		check_index=$((check_index + 1))
		# After a timeout under this host's load, later phases that CI also
		# requires would most likely time out too; leave them to that gate.
		if [[ "$deferring" -eq 1 ]] &&
			_validator_defer_to_required_ci "$phase" "$pm run $script_name ($scope_label)" "$snapshot_dir" \
				"not run after an earlier timeout in this scope"; then
			continue
		fi
		phase_timeout="$t"
		plugin_tests=0
		# Callers run this function in a per-scope subshell and test is its
		# last phase, so the selected concurrency reaches no other scope.
		if [[ "$phase" == "test" ]] && jq -e '.name == "opencode-aidevops"' "$package_json" >/dev/null 2>&1; then
			plugin_tests=1
			_validator_plugin_test_concurrency
			phase_timeout=$(_validator_plugin_test_timeout "$t")
			if [[ "$phase_timeout" != "$t" ]]; then
				print_info "[validators] serialized plugin tests: timeout ${phase_timeout}s (validator timeout ${t}s)"
			fi
		fi
		print_info "[validators] scope=${scope_label} reason=$([[ "$scope" == "." ]] && printf 'root-or-shared-change' || printf 'affected-workspace') command=$pm run $script_name"
		_validator_snapshot "${snapshot_dir}/before-${check_index}" || return 1
		command_rc=0
		(
			cd "$scope" || exit 1
			timeout_sec "$phase_timeout" "$pm" run "$script_name"
		) >"${snapshot_dir}/command-${check_index}.log" 2>&1 || command_rc=$?
		_restore_validator_repo_root "$(git rev-parse --show-toplevel 2>/dev/null)" "$script_name" || return 1
		_validator_snapshot "${snapshot_dir}/after-${check_index}" || return 1
		_validator_state_unchanged "${snapshot_dir}/before-${check_index}" "${snapshot_dir}/after-${check_index}" "$pm run $script_name ($scope_label)" || return 1
		if [[ "$command_rc" -eq 124 ]]; then
			if _validator_defer_to_required_ci "$phase" "$pm run $script_name ($scope_label)" "$snapshot_dir" \
				"local TIMEOUT after ${phase_timeout}s"; then
				deferring=1
				continue
			fi
			print_error "[validators] TIMEOUT after ${phase_timeout}s: $pm run $script_name ($scope_label)"
			_validator_timeout_remedy
			return 1
		elif [[ "$command_rc" -ne 0 ]]; then
			if [[ "$plugin_tests" -eq 1 ]] && _validator_rerun_flaky_plugin_tests "$scope" "$phase_timeout" \
				"$snapshot_dir" "$check_index" "$pm run $script_name ($scope_label)"; then
				continue
			fi
			print_error "[validators] CHECK FAILED (exit ${command_rc}): $pm run $script_name ($scope_label)"
			_validator_print_failure_log "${snapshot_dir}/command-${check_index}.log"
			return 1
		fi
	done
	if [[ "$check_count" -eq 0 ]]; then
		print_error "[validators] NO SCOPED CHECKS AVAILABLE for ${scope_label}"
		print_error "[validators] configure lint, typecheck, or a check-only format script in ${package_json}"
		return 1
	fi
	return 0
}

# The snapshot directory is deleted after a failure, and Node's test runner
# prints a failing file's assertion above its summary, so `tail -20` alone can
# leave only "test failed" (GH#39068). Retain the full log, then print failure
# records before the tail.
_validator_print_failure_log() {
	local log_file="$1"
	local keep_dir="${AIDEVOPS_TEMP_DIR:-${HOME}/.aidevops/.agent-workspace/tmp}/validator-logs"
	local kept_log="" excerpt=""
	if mkdir -p "$keep_dir" 2>/dev/null && kept_log=$(mktemp "${keep_dir}/check-failed.XXXXXX" 2>/dev/null); then
		if cp "$log_file" "$kept_log" 2>/dev/null; then
			print_error "[validators] full log retained: ${kept_log}"
		else
			rm -f "$kept_log"
		fi
	fi
	# Failure records first, so handled "Error:" lines from passing tests cannot
	# consume the match limit; wide context keeps a TAP error block. awk caps the
	# output without closing the pipe early under pipefail.
	excerpt=$(grep -n -E -m 8 -A 20 '^[[:space:]]*(not ok [0-9]+|AssertionError( \[[A-Z_]+\])?:)|failing tests:' "$log_file" 2>/dev/null | awk 'NR <= 120') || excerpt=""
	if [[ -z "$excerpt" ]]; then
		excerpt=$(grep -n -E -m 8 -A 6 '^[[:space:]]*[A-Za-z]*Error( \[[A-Z_]+\])?:' "$log_file" 2>/dev/null | awk 'NR <= 60') || excerpt=""
	fi
	if [[ -n "$excerpt" ]]; then
		print_error "[validators] failure details (error headlines with line numbers):"
		printf '%s\n' "$excerpt" >&2
		print_error "[validators] log tail:"
	fi
	tail -20 "$log_file" >&2
	return 0
}

# GH#40322: on a host loaded far beyond its CPUs, plugin timing tests can fail
# at random in the full suite (GH#40309). As for affected script suites
# (workflows/full-loop.md "flaky"), rerun only the failed tests, serialized, up
# to twice. Tests that pass are reported as flaky and do not block; a repeat
# failure, an unattributable failure, or more than 10 failed tests still blocks.
# Args: $1=scope $2=phase timeout $3=snapshot dir $4=check index $5=label.
_validator_rerun_flaky_plugin_tests() {
	local scope="$1" t="$2" snapshot_dir="$3" check_index="$4" command_label="$5"
	local names_file="${snapshot_dir}/flaky-names-${check_index}" files_file="${snapshot_dir}/flaky-files-${check_index}"
	local name="" file="" attempt=0 rerun_rc=0 rerun_log="" rerun_timeout="$t" count=0
	if ! _validator_failed_plugin_tests "$scope" "${snapshot_dir}/command-${check_index}.log" "$names_file" "$files_file"; then
		print_info "[validators] failure is not attributable to at most 10 named plugin tests; not rerunning"
		return 1
	fi
	local -a patterns=() files=()
	while IFS= read -r name; do
		patterns+=("--test-name-pattern=$(_validator_regex_escape "$name")")
	done <"$names_file"
	while IFS= read -r file; do files+=("$file"); done <"$files_file"
	count="${#patterns[@]}"
	[[ "$rerun_timeout" -gt 600 ]] && rerun_timeout=600
	for attempt in 1 2; do
		rerun_log="${snapshot_dir}/flaky-rerun-${check_index}-${attempt}.log"
		print_info "[validators] rerunning ${count} failed plugin test(s) serialized (attempt ${attempt}/2)"
		rerun_rc=0
		(
			cd "$scope" || exit 1
			timeout_sec "$rerun_timeout" node --test --test-concurrency=1 --test-reporter=spec "${patterns[@]}" "${files[@]}"
		) >"$rerun_log" 2>&1 || rerun_rc=$?
		_validator_snapshot "${snapshot_dir}/after-rerun-${check_index}" || return 1
		_validator_state_unchanged "${snapshot_dir}/before-${check_index}" "${snapshot_dir}/after-rerun-${check_index}" \
			"serialized rerun of ${command_label}" || return 1
		if [[ "$rerun_rc" -eq 0 ]] && _validator_rerun_passed_all "$names_file" "$rerun_log"; then
			name=$(awk 'NR > 1 { printf " | " } { printf "%s", $0 }' "$names_file") || name="(names unavailable)"
			print_warning "[validators] FLAKY (not blocking): ${count} plugin test(s) failed in the full suite and passed on serialized rerun ${attempt}: ${name}"
			printf '%s: %s\n' "$command_label" "$name" >>"${snapshot_dir}/flaky" || return 1
			return 0
		fi
		[[ "$rerun_rc" -eq 124 ]] && break
	done
	print_error "[validators] ${count} failed plugin test(s) failed again on serialized rerun (exit ${rerun_rc}); blocking"
	tail -20 "$rerun_log" >&2
	return 1
}

# Write the failed test names and their test files from a Node spec-reporter
# log. A location may be a helper module that only registers tests when another
# file calls it, so the files that import a location are rerun too. Returns 1
# when the failure cannot be attributed to 1-10 named tests under tests/.
# Args: $1=scope $2=log $3=names output $4=files output.
_validator_failed_plugin_tests() {
	local scope="$1" log_file="$2" names_file="$3" files_file="$4"
	local records="" kind="" value="" names=0 locations=0 abs_scope="" real_scope="" candidate=""
	records=$(awk '
		/✖ failing tests:/ { section = 1; next }
		!section { next }
		/^test at / { loc = $0; sub(/^test at /, "", loc); sub(/:[0-9]+:[0-9]+$/, "", loc); print "F\t" loc; next }
		/^✖ / { name = $0; sub(/^✖ /, "", name); sub(/ \([0-9.]+ms\)$/, "", name); print "N\t" name }
	' "$log_file") || return 1
	abs_scope=$(cd "$scope" && pwd) || return 1
	real_scope=$(cd "$scope" && pwd -P) || return 1
	: >"$names_file" || return 1
	: >"${files_file}.locations" || return 1
	while IFS=$'\t' read -r kind value; do
		case "$kind" in
		N)
			# A file-level failure is named by its path; a name filter cannot
			# rerun it, and the file record would pass with no tests run.
			[[ "$value" != *.mjs ]] || return 1
			names=$((names + 1))
			printf '%s\n' "$value" >>"$names_file"
			;;
		F)
			locations=$((locations + 1))
			value="${value#file://}"
			value="${value#"${real_scope}"/}"
			value="${value#"${abs_scope}"/}"
			[[ "$value" == tests/*.mjs && "$value" != *..* && -f "${scope}/${value}" ]] || return 1
			printf '%s\n' "$value" >>"${files_file}.locations"
			;;
		esac
	done <<<"$records"
	[[ "$names" -ge 1 && "$names" -le 10 && "$names" -eq "$locations" ]] || return 1
	awk '!seen[$0]++' "$names_file" >"${names_file}.unique" || return 1
	mv "${names_file}.unique" "$names_file" || return 1
	while IFS= read -r value; do
		printf '%s\n' "$value"
		for candidate in "${scope}"/tests/*.mjs; do
			if [[ -f "$candidate" ]] && grep -q -F -- "${value##*/}" "$candidate"; then
				printf '%s\n' "${candidate#"${scope}"/}"
			fi
		done
	done <"${files_file}.locations" | awk '!seen[$0]++' >"$files_file" || return 1
	[[ -s "$files_file" ]] || return 1
	return 0
}

# Escape a test name for Node's --test-name-pattern, which builds a RegExp.
_validator_regex_escape() {
	local text="$1"
	printf '%s' "$text" | sed -e 's/[][\\.^$|?*+(){}/]/\\&/g'
	return 0
}

# A name filter that matches nothing also exits 0, so require a passing record
# for every failed name before counting a rerun as passed.
_validator_rerun_passed_all() {
	local names_file="$1" rerun_log="$2" name="" line="" found=0
	while IFS= read -r name; do
		found=0
		while IFS= read -r line; do
			line="${line#"${line%%[![:space:]]*}"}"
			if [[ "$line" == "✔ ${name} ("* ]]; then
				found=1
				break
			fi
		done <"$rerun_log"
		[[ "$found" -eq 1 ]] || return 1
	done <"$names_file"
	return 0
}

# Only the full-loop plugin gate adapts to host load; direct npm/CI runs keep
# Node's default concurrency. Reduce contention at moderate load and serialize
# at high load (GH#35499, GH#39133). Never extend per-test budgets.
_validator_plugin_test_concurrency() {
	local concurrency=""
	if [[ -n "${AIDEVOPS_PLUGIN_TEST_CONCURRENCY+x}" ]]; then
		print_info "[validators] using caller-set plugin test concurrency: ${AIDEVOPS_PLUGIN_TEST_CONCURRENCY}"
		return 0
	fi
	concurrency=$(node -e '
		const os = require("node:os");
		const cpus = typeof os.availableParallelism === "function"
			? os.availableParallelism() : Math.max(1, os.cpus().length);
		const load = os.loadavg()[0] / cpus;
		if (load > 4) process.stdout.write("1");
		else if (load > 1.5) process.stdout.write(String(Math.max(2, Math.floor(cpus / 4))));
	') || concurrency=1
	if [[ -n "$concurrency" ]]; then
		export AIDEVOPS_PLUGIN_TEST_CONCURRENCY="$concurrency"
		print_info "[validators] running plugin tests with concurrency ${concurrency} (host load or unavailable load probe)"
	fi
	return 0
}

# A serialized suite runs its files one at a time on a host already loaded
# above 4 per CPU, so it cannot finish inside a budget sized for a parallel
# run (GH#40303). Give that phase a floor; a larger configured timeout wins.
# Per-test budgets are unchanged, and a hang still ends at the floor.
_validator_plugin_test_timeout() {
	local t="$1"
	local floor=2400
	if [[ "${AIDEVOPS_PLUGIN_TEST_CONCURRENCY:-}" == 1 && "$t" -lt "$floor" ]]; then
		printf '%s\n' "$floor"
		return 0
	fi
	printf '%s\n' "$t"
	return 0
}

# The orchestrator's selected config is inherited by scoped checks. Keep the
# durable remedy alongside the env hint, which cannot override a project value.
_validator_timeout_remedy() {
	print_error "[validators] Run: aidevops project-config set validator_timeout_seconds <n> (larger positive integer; audited durable canonical setting: ${validator_config:-.aidevops.json})"
	print_error "[validators] A worktree-local .aidevops.json overrides the canonical setting; update a local override inside the linked worktree if present"
	print_error "[validators] Set AIDEVOPS_VALIDATOR_TIMEOUT=<n> and rerun if no project timeout is configured; do not skip checks"
	return 0
}

# Print one line per record file entry joined by "; " (empty when absent).
_validator_join_records() {
	local record_file="$1" record="" joined=""
	if [[ -s "$record_file" ]]; then
		while IFS= read -r record; do
			joined="${joined}${joined:+; }${record}"
		done <"$record_file"
	fi
	printf '%s' "$joined"
	return 0
}

# Orchestrator. Args: $1=skip_hooks (0|1). Returns 0 on pass/skip, 1 on fail.
_run_project_validators() {
	local skip_hooks="${1:-0}"
	FULL_LOOP_VALIDATOR_DEFERRALS=""
	FULL_LOOP_VALIDATOR_FLAKY=""
	# _validators_should_run returns 0 when validators should run, 1 otherwise.
	if ! _validators_should_run "$skip_hooks"; then
		return 0
	fi
	if ! _commit_touches_node_files; then
		print_info "[validators] no Node/TypeScript files changed, skipping node project validators"
		return 0
	fi
	local pm=""
	if ! _detect_node_project; then
		# Silent skip when no project detected (non-node project = most aidevops paths).
		return 0
	fi
	print_info "[validators] running node project validators ($pm)..."
	local validator_timeout validator_config=".aidevops.json"
	# Ignored project settings are not copied to linked worktrees. The common Git
	# directory's first worktree is the canonical checkout, including repositories
	# with a separate Git directory. Never fall back when a local config exists.
	if [[ ! -e "$validator_config" ]]; then
		local common_dir="" record=""
		common_dir=$(git rev-parse --git-common-dir 2>/dev/null) || return 1
		while IFS= read -r record; do
			if [[ "$record" == worktree\ * ]]; then
				validator_config="${record#worktree }/.aidevops.json"
				break
			fi
		done < <(git -c core.quotePath=false --git-dir="$common_dir" worktree list --porcelain)
	fi
	# Project configuration takes precedence over the environment override.
	if [[ -f "$validator_config" ]]; then
		if ! jq -e 'type == "object"' "$validator_config" >/dev/null 2>&1; then
			print_error "[validators] invalid .aidevops.json configuration: ${validator_config}"
			return 1
		fi
		if jq -e 'has("validator_timeout_seconds")' "$validator_config" >/dev/null; then
			validator_timeout=$(jq -r '.validator_timeout_seconds | tostring' "$validator_config") || return 1
		else
			validator_timeout="${AIDEVOPS_VALIDATOR_TIMEOUT-300}"
		fi
	else
		validator_timeout="${AIDEVOPS_VALIDATOR_TIMEOUT-300}"
	fi
	if ! [[ "$validator_timeout" =~ ^[1-9][0-9]*$ ]]; then
		print_error "[validators] validator_timeout_seconds / AIDEVOPS_VALIDATOR_TIMEOUT must be a positive integer"
		return 1
	fi
	if ! command -v "$pm" >/dev/null 2>&1; then
		print_error "[validators] REQUIRED COMMAND UNAVAILABLE: $pm"
		return 1
	fi
	local scopes="" snapshot_dir=""
	local scope=""
	scopes=$(_validator_scopes) || return 1
	snapshot_dir=$(mktemp -d) || return 1
	while IFS= read -r scope; do
		[[ -n "$scope" ]] || continue
		( _run_scoped_node_checks "$pm" "$scope" "$validator_timeout" "$snapshot_dir" ) || {
			rm -rf "$snapshot_dir"
			return 1
		}
	done <<<"$scopes"
	FULL_LOOP_VALIDATOR_DEFERRALS=$(_validator_join_records "${snapshot_dir}/deferred")
	FULL_LOOP_VALIDATOR_FLAKY=$(_validator_join_records "${snapshot_dir}/flaky")
	rm -rf "$snapshot_dir"
	if [[ -n "$FULL_LOOP_VALIDATOR_FLAKY" ]]; then
		print_warning "[validators] flaky plugin tests passed on serialized rerun (not blocking): ${FULL_LOOP_VALIDATOR_FLAKY}"
	fi
	if [[ -n "$FULL_LOOP_VALIDATOR_DEFERRALS" ]]; then
		print_info "[validators] passed with deferrals to required CI (check-only scope: ${scopes//$'\n'/, }): ${FULL_LOOP_VALIDATOR_DEFERRALS}"
		return 0
	fi
	print_info "[validators] passed (check-only scope: ${scopes//$'\n'/, })"
	return 0
}
