#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# Runtime-risk and testing-evidence classification for full-loop PR bodies.

[[ "${BASH_SOURCE[0]}" == "${0}" ]] && set -euo pipefail
[[ -n "${_FULL_LOOP_RISK_LIB_LOADED:-}" ]] && return 0
_FULL_LOOP_RISK_LIB_LOADED=1

# Derive the most conservative runtime-risk level supported by the supplied
# metadata and branch diff. An explicit level remains available for cases that
# cannot be inferred reliably from text. Low is reserved for policy-listed
# non-runtime paths; other unmatched changes fail upward to Medium.
# Arguments: requested_risk, files_changed, summary_what, base_ref (optional)
_derive_runtime_risk() {
	local requested_risk="${1:-}"
	local files_changed="${2:-}"
	local summary_what="${3:-}"
	local base_ref="${4:-}"
	local normalized=""

	if [[ -n "$requested_risk" ]]; then
		normalized=$(printf '%s' "$requested_risk" | tr '[:upper:]' '[:lower:]')
		case "$normalized" in
		critical)
			printf 'Critical\n'
			return 0
			;;
		high)
			printf 'High\n'
			return 0
			;;
		medium)
			printf 'Medium\n'
			return 0
			;;
		low)
			printf 'Low\n'
			return 0
			;;
		*)
			print_error "Invalid --risk-level '${requested_risk}'. Expected Critical, High, Medium, or Low."
			return 1
			;;
		esac
	fi

	local context="${summary_what} ${files_changed}"
	if [[ -n "$base_ref" ]]; then
		local diff_context=""
		diff_context=$(git diff --unified=0 "${base_ref}..HEAD" 2>/dev/null || true)
		context="${context} ${diff_context}"
	fi
	context=$(printf '%s' "$context" | tr '[:upper:]' '[:lower:]')

	if [[ "$context" =~ payment|billing|auth(entication|orization)?[[:space:]_/-]*(session)?|session[[:space:]_/-]*auth|data[[:space:]_/-]*delet|cryptograph|credential ]]; then
		printf 'Critical\n'
		return 0
	fi
	if [[ "$context" =~ poll(ing)?[[:space:]_/-]*(loop|interval)|websocket|server[[:space:]_/-]*sent[[:space:]_/-]*event|state[[:space:]_/-]*machine|form[[:space:]_/-]*handler|api[[:space:]_/-]*endpoint ]]; then
		printf 'High\n'
		return 0
	fi

	local path=""
	local saw_path=0
	local all_low=1
	local old_ifs="$IFS"
	IFS=','
	for path in $files_changed; do
		IFS="$old_ifs"
		path="${path#"${path%%[![:space:]]*}"}"
		[[ -z "$path" ]] && continue
		saw_path=1
		case "$path" in
		*.md | *.mdx | *.rst | *.txt | *.d.ts | */tests/* | */test/* | test-* | *.test.* | *.spec.* | .github/* | *lint*.config.* | *linters*.conf | .agents/prompts/*) ;;
		*) all_low=0 ;;
		esac
	done
	IFS="$old_ifs"

	if [[ "$saw_path" -eq 1 && "$all_low" -eq 1 ]]; then
		printf 'Low\n'
	else
		printf 'Medium\n'
	fi
	return 0
}

# Resolve testing evidence and enforce the runtime gate. The literal evidence
# marker is intentionally machine-readable so a prose-only claim cannot satisfy
# Critical/High requirements accidentally.
# Arguments: runtime_risk, requested_testing_level, summary_testing
_resolve_runtime_testing_level() {
	local runtime_risk="$1"
	local requested_testing_level="${2:-}"
	local summary_testing="${3:-}"
	local testing_level=""

	if [[ -n "$requested_testing_level" ]]; then
		testing_level=$(printf '%s' "$requested_testing_level" | tr '[:upper:]' '[:lower:]')
	elif [[ "$summary_testing" == *runtime-verified* ]]; then
		testing_level="runtime-verified"
	else
		testing_level="self-assessed"
	fi

	case "$testing_level" in
	runtime-verified | self-assessed) ;;
	*)
		print_error "Invalid --testing-level '${requested_testing_level}'. Expected runtime-verified or self-assessed."
		return 1
		;;
	esac

	if [[ "$runtime_risk" == "Critical" || "$runtime_risk" == "High" ]] &&
		[[ "$testing_level" != "runtime-verified" ]]; then
		print_error "${runtime_risk} runtime risk requires runtime-verified evidence; PR body generation blocked."
		return 1
	fi

	printf '%s\n' "$testing_level"
	return 0
}
