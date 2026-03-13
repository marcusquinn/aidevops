#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
HELPER="${SCRIPT_DIR}/../browser-qa-helper.sh"

readonly TEST_RED='\033[0;31m'
readonly TEST_GREEN='\033[0;32m'
readonly TEST_RESET='\033[0m'

TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0

print_result() {
	local test_name="$1"
	local result="$2"
	local message="${3:-}"

	TESTS_RUN=$((TESTS_RUN + 1))
	if [[ "$result" -eq 0 ]]; then
		echo -e "${TEST_GREEN}PASS${TEST_RESET} ${test_name}"
		TESTS_PASSED=$((TESTS_PASSED + 1))
		return 0
	fi

	echo -e "${TEST_RED}FAIL${TEST_RESET} ${test_name}"
	if [[ -n "$message" ]]; then
		echo "       ${message}"
	fi
	TESTS_FAILED=$((TESTS_FAILED + 1))
	return 0
}

test_resolve_default_max_dim() {
	local value
	value=$(resolve_max_image_dim "")
	if [[ "$value" == "4000" ]]; then
		print_result "resolve default max dimension" 0
	else
		print_result "resolve default max dimension" 1 "expected 4000, got ${value}"
	fi
	return 0
}

test_resolve_invalid_max_dim_falls_back() {
	local value
	value=$(resolve_max_image_dim "not-a-number")
	if [[ "$value" == "4000" ]]; then
		print_result "invalid max dimension falls back to default" 0
	else
		print_result "invalid max dimension falls back to default" 1 "expected 4000, got ${value}"
	fi
	return 0
}

test_resolve_clamps_to_anthropic_limit() {
	local value
	value=$(resolve_max_image_dim "12000")
	if [[ "$value" == "8000" ]]; then
		print_result "max dimension clamps to Anthropic limit" 0
	else
		print_result "max dimension clamps to Anthropic limit" 1 "expected 8000, got ${value}"
	fi
	return 0
}

test_guardrail_resizes_oversized_images() {
	local tmp_dir
	tmp_dir=$(mktemp -d)
	touch "${tmp_dir}/small.png"
	touch "${tmp_dir}/large.png"

	get_image_dimensions() {
		local image_path="$1"
		case "$(basename "$image_path")" in
		small.png) echo "1200x900" ;;
		large.png)
			if [[ -f "${image_path}.resized" ]]; then
				echo "4000x2500"
			else
				echo "9000x5000"
			fi
			;;
		*) return 1 ;;
		esac
		return 0
	}

	resize_image_to_max_dim() {
		local image_path="$1"
		local max_dim="$2"
		if [[ "$max_dim" != "4000" ]]; then
			return 1
		fi
		touch "${image_path}.resized"
		return 0
	}

	if enforce_screenshot_size_guardrails "$tmp_dir" "4000"; then
		print_result "guardrail resizes oversized screenshots" 0
	else
		print_result "guardrail resizes oversized screenshots" 1 "expected enforcement success"
	fi

	rm -rf "$tmp_dir"
	return 0
}

test_guardrail_fails_hard_limit_violation() {
	local tmp_dir
	tmp_dir=$(mktemp -d)
	touch "${tmp_dir}/too-large.png"

	get_image_dimensions() {
		local image_path="$1"
		if [[ "$(basename "$image_path")" == "too-large.png" ]]; then
			echo "9001x9001"
			return 0
		fi
		return 1
	}

	resize_image_to_max_dim() {
		local image_path="$1"
		local max_dim="$2"
		if [[ -z "$image_path" || -z "$max_dim" ]]; then
			return 1
		fi
		return 0
	}

	if enforce_screenshot_size_guardrails "$tmp_dir" "8000"; then
		print_result "guardrail fails when hard limit remains exceeded" 1 "expected failure for image > 8000px"
	else
		print_result "guardrail fails when hard limit remains exceeded" 0
	fi

	rm -rf "$tmp_dir"
	return 0
}

main() {
	# Source after function declarations so helper functions are available here.
	# main() in helper is guarded and will not auto-run when sourced.
	# shellcheck source=../browser-qa-helper.sh
	source "$HELPER"

	echo "============================================="
	echo "  browser-qa-helper.sh guardrail tests"
	echo "============================================="

	test_resolve_default_max_dim
	test_resolve_invalid_max_dim_falls_back
	test_resolve_clamps_to_anthropic_limit
	test_guardrail_resizes_oversized_images
	test_guardrail_fails_hard_limit_violation

	echo "============================================="
	echo "  Results: ${TESTS_PASSED}/${TESTS_RUN} passed, ${TESTS_FAILED} failed"
	echo "============================================="

	if [[ "$TESTS_FAILED" -gt 0 ]]; then
		exit 1
	fi
	return 0
}

main "$@"
