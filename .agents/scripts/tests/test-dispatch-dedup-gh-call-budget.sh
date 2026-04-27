#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# Regression test for t2996 — dispatch_with_dedup gh-call budget.
#
# The pulse's `dispatch_with_dedup` orchestrator and the gates it delegates
# to (consolidation, large-file simplification, brief-freshness, eligibility,
# 7-layer dedup) historically made 10-15 serial `gh issue view` calls per
# dispatch candidate. Each call costs 0.5-2s under steady state and 5s+
# under load; the cumulative cost reliably exceeded the t2989 30s
# `fill_floor_per_candidate_timeout`, killing dispatch decisions before
# the worker could be spawned (37 timeout events in 24h, baseline 2026-04-27).
#
# The fix (t2996) threads a single canonical bundle —
# `gh issue view --json number,title,state,labels,assignees,body` — through
# every gate that needs issue metadata. This test enforces the budget at
# the source level: a regression that re-introduces a per-gate gh call
# fails CI with an explicit pointer at the offending function.
#
# What this test verifies (static source-level checks, no live network):
#   1. `dispatch_with_dedup` fetches the canonical bundle in ONE gh call
#      with `body` included.
#   2. `_dispatch_dedup_check_layers` does NOT make a separate
#      `gh issue view --json body` call (body comes from the bundle).
#   3. `_issue_needs_consolidation` accepts an optional pre-fetched JSON
#      argument and skips the gh call when it's provided.
#   4. `_issue_targets_large_files` accepts an optional pre-fetched JSON
#      argument and skips both its labels AND title gh calls when provided.
#   5. `_ensure_issue_body_has_brief` accepts an optional pre-fetched JSON
#      argument and skips the gh call when it's provided.
#   6. The total `gh issue view` count inside `_dispatch_dedup_check_layers`
#      stays at zero (all calls are now in `dispatch_with_dedup` itself).
#   7. The t2996 marker is present at every threading site so future
#      auditors can `rg t2996` to find the budget invariant.
#
# Why static checks instead of mocking and counting live invocations:
# the dispatch path depends on disk-space probes, git fetches, signal
# traps, and several supporting helpers that would each need their own
# scaffolding. The static checks pin the contract at the cheapest layer
# and will catch every realistic regression — a future contributor that
# reverts the JSON threading WILL change one of the patterns this test
# matches.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)" || exit 1

CORE_SH="${REPO_ROOT}/.agents/scripts/pulse-dispatch-core.sh"
LARGE_FILE_GATE_SH="${REPO_ROOT}/.agents/scripts/pulse-dispatch-large-file-gate.sh"
TRIAGE_SH="${REPO_ROOT}/.agents/scripts/pulse-triage.sh"

# shellcheck disable=SC2034  # ANSI helpers used by _print_result; shellcheck doesn't trace printf %b refs
readonly TEST_RED='\033[0;31m'
# shellcheck disable=SC2034
readonly TEST_GREEN='\033[0;32m'
# shellcheck disable=SC2034
readonly TEST_RESET='\033[0m'

TESTS_RUN=0
TESTS_FAILED=0

_print_result() {
	local name="$1"
	local passed="$2"
	local detail="${3:-}"
	TESTS_RUN=$((TESTS_RUN + 1))
	if [[ "$passed" == "1" ]]; then
		printf '%b[PASS]%b %s\n' "$TEST_GREEN" "$TEST_RESET" "$name"
	else
		printf '%b[FAIL]%b %s' "$TEST_RED" "$TEST_RESET" "$name"
		[[ -n "$detail" ]] && printf ' — %s' "$detail"
		printf '\n'
		TESTS_FAILED=$((TESTS_FAILED + 1))
	fi
	return 0
}

_extract_function_body() {
	# Print the body lines of a bash function from a file. Uses a simple
	# brace-tracking awk pass so it tolerates the indented `}` style used
	# by the pulse scripts. Args: $1=file $2=function_name (must match the
	# canonical `name() {` form used in this codebase).
	local file="$1"
	local fname="$2"
	awk -v fname="$fname" '
		# Match the function header. Tolerates whitespace before "(){" and
		# accepts both `name() {` and `name () {`. We deliberately do not
		# match `function name { ... }` (not used in this codebase).
		$0 ~ "^"fname"[[:space:]]*\\([[:space:]]*\\)[[:space:]]*\\{" {
			depth = 1; in_fn = 1; next
		}
		in_fn {
			# Count opening / closing braces to find the matching `}`.
			# This is a heuristic — strings and heredocs containing
			# unbalanced braces would defeat it, but these dispatch
			# functions do not use any.
			n = gsub(/\{/, "&"); m = gsub(/\}/, "&")
			depth += n - m
			if (depth <= 0) { exit }
			print
		}
	' "$file"
}

_count_gh_issue_view_in_function() {
	# Counts ACTUAL `gh issue view` invocations — skips lines whose first
	# non-whitespace character is `#` (shell comments). Without this filter
	# the t2996 audit markers in the function bodies (which legitimately
	# mention "gh issue view" inside comments to document what was eliminated)
	# would inflate the count and trigger false-positive regressions.
	local file="$1"
	local fname="$2"
	_extract_function_body "$file" "$fname" \
		| grep -vE '^[[:space:]]*#' \
		| grep -cE 'gh issue view ' || true
}

# ---------------------------------------------------------------------------
# Test 1: dispatch_with_dedup makes ONE canonical gh call with `body`.
# ---------------------------------------------------------------------------
test_canonical_bundle_includes_body() {
	local body
	body=$(_extract_function_body "$CORE_SH" "dispatch_with_dedup")

	# shellcheck disable=SC2016 # Literal '$issue_number' inside regex pattern is intentional.
	if printf '%s' "$body" | grep -qE 'gh issue view "\$issue_number" --repo "\$repo_slug" \\$'; then
		# header line present; check the next line includes body
		if printf '%s' "$body" | grep -qE -- '--json number,title,state,labels,assignees,body'; then
			_print_result "dispatch_with_dedup canonical gh call includes body" 1
			return 0
		fi
	fi
	_print_result "dispatch_with_dedup canonical gh call includes body" 0 \
		"expected '--json number,title,state,labels,assignees,body' inside dispatch_with_dedup"
	return 1
}

# ---------------------------------------------------------------------------
# Test 2: dispatch_with_dedup makes EXACTLY ONE `gh issue view` call.
# ---------------------------------------------------------------------------
test_dispatch_with_dedup_single_gh_call() {
	local count
	count=$(_count_gh_issue_view_in_function "$CORE_SH" "dispatch_with_dedup")
	count="${count//[!0-9]/}"
	count="${count:-0}"
	if [[ "$count" -eq 1 ]]; then
		_print_result "dispatch_with_dedup makes exactly 1 gh issue view call (got $count)" 1
	else
		_print_result "dispatch_with_dedup makes exactly 1 gh issue view call (got $count)" 0 \
			"budget is 1; threading the canonical bundle should cover all sub-gate metadata needs"
	fi
}

# ---------------------------------------------------------------------------
# Test 3: _dispatch_dedup_check_layers makes ZERO `gh issue view` calls.
# All metadata flows through $issue_meta_json (extracted from the bundle).
# ---------------------------------------------------------------------------
test_check_layers_no_gh_issue_view() {
	local count
	count=$(_count_gh_issue_view_in_function "$CORE_SH" "_dispatch_dedup_check_layers")
	count="${count//[!0-9]/}"
	count="${count:-0}"
	if [[ "$count" -eq 0 ]]; then
		_print_result "_dispatch_dedup_check_layers makes 0 gh issue view calls (got $count)" 1
	else
		_print_result "_dispatch_dedup_check_layers makes 0 gh issue view calls (got $count)" 0 \
			"a new gh call here re-introduces the t2996 timeout cliff; thread issue_meta_json instead"
	fi
}

# ---------------------------------------------------------------------------
# Test 4: _issue_needs_consolidation accepts optional pre_fetched_json.
# ---------------------------------------------------------------------------
test_issue_needs_consolidation_accepts_meta() {
	local body
	body=$(_extract_function_body "$TRIAGE_SH" "_issue_needs_consolidation")
	if printf '%s' "$body" | grep -qE 'pre_fetched_json="\$\{3:-\}"' \
		&& printf '%s' "$body" | grep -qE 'jq -r .*\.labels\[\]\.name'; then
		_print_result "_issue_needs_consolidation accepts pre_fetched_json (param 3)" 1
	else
		_print_result "_issue_needs_consolidation accepts pre_fetched_json (param 3)" 0 \
			"expected 'local pre_fetched_json=\"\${3:-}\"' + jq labels extraction inside the body"
	fi
}

# ---------------------------------------------------------------------------
# Test 5: _issue_targets_large_files accepts optional pre_fetched_json
# (param 6) and skips BOTH labels AND title gh calls when provided.
# ---------------------------------------------------------------------------
test_issue_targets_large_files_accepts_meta() {
	local body
	body=$(_extract_function_body "$LARGE_FILE_GATE_SH" "_issue_targets_large_files")
	local ok=1
	if ! printf '%s' "$body" | grep -qE 'pre_fetched_json="\$\{6:-\}"'; then
		ok=0
	fi
	# Must extract labels from JSON when bundle is present.
	if ! printf '%s' "$body" | grep -qE 'jq -r .*\.labels\[\]\.name'; then
		ok=0
	fi
	# Must extract title from JSON when bundle is present.
	if ! printf '%s' "$body" | grep -qE 'jq -r .*\.title'; then
		ok=0
	fi
	if [[ "$ok" -eq 1 ]]; then
		_print_result "_issue_targets_large_files accepts pre_fetched_json (param 6) + JSON-derives labels & title" 1
	else
		_print_result "_issue_targets_large_files accepts pre_fetched_json (param 6) + JSON-derives labels & title" 0 \
			"expected 'local pre_fetched_json=\"\${6:-}\"' + jq labels + jq title inside the body"
	fi
}

# ---------------------------------------------------------------------------
# Test 6: _ensure_issue_body_has_brief accepts optional pre_fetched_json
# (param 5) and skips the body gh call when provided.
# ---------------------------------------------------------------------------
test_ensure_issue_body_has_brief_accepts_meta() {
	local body
	body=$(_extract_function_body "$CORE_SH" "_ensure_issue_body_has_brief")
	if printf '%s' "$body" | grep -qE 'pre_fetched_json="\$\{5:-\}"' \
		&& printf '%s' "$body" | grep -qE 'jq -r .*\.body'; then
		_print_result "_ensure_issue_body_has_brief accepts pre_fetched_json (param 5)" 1
	else
		_print_result "_ensure_issue_body_has_brief accepts pre_fetched_json (param 5)" 0 \
			"expected 'local pre_fetched_json=\"\${5:-}\"' + jq body extraction inside the body"
	fi
}

# ---------------------------------------------------------------------------
# Test 7: ISSUE_META_JSON is exported when calling check_dispatch_dedup so
# Layer 6 (and other dispatch-dedup-helper.sh subcommands) reuse the bundle
# instead of re-fetching.
# ---------------------------------------------------------------------------
test_check_dispatch_dedup_passes_meta_env() {
	local body
	body=$(_extract_function_body "$CORE_SH" "_dispatch_dedup_check_layers")
	# Combine both regex checks into one local var to keep the shellcheck
	# disable directive in a valid pre-`if` position. The patterns contain
	# literal `$issue_meta_json` which SC2016 mistakes for a shell expansion.
	local has_env=0 has_call=0
	# shellcheck disable=SC2016
	printf '%s' "$body" | grep -qE 'ISSUE_META_JSON="\$issue_meta_json"' && has_env=1
	printf '%s' "$body" | grep -qE 'check_dispatch_dedup ' && has_call=1
	if [[ "$has_env" -eq 1 && "$has_call" -eq 1 ]]; then
		_print_result "_dispatch_dedup_check_layers exports ISSUE_META_JSON for check_dispatch_dedup" 1
	else
		_print_result "_dispatch_dedup_check_layers exports ISSUE_META_JSON for check_dispatch_dedup" 0 \
			"expected 'ISSUE_META_JSON=\"\$issue_meta_json\" check_dispatch_dedup ...' env-prefix"
	fi
}

# ---------------------------------------------------------------------------
# Test 8: t2996 markers are present at every threading site. Future
# auditors can run `rg 't2996' .agents/scripts/` to find the invariant.
# ---------------------------------------------------------------------------
test_t2996_markers_present() {
	local sites
	sites=$(grep -lE 't2996' "$CORE_SH" "$LARGE_FILE_GATE_SH" "$TRIAGE_SH" 2>/dev/null | wc -l)
	sites="${sites//[!0-9]/}"
	sites="${sites:-0}"
	if [[ "$sites" -ge 3 ]]; then
		_print_result "t2996 audit markers present in all 3 modified files (got $sites/3)" 1
	else
		_print_result "t2996 audit markers present in all 3 modified files (got $sites/3)" 0 \
			"each threading site must carry a 't2996' comment so reverts are traceable"
	fi
}

main() {
	test_canonical_bundle_includes_body || true
	test_dispatch_with_dedup_single_gh_call || true
	test_check_layers_no_gh_issue_view || true
	test_issue_needs_consolidation_accepts_meta || true
	test_issue_targets_large_files_accepts_meta || true
	test_ensure_issue_body_has_brief_accepts_meta || true
	test_check_dispatch_dedup_passes_meta_env || true
	test_t2996_markers_present || true

	printf '\n--- Tests run: %d, failed: %d ---\n' "$TESTS_RUN" "$TESTS_FAILED"
	[[ "$TESTS_FAILED" -eq 0 ]]
}

main "$@"
