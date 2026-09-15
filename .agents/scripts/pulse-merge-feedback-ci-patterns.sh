#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# CI check classification and guidance helpers.

[[ "${BASH_SOURCE[0]}" == "${0}" ]] && set -euo pipefail

[[ -n "${_PULSE_MERGE_FEEDBACK_CI_PATTERNS_LOADED:-}" ]] && return 0
_PULSE_MERGE_FEEDBACK_CI_PATTERNS_LOADED=1

#######################################
# Classify a list of failing CI check names against ci-failure-patterns.conf
# (t3225). Mirror of _classify_conflicts_by_pattern but operates on check
# names (newline-separated) instead of file paths.
#
# Each output line has the form:
#   CLASSIFICATION name1|name2|...
# (note: separator inside the names list is `|` not space, because check
# names commonly contain spaces e.g. "ShellCheck (ubuntu-latest)").
#
# Patterns are matched in conf order. OTHER is the catch-all fallback.
# Names that match a non-OTHER pattern are collected per-classification.
# Unmatched names fall through to the OTHER bucket.
#
# Args:
#   $1 - newline-separated list of failing CI check names
#   $2 - (optional) path to ci-failure-patterns.conf; defaults to
#        configs/ci-failure-patterns.conf relative to this script.
#
# Output: multi-line classification on stdout (empty if no names given).
#######################################
_classify_ci_failures_by_pattern() {
	local name_list="$1"
	local conf_file="${2:-}"

	if [[ -z "$conf_file" ]]; then
		# Resolve via dirname (no symlink resolution needed for -f / read).
		conf_file="${BASH_SOURCE[0]%/*}/../configs/ci-failure-patterns.conf"
	fi

	[[ -n "$name_list" ]] || return 0
	[[ -f "$conf_file" ]] || {
		printf 'OTHER %s\n' "${name_list//$'\n'/|}"
		return 0
	}

	local classified_lines=
	while IFS= read -r cname; do
		[[ -n "$cname" ]] || continue

		local matched_class=
		while IFS='|' read -r class_raw glob_raw _rest; do
			# Both vars initialised to empty for set -u safety (t2863).
			local class='' glob=''
			class="${class_raw#"${class_raw%%[![:space:]]*}"}"
			class="${class%"${class##*[![:space:]]}"}"
			glob="${glob_raw#"${glob_raw%%[![:space:]]*}"}"
			glob="${glob%"${glob##*[![:space:]]}"}"

			[[ -n "$class" && -n "$glob" ]] || continue
			[[ "$class" == \#* ]] && continue

			# shellcheck disable=SC2254  # dynamic glob is intentional
			case "$cname" in
				$glob)
					matched_class="$class"
					break
					;;
			esac
		done < <(grep -v '^[[:space:]]*#' "$conf_file" | grep -v '^[[:space:]]*$')

		[[ -n "$matched_class" ]] || matched_class="OTHER"
		classified_lines="${classified_lines}${matched_class}::${cname}"$'\n'
	done < <(printf '%s\n' "$name_list")

	# Group by classification, preserving conf-file priority order.
	local all_classes="FORMAT_FAILURE LINT_FAILURE EXTERNAL_STATIC_ANALYSIS TYPECHECK_FAILURE TEST_FAILURE TIMEOUT_NO_OUTPUT OTHER"
	for class in $all_classes; do
		local names_for_class=
		while IFS= read -r entry; do
			[[ "$entry" == "${class}::"* ]] || continue
			local n="${entry#*::}"
			if [[ -z "$names_for_class" ]]; then
				names_for_class="$n"
			else
				names_for_class="${names_for_class}|${n}"
			fi
		done < <(printf '%s\n' "$classified_lines")
		if [[ -n "$names_for_class" ]]; then
			printf '%s %s\n' "$class" "$names_for_class"
		fi
	done
	return 0
}

#######################################
# Emit markdown guidance blocks for each non-OTHER CI failure pattern (t3225).
#
# Mirror of _emit_pattern_guidance_blocks but for CI check names. Reads the
# RESOLUTION_COMMAND and GUIDANCE_TEXT for each detected classification from
# ci-failure-patterns.conf.
#
# Args:
#   $1 - classification_output  (multi-line: "CLASS name1|name2|...")
#   $2 - conf_file              (path to ci-failure-patterns.conf)
#
# Output: markdown guidance blocks on stdout (nothing if all OTHER or empty).
#######################################
_emit_ci_failure_guidance_blocks() {
	local classification_output="$1"
	local conf_file="$2"

	[[ -n "$classification_output" ]] || return 0

	local has_actionable=0
	while IFS= read -r cls_line; do
		[[ -n "$cls_line" ]] || continue
		[[ "$cls_line" == OTHER\ * ]] || has_actionable=1
	done < <(printf '%s\n' "$classification_output")
	[[ $has_actionable -eq 1 ]] || return 0

	printf '\n### Pattern-Specific Resolution Guidance\n\n'
	printf 'The failing checks match known patterns with deterministic resolution paths.\n'
	printf 'Try the auto-fix sequence(s) below FIRST, before falling back to the\n'
	printf 'generic worker guidance further down.\n\n'

	while IFS= read -r cls_line; do
		[[ -n "$cls_line" ]] || continue
		local class="${cls_line%% *}"
		local names="${cls_line#* }"
		[[ "$class" == "OTHER" ]] && continue

		local resolution_cmd="" guidance=""
		local fallback_resolution_cmd="" fallback_guidance="" cr="" gr="" rr="" guide_raw=""
		if [[ -f "$conf_file" ]]; then
			while IFS='|' read -r cr gr rr guide_raw; do
				local cn="${cr#"${cr%%[![:space:]]*}"}"
				cn="${cn%"${cn##*[![:space:]]}"}"
				[[ "$cn" == "$class" ]] || continue
				local glob="${gr#"${gr%%[![:space:]]*}"}"
				glob="${glob%"${glob##*[![:space:]]}"}"
				rr="${rr#"${rr%%[![:space:]]*}"}"; rr="${rr%"${rr##*[![:space:]]}"}"
				guide_raw="${guide_raw#"${guide_raw%%[![:space:]]*}"}"
				guide_raw="${guide_raw%"${guide_raw##*[![:space:]]}"}"
				if [[ -z "$fallback_resolution_cmd" && -z "$fallback_guidance" ]]; then
					fallback_resolution_cmd="$rr"; fallback_guidance="$guide_raw"
				fi

				local name=""
				while IFS= read -r name; do
					[[ -n "$name" ]] || continue
					# shellcheck disable=SC2254  # dynamic glob is intentional
					case "$name" in
						$glob)
							resolution_cmd="$rr"; guidance="$guide_raw"
							break 2
							;;
					esac
				done < <(printf '%s\n' "${names//|/$'\n'}")
			done < <(grep -v '^[[:space:]]*#' "$conf_file" \
				| grep -v '^[[:space:]]*$')
		fi
		if [[ -z "$resolution_cmd" && -n "$fallback_resolution_cmd" ]]; then
			resolution_cmd="$fallback_resolution_cmd"; guidance="$fallback_guidance"
		fi

		printf '#### Pattern: %s\n\n' "$class"
		# shellcheck disable=SC2016  # backticks are literal markdown
		printf 'Affected checks: `%s`\n\n' "${names//|/, }"
		if [[ -n "$guidance" ]]; then
			local expanded="${guidance//\\n/$'\n'}"
			printf '%s\n\n' "$expanded"
		fi
		if [[ -n "$resolution_cmd" ]]; then
			# shellcheck disable=SC2016  # backticks are literal markdown
			printf 'Quick resolution command: `%s`\n\n' "$resolution_cmd"
		fi
	done < <(printf '%s\n' "$classification_output")
	return 0
}
